//
//  LibraryWindowController.swift
//  iina
//
//  Window shown at launch that lets the user browse the WebDAV library (posters, info, rating and
//  saved position) and play files.
//

import Cocoa
import SwiftUI

extension Notification.Name {
  /// Posted each time the library window is shown, so it refreshes the saved positions.
  static let webdavLibraryDidShow = Notification.Name("WebDAVLibraryDidShow")
}

final class LibraryWindowController: NSWindowController, NSWindowDelegate {
  static let shared = LibraryWindowController()

  private var didFillScreen = false

  private init() {
    // Same chrome as IINA's welcome window: transparent title bar, no title, content under the title bar.
    let window = CommonWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Biblioteca WebDAV"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    window.collectionBehavior.insert(.fullScreenPrimary)   // green button = real full screen
    window.minSize = NSSize(width: 760, height: 460)
    super.init(window: window)
    window.delegate = self
    let host = NSHostingController(rootView: LibraryView(onPlay: { [weak self] entry, fromStart in
      self?.play(entry, fromStart: fromStart)
    }))
    if #available(macOS 13.0, *) { host.sizingOptions = [] }   // don't let SwiftUI resize the window to its content
    window.contentViewController = host
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show() {
    NotificationCenter.default.post(name: .webdavLibraryDidShow, object: nil)
    // Follow IINA's theme setting.
    if let theme = Preference.enum(for: .themeMaterial) as Preference.Theme? {
      window?.appearance = NSAppearance(iinaTheme: theme)
    }
    // Fill the whole usable screen the first time it is shown (the user can still resize or go full screen).
    if !didFillScreen, let window, let screen = window.screen ?? NSScreen.main {
      window.setFrame(screen.visibleFrame, display: true)
      didFillScreen = true
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func play(_ entry: WebDAVEntry, fromStart: Bool) {
    guard let url = WebDAVClient.absoluteURL(forHref: entry.href) else { return }
    let player = PlayerCore.activeOrNew
    if fromStart {
      // mpv resumes from its watch-later file; removing it (and Trakt's resume) makes playback start at 0.
      let md5 = Utility.mpvWatchLaterMd5(url, false)
      try? FileManager.default.removeItem(at: Utility.watchLaterURL.appendingPathComponent(md5))
      TraktScrobbler.shared.skipResumeOnce = true
    }
    // Send credentials as a header instead of embedding them in the URL.
    WebDAVConfig.applyAuth(to: player)
    player.openURLString(url.absoluteString)
    window?.close()
  }
}

// MARK: - View model

enum LibrarySort: String, CaseIterable, Identifiable {
  case name = "Nombre (A–Z)"
  case nameDescending = "Nombre (Z–A)"
  case size = "Tamaño (mayor primero)"
  var id: String { rawValue }
}

enum LibraryTab: Hashable {
  case home
  case library
  case list(UUID)
}

@MainActor
final class LibraryViewModel: ObservableObject {
  @Published var entries: [WebDAVEntry] = []
  @Published var metadata: [String: MediaMetadata] = [:]
  @Published var progress: [String: ProgressInfo] = [:]
  @Published var loading = false
  @Published var errorMessage: String?
  @Published var current: URL?
  @Published var filter = ""
  @Published var hasTMDB = TMDBConfig.isConfigured
  @Published var sort: LibrarySort = .name
  /// Wide episode images for the shelves, by entry id.
  @Published var stills: [String: URL] = [:]
  @Published var tab: LibraryTab = .home
  /// In-progress items, newest first ("Continuar viendo").
  @Published var resumeEntries: [WebDAVEntry] = []
  /// Recently played items that are not in progress ("Vistos recientemente").
  @Published var recentEntries: [WebDAVEntry] = []
  /// Ids of the "Continuar viendo" entries that are the next episode after one that was finished.
  @Published var nextUp: Set<String> = []
  private var nextUpTask: Task<Void, Never>?

  private(set) var stack: [URL] = []
  private var trakt: [String: Double] = [:]
  private let client = WebDAVClient()
  private let finder = NextEpisodeFinder()

  var canGoUp: Bool { !stack.isEmpty }
  /// Progress saved in Trakt, keyed like `MetadataStore.key(for:)`.
  var traktMap: [String: Double] { trakt }

  func matches(_ entry: WebDAVEntry) -> Bool {
    filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter)
  }

  var visibleLibrary: [WebDAVEntry] {
    let shown = entries.filter(matches)
    func order(_ a: WebDAVEntry, _ b: WebDAVEntry) -> Bool {
      switch sort {
      case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
      case .nameDescending: return a.name.localizedStandardCompare(b.name) == .orderedDescending
      case .size: return (a.size ?? 0) > (b.size ?? 0)
      }
    }
    // Folders always come first, like in Finder.
    return shown.filter(\.isDirectory).sorted(by: order) + shown.filter { !$0.isDirectory }.sorted(by: order)
  }

  func start() {
    hasTMDB = TMDBConfig.isConfigured
    guard WebDAVConfig.isConfigured, let url = URL(string: WebDAVConfig.url) else {
      errorMessage = WebDAVError.notConfigured.localizedDescription
      entries = []
      return
    }
    stack = []
    load(url)
    loadRecents()
  }

  func reload() {
    Task {
      await MetadataStore.shared.forgetMisses()
      if tab == .library, let current { load(current) } else { start() }
    }
  }

  func goUp() {
    guard let previous = stack.popLast() else { return }
    load(previous)
  }

  func open(folder entry: WebDAVEntry) {
    guard let next = WebDAVClient.absoluteURL(forHref: entry.href) else { return }
    if let current { stack.append(current) }
    load(next)
  }

  /// Opens a folder coming from a list or the home screen, switching to the library tab.
  func jump(toFolder entry: WebDAVEntry) {
    guard let target = WebDAVClient.absoluteURL(forHref: entry.href), let root = URL(string: WebDAVConfig.url) else { return }
    tab = .library
    stack = target.path == root.path ? [] : [root]
    load(target)
  }

  private func load(_ url: URL) {
    current = url
    loading = true
    errorMessage = nil
    filter = ""
    Task {
      do {
        async let listing = client.list(url)
        async let saved = TraktAPI.shared.allSavedProgress()
        let (result, traktMap) = try await (listing, saved)
        trakt = traktMap
        entries = result
        loading = false
      } catch {
        entries = []
        loading = false
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  /// Builds "Continuar viendo" and "Vistos recientemente" from IINA's playback history, limited to the configured server.
  /// When an episode was finished (it is in the history but has no saved position left), its next episode is added
  /// to "Continuar viendo".
  func loadRecents() {
    guard let host = URL(string: WebDAVConfig.url)?.host else { return }
    let recent = HistoryController.shared.history
      .filter { !$0.url.isFileURL && $0.url.host == host }
      .sorted { $0.addedDate > $1.addedDate }
    var resume: [(date: Date, entry: WebDAVEntry)] = []
    var others: [WebDAVEntry] = []
    var finished: [(date: Date, url: URL, showKey: String, entryID: String)] = []
    // A series appears once: its most recent history item decides where (in progress -> "Continuar viendo",
    // finished -> "Vistos recientemente", plus its next episode in "Continuar viendo"). Older episodes are ignored.
    var decidedShows = Set<String>()
    for item in recent {
      let href = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? item.url.path
      let name = item.url.lastPathComponent
      guard !href.isEmpty, !name.isEmpty else { continue }
      let entry = WebDAVEntry(href: href, name: name, isDirectory: false, size: nil)
      let media = TraktMedia.parse(fileName: name, folders: Array(item.url.pathComponents.dropLast()))
      var showKey: String?
      if case let .episode(show, _, _)? = media { showKey = TraktMedia.normalize(show) }
      if let showKey {
        guard decidedShows.insert(showKey).inserted else { continue }
      }
      if let info = ProgressResolver.resolve(url: item.url, media: media, runtimeMinutes: nil, trakt: trakt),
         info.percent < 95 {
        resume.append((item.addedDate, entry))
        progress[entry.id] = info
      } else {
        others.append(entry)
        if let showKey { finished.append((item.addedDate, item.url, showKey, entry.id)) }
      }
    }
    resumeEntries = resume.prefix(40).map(\.entry)
    recentEntries = Array(others.prefix(60))
    nextUp = []

    nextUpTask?.cancel()
    guard !finished.isEmpty else { return }
    let base = resume
    nextUpTask = Task {
      var extra: [(date: Date, entry: WebDAVEntry)] = []
      var represented = Set<String>()       // finished entries whose series now shows its next episode instead
      for item in finished.prefix(8) {
        if Task.isCancelled { return }
        guard let next = await finder.next(after: item.url),
              !base.contains(where: { $0.entry.id == next.id }) else { continue }
        extra.append((item.date, next))
        represented.insert(item.entryID)
      }
      if Task.isCancelled || extra.isEmpty { return }
      resumeEntries = (base + extra).sorted { $0.date > $1.date }.prefix(40).map(\.entry)
      nextUp = Set(extra.map(\.entry.id))
      recentEntries = recentEntries.filter { !represented.contains($0.id) }   // don't show the same series twice
    }
  }

  /// Fetches poster/info and the saved position for a file. Called lazily by each visible card.
  func enrich(_ entry: WebDAVEntry) async {
    if entry.isDirectory {
      // A release folder: look up its poster by the title in its name.
      guard metadata[entry.id] == nil, let info = TraktMedia.folderTitle(entry.name) else { return }
      if let meta = await MetadataStore.shared.folderMetadata(title: info.title, year: info.year, isSeries: info.isSeries) {
        metadata[entry.id] = meta
      }
      return
    }
    // The folders the file lives in help when the file name has no show name (e.g. "S01E01.mkv").
    let folders = (WebDAVClient.absoluteURL(forHref: entry.href)?.pathComponents ?? []).dropLast()
    let media = TraktMedia.parse(fileName: entry.name, folders: Array(folders))
    var meta: MediaMetadata?
    if let media {
      meta = await MetadataStore.shared.metadata(for: media)
      if let meta { metadata[entry.id] = meta }
      // Series episodes get their own wide image for the shelves.
      if case let .episode(show, s, n) = media {
        let eps = await MetadataStore.shared.episodes(show: show, season: s)
        if let url = eps[n]?.stillLargeURL { stills[entry.id] = url }
      }
    }
    let url = WebDAVClient.absoluteURL(forHref: entry.href)
    if let info = ProgressResolver.resolve(url: url, media: media, runtimeMinutes: meta?.runtimeMinutes, trakt: trakt) {
      progress[entry.id] = info
    } else {
      progress[entry.id] = nil     // e.g. the position was reset
    }
  }

  /// Recomputes saved positions (after playing something, or when the window is shown again).
  func refreshProgress() async {
    trakt = await TraktAPI.shared.allSavedProgress()
    loadRecents()
    let listed = ListsStore.shared.lists.flatMap { $0.items.map(\.entry) }
    for entry in entries + resumeEntries + recentEntries + listed where !entry.isDirectory { await enrich(entry) }
  }
}

// MARK: - Views

struct LibraryView: View {
  let onPlay: (WebDAVEntry, Bool) -> Void

  @StateObject private var model = LibraryViewModel()
  @ObservedObject private var lists = ListsStore.shared
  @State private var selected: WebDAVEntry?
  @State private var seriesEntry: WebDAVEntry?
  @State private var showSettings = false
  @State private var settingsTab: WebDAVSettingsView.Tab = .server
  @State private var listToDelete: LibraryList?
  @FocusState private var searchFocused: Bool
  @State private var newListName = ""
  @State private var showNewList = false
  @State private var renaming: LibraryList?
  @State private var renameText = ""

  private let columns = [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 24, alignment: .top)]

  private var tabSelection: Binding<LibraryTab?> {
    Binding(get: { model.tab }, set: { if let value = $0 { model.tab = value } })
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar.frame(width: 220)
      Divider()
      VStack(spacing: 0) {
        header
        if !model.hasTMDB && model.errorMessage == nil {
          HStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").foregroundColor(.orange)
            Text("Añade tu clave de TMDB para ver carátulas, sinopsis y rating.").font(.caption)
            Button("Configurar") { settingsTab = .metadata; showSettings = true }
              .buttonStyle(.link).font(.caption)
            Spacer()
          }
          .padding(.horizontal, 24).padding(.bottom, 8)
        }
        content
      }
    }
    .background(LibraryBackground().ignoresSafeArea())
    .frame(minWidth: 760, minHeight: 460)
    .overlay(shortcutButtons)
    .sheet(isPresented: $showSettings, onDismiss: { model.start() }) { WebDAVSettingsView(initialTab: settingsTab) }
    .sheet(item: $selected) { entry in
      LibraryDetailView(entry: entry, meta: model.metadata[entry.id], progress: model.progress[entry.id],
                        onPlay: { fromStart in selected = nil; onPlay(entry, fromStart) },
                        onEpisodes: {
                          selected = nil
                          // Presenting a sheet right after dismissing another one needs a moment.
                          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { seriesEntry = entry }
                        },
                        onClose: { selected = nil })
    }
    .sheet(item: $seriesEntry) { entry in
      SeriesView(entry: entry, trakt: model.traktMap,
                 onPlay: { file, fromStart in seriesEntry = nil; onPlay(file, fromStart) },
                 onClose: { seriesEntry = nil })
    }
    .sheet(isPresented: $showNewList) { nameSheet(title: "Nueva lista", text: $newListName) {
      if let id = lists.create(name: newListName) { model.tab = .list(id) }
      newListName = ""
      showNewList = false
    } onCancel: { newListName = ""; showNewList = false } }
    .sheet(item: $renaming) { list in nameSheet(title: "Renombrar lista", text: $renameText) {
      lists.rename(list.id, to: renameText)
      renaming = nil
    } onCancel: { renaming = nil } }
    .confirmationDialog("¿Eliminar la lista «\(listToDelete?.name ?? "")»?",
                        isPresented: Binding(get: { listToDelete != nil }, set: { if !$0 { listToDelete = nil } }),
                        titleVisibility: .visible, presenting: listToDelete) { list in
      Button("Eliminar lista", role: .destructive) {
        if model.tab == .list(list.id) { model.tab = .home }
        lists.delete(list.id)
      }
      Button("Cancelar", role: .cancel) {}
    } message: { _ in
      Text("Las películas y series no se borran, solo la lista.")
    }
    .onReceive(NotificationCenter.default.publisher(for: .webdavLibraryDidShow)) { _ in
      Task { await model.refreshProgress() }
    }
    .onAppear {
      model.start()
      if !WebDAVConfig.isConfigured { showSettings = true }   // first run: ask for the server
    }
  }

  // MARK: Sidebar and header

  private var sidebar: some View {
    VStack(spacing: 0) {
      List(selection: tabSelection) {
        Section {
          Label("Inicio", systemImage: "house").tag(LibraryTab.home)
          Label("Biblioteca", systemImage: "rectangle.stack").tag(LibraryTab.library)
        }
        Section("Listas") {
          ForEach(lists.lists) { list in
            Label(list.name, systemImage: "star").tag(LibraryTab.list(list.id))
              .contextMenu {
                Button("Renombrar…") { renameText = list.name; renaming = list }
                Button("Eliminar lista…", role: .destructive) { listToDelete = list }
              }
          }
        }
      }
      .listStyle(.sidebar)
      Divider()
      HStack {
        Button { showNewList = true } label: { Label("Nueva lista", systemImage: "plus") }
        Spacer()
        Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Ajustes").accessibilityLabel("Ajustes")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 14).padding(.vertical, 10)
    }
  }

  private var title: String {
    switch model.tab {
    case .home: return "Inicio"
    case .library:
      guard let current = model.current else { return "Biblioteca" }
      let name = (current.path.removingPercentEncoding ?? current.path).split(separator: "/").last.map(String.init)
      return name ?? "Biblioteca"
    case .list(let id): return lists.list(id)?.name ?? "Lista"
    }
  }

  /// Path of the folder being shown, under the title (the title alone only names the last folder).
  private var folderPath: String? {
    guard model.tab == .library, let path = model.current?.path else { return nil }
    let decoded = path.removingPercentEncoding ?? path
    let count = model.entries.count
    let items = count == 1 ? "1 elemento" : "\(count) elementos"
    return decoded == "/" ? (count > 0 ? items : nil) : (count > 0 ? "\(items) · \(decoded)" : decoded)
  }

  private var header: some View {
    HStack(spacing: 12) {
      if model.tab == .library && model.canGoUp {
        Button { model.goUp() } label: { Image(systemName: "chevron.left") }
          .help("Subir un nivel (⌘[)").accessibilityLabel("Subir un nivel")
          .keyboardShortcut("[", modifiers: .command)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
        if let folderPath {
          Text(folderPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
        }
      }
      Spacer()
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField("Buscar", text: $model.filter)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onExitCommand { model.filter = ""; searchFocused = false }     // Esc clears the search
        if !model.filter.isEmpty {
          Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundColor(.secondary).accessibilityLabel("Borrar búsqueda")
        }
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
      .frame(width: 240)
      if model.tab == .library {
        Menu {
          Picker("Ordenar por", selection: $model.sort) {
            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.inline)
        } label: { Image(systemName: "arrow.up.arrow.down") }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .help("Ordenar").accessibilityLabel("Ordenar")
      }
      Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
        .help("Actualizar (⌘R)").accessibilityLabel("Actualizar")
        .keyboardShortcut("r", modifiers: .command)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 14))
    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
  }

  /// Keyboard shortcuts without a visible button. ⌘1 is taken by IINA's "Normal Size", so sections use ⌥⌘1/⌥⌘2.
  private var shortcutButtons: some View {
    ZStack {
      Button("Buscar") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
      Button("Inicio") { model.tab = .home }.keyboardShortcut("1", modifiers: [.command, .option])
      Button("Biblioteca") { model.tab = .library }.keyboardShortcut("2", modifiers: [.command, .option])
    }
    .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
  }

  private func nameSheet(title: String, text: Binding<String>, onOK: @escaping () -> Void,
                         onCancel: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      TextField("Nombre", text: text).textFieldStyle(.roundedBorder).onSubmit(onOK)
      HStack {
        Spacer()
        Button("Cancelar", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Aceptar", action: onOK).keyboardShortcut(.defaultAction)
          .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(20).frame(width: 340)
  }

  // MARK: Content

  @ViewBuilder
  private var content: some View {
    switch model.tab {
    case .home: homeContent
    case .library: libraryContent
    case .list(let id): listContent(id)
    }
  }

  private func grid(_ items: [WebDAVEntry]) -> some View {
    LazyVGrid(columns: columns, spacing: 28) {
      ForEach(items) { entry in
        LibraryCard(entry: entry, meta: model.metadata[entry.id], progress: model.progress[entry.id],
                    badge: model.nextUp.contains(entry.id) ? "Siguiente episodio" : nil,
                    menuContent: listMenu(for: entry))
          .onTapGesture { tapped(entry) }
          .contextMenu { listMenu(for: entry) }
          .task { await model.enrich(entry) }
      }
    }
  }

  private func tapped(_ entry: WebDAVEntry) {
    if entry.isDirectory {
      model.tab == .library ? model.open(folder: entry) : model.jump(toFolder: entry)
    } else {
      selected = entry
    }
  }

  @ViewBuilder
  private func listMenu(for entry: WebDAVEntry) -> some View {
    if entry.isDirectory || TraktMedia.parse(fileName: entry.name, folders: []).map({ if case .episode = $0 { return true } else { return false } }) == true {
      Button("Ver temporadas y capítulos…") { seriesEntry = entry }
      Divider()
    }
    ForEach(lists.lists) { list in
      let inList = lists.contains(entry, in: list.id)
      Button(inList ? "Quitar de \(list.name)" : "Agregar a \(list.name)") { lists.toggle(entry, in: list.id) }
    }
    Button("Nueva lista…") { showNewList = true }
  }

  /// A horizontal row of cards, like the shelves in Apple's TV app.
  private func shelf(_ title: String, _ items: [WebDAVEntry], wide: Bool) -> some View {
    let shown = items.filter(model.matches)
    return Group {
      if !shown.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          Text(title).font(.title3.bold()).padding(.horizontal, 24)
          ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 18) {
              ForEach(shown) { entry in
                Group {
                  if wide {
                    ShelfCard(entry: entry, meta: model.metadata[entry.id], still: model.stills[entry.id],
                              progress: model.progress[entry.id],
                              badge: model.nextUp.contains(entry.id) ? "Siguiente episodio" : nil,
                              menuContent: listMenu(for: entry))
                  } else {
                    LibraryCard(entry: entry, meta: model.metadata[entry.id], progress: model.progress[entry.id],
                                menuContent: listMenu(for: entry)).frame(width: 150)
                  }
                }
                .onTapGesture { tapped(entry) }
                .contextMenu { listMenu(for: entry) }
                .task { await model.enrich(entry) }
              }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
          }
        }
      }
    }
  }

  /// What the hero features: the first item to continue, otherwise the most recent one.
  private var heroEntry: WebDAVEntry? { model.resumeEntries.first ?? model.recentEntries.first }

  private var homeContent: some View {
    let nothing = model.resumeEntries.isEmpty && model.recentEntries.isEmpty
    return Group {
      if nothing {
        stateView(icon: "play.rectangle.on.rectangle", "Aún no has visto nada de este servidor. Lo que empieces a ver aparecerá aquí.") {
          Button("Ir a la biblioteca") { model.tab = .library }
        }
        Spacer()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 26) {
            if let hero = heroEntry, model.filter.isEmpty {
              HeroView(entry: hero, meta: model.metadata[hero.id],
                       backdrop: model.metadata[hero.id]?.backdropURL ?? model.stills[hero.id],
                       progress: model.progress[hero.id], isNextUp: model.nextUp.contains(hero.id),
                       onPlay: { onPlay(hero, false) }, onDetails: { selected = hero })
                .padding(.horizontal, 24)
                .task { await model.enrich(hero) }
            }
            shelf("Continuar viendo", model.resumeEntries, wide: true)
            shelf("Vistos recientemente", model.recentEntries, wide: false)
            ForEach(lists.lists.filter { !$0.items.isEmpty }) { list in
              shelf("★ \(list.name)", list.items.map(\.entry), wide: false)
            }
          }
          .padding(.vertical, 8).padding(.bottom, 24)
        }
      }
    }
  }

  /// Centered message with an icon and optional actions, the way Apple's apps present empty and error states.
  private func stateView<Actions: View>(icon: String, tint: Color = .secondary, _ message: String,
                                        @ViewBuilder actions: () -> Actions) -> some View {
    VStack(spacing: 12) {
      Image(systemName: icon).font(.system(size: 34)).foregroundColor(tint)
      Text(message).multilineTextAlignment(.center).foregroundColor(.secondary).frame(maxWidth: 420)
      HStack { actions() }.padding(.top, 4)
    }
    .padding(40).frame(maxWidth: .infinity).padding(.top, 40)
  }

  @ViewBuilder
  private var libraryContent: some View {
    if let message = model.errorMessage {
      stateView(icon: "exclamationmark.triangle", tint: .orange, message) {
        Button("Reintentar") { model.reload() }
        Button("Abrir ajustes") { settingsTab = .server; showSettings = true }
      }
      Spacer()
    } else if model.loading {
      ProgressView("Cargando…").padding(40).frame(maxWidth: .infinity)
      Spacer()
    } else if model.visibleLibrary.isEmpty {
      if model.entries.isEmpty {
        stateView(icon: "folder", "Esta carpeta no tiene películas ni series.") { EmptyView() }
      } else {
        stateView(icon: "magnifyingglass", "Sin resultados para «\(model.filter)».") {
          Button("Borrar búsqueda") { model.filter = "" }
        }
      }
      Spacer()
    } else {
      ScrollView { grid(model.visibleLibrary).padding(24) }
    }
  }

  @ViewBuilder
  private func listContent(_ id: UUID) -> some View {
    let items = (lists.list(id)?.items ?? []).map(\.entry).filter(model.matches)
    if items.isEmpty {
      Text("Esta lista está vacía. Haz clic derecho sobre una película o carpeta y elige «Agregar a…».")
        .foregroundColor(.secondary).padding(24)
      Spacer()
    } else {
      ScrollView { grid(items).padding(24) }
    }
  }
}

struct PosterView: View {
  let url: URL?
  let isFolder: Bool

  var body: some View {
    ZStack {
      if isFolder && url == nil {
        FolderTile()
      } else {
        Rectangle().fill(Color.primary.opacity(0.08))
        if let url {
          AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
            if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
          }
        } else {
          placeholder
        }
      }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
  }

  private var placeholder: some View {
    Image(systemName: "film").font(.system(size: 34)).foregroundColor(.secondary.opacity(0.6))
  }
}

struct LibraryCard<MenuContent: View>: View {
  let entry: WebDAVEntry
  let meta: MediaMetadata?
  let progress: ProgressInfo?
  var badge: String? = nil
  /// Actions shown in the "…" button (the same as the context menu), so they don't depend on knowing about right-click.
  let menuContent: MenuContent

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      PosterView(url: meta?.posterURL, isFolder: entry.isDirectory)
        .overlay(alignment: .bottom) {
          if let progress, progress.percent > 0 {
            ProgressView(value: min(progress.percent, 100), total: 100)
              .progressViewStyle(.linear).padding(6)
          }
        }
        .overlay(alignment: .topTrailing) {
          if hovering {
            Menu { menuContent } label: {
              Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 22)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(6).help("Más opciones").accessibilityLabel("Más opciones")
          }
        }
        .overlay(alignment: .bottomTrailing) {
          // A folder that got a poster still has to look like a folder.
          if entry.isDirectory, meta?.posterURL != nil {
            Image(systemName: "folder.fill").font(.system(size: 15)).foregroundColor(.white)
              .shadow(color: .black.opacity(0.7), radius: 3).padding(8)
          }
        }
      Text(displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2)
      HStack(spacing: 6) {
        if let sub = subtitle { Text(sub).foregroundColor(.secondary) }
        if let rating = meta?.rating, rating > 0 { Text("⭐ \(String(format: "%.1f", rating))") }
      }.font(.caption)
      let tags = MediaQuality.compactBadges(for: entry.name)
      if !tags.isEmpty {
        HStack(spacing: 4) { ForEach(Array(tags.prefix(3)), id: \.self) { QualityBadge(text: $0) } }
      }
      if let badge {
        Text(badge).font(.caption2.weight(.semibold)).foregroundColor(.accentColor).lineLimit(1)
      } else if let progress {
        Text(progress.label).font(.caption2).foregroundColor(.accentColor).lineLimit(1)
      }
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }

  private var displayTitle: String { libraryDisplayTitle(entry: entry, meta: meta) }

  private var subtitle: String? {
    if let y = meta?.year { return String(y) }
    if let size = entry.size, !entry.isDirectory { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
    return nil
  }
}

struct LibraryDetailView: View {
  let entry: WebDAVEntry
  let meta: MediaMetadata?
  let progress: ProgressInfo?
  let onPlay: (Bool) -> Void
  let onEpisodes: () -> Void
  let onClose: () -> Void

  @ObservedObject private var lists = ListsStore.shared

  var body: some View {
    VStack(spacing: 0) {
      backdropHeader
      HStack(alignment: .top, spacing: 22) {
        // The poster overlaps the backdrop, as in Apple's TV app.
        PosterView(url: meta?.largePosterURL, isFolder: false).frame(width: 168)
          .offset(y: -84).padding(.bottom, -84)
        info
      }
      .padding(.horizontal, 26).padding(.bottom, 22)
    }
    .frame(width: 860, height: 540)
  }

  private var backdropHeader: some View {
    ZStack(alignment: .topTrailing) {
      Group {
        if let url = meta?.backdropURL {
          RemoteImage(url: url)
        } else {
          LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.15)],
                         startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      }
      .frame(height: 230).frame(maxWidth: .infinity).clipped()
      // Fade into the sheet background so the image melts into the content.
      LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .center, endPoint: .bottom)
        .frame(height: 230)
      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill").font(.system(size: 24)).foregroundColor(.white)
          .shadow(color: .black.opacity(0.6), radius: 3)
      }
      .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Cerrar (Esc)").accessibilityLabel("Cerrar")
      .padding(14)
    }
    .frame(height: 230)
  }

  private var info: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(meta?.title ?? entry.name).font(.system(size: 28, weight: .bold)).lineLimit(2)
      if let ep = meta?.episodeTitle, let s = meta?.season, let n = meta?.number {
        Text("Temporada \(s) · Episodio \(n) — \(ep)").foregroundColor(.secondary)
      } else if let tagline = meta?.tagline, !tagline.isEmpty {
        Text(tagline).italic().foregroundColor(.secondary).lineLimit(2)
      }
      HStack(spacing: 10) {
        if let y = meta?.year { Text(String(y)) }
        if let rt = meta?.runtimeMinutes, rt > 0 { Text("\(rt) min") }
        if let r = meta?.rating, r > 0 { Label(String(format: "%.1f", r), systemImage: "star.fill").foregroundColor(.yellow) }
        if let size = entry.size, size > 0 { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
      }.font(.system(size: 13)).foregroundColor(.secondary)
      let badges = MediaQuality.badges(for: entry.name)
      if !badges.isEmpty || !(meta?.genres.isEmpty ?? true) {
        HStack(spacing: 6) {
          ForEach(badges, id: \.self) { QualityBadge(text: $0) }
          if let genres = meta?.genres, !genres.isEmpty {
            Text(genres.prefix(3).joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
          }
        }
      }
      ScrollView {
        Text(meta?.overview.isEmpty == false ? meta!.overview : "Sin sinopsis disponible.")
          .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
      }
      if let progress {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(value: min(progress.percent, 100), total: 100)
          Text(progress.label + (progress.source == .trakt ? " · desde Trakt" : "")).font(.caption).foregroundColor(.secondary)
        }
      }
      HStack(spacing: 10) {
        Button { onPlay(false) } label: { Label(progress != nil ? "Continuar" : "Reproducir", systemImage: "play.fill") }
          .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        if progress != nil { Button("Desde el inicio") { onPlay(true) }.controlSize(.large) }
        if meta?.season != nil { Button("Capítulos") { onEpisodes() }.controlSize(.large) }
        Menu("★ Listas") {
          ForEach(lists.lists) { list in
            Button((lists.contains(entry, in: list.id) ? "✓ " : "") + list.name) { lists.toggle(entry, in: list.id) }
          }
        }.fixedSize().controlSize(.large)
      }
    }
  }
}

// MARK: - Background (same material IINA uses for its welcome window)

struct VisualEffectBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .underWindowBackground
    view.state = .active
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct LibraryBackground: View {
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    ZStack {
      VisualEffectBackground()
      LinearGradient(colors: scheme == .dark ? [Color.black.opacity(0.4), Color.black.opacity(0.1)]
                                             : [Color.black.opacity(0.1), Color.clear],
                     startPoint: .top, endPoint: .bottom)
    }
  }
}

// MARK: - Settings

struct WebDAVSettingsView: View {
  enum Tab: String, CaseIterable, Identifiable {
    case server, playback, metadata, accounts
    var id: String { rawValue }
  }

  @Environment(\.presentationMode) private var presentation
  @State private var url = WebDAVConfig.url
  @State private var user = WebDAVConfig.user
  @State private var password = WebDAVConfig.password
  @State private var openOnLaunch = WebDAVConfig.openOnLaunch
  @State private var tmdbKey = TMDBConfig.apiKey
  @State private var nuvioURL = NuvioConfig.backendURL
  @State private var nuvioKey = NuvioConfig.anonKey
  @State private var nuvioEmail = NuvioConfig.email
  @State private var nuvioPassword = NuvioConfig.password
  @State private var nuvioProfile = NuvioConfig.profileIndex
  @State private var nuvioEnabled = NuvioConfig.enabled
  @State private var nuvioStatus = ""
  @State private var nuvioBusy = false
  @State private var assistNext = AssistConfig.showNext
  @State private var assistAutoplay = AssistConfig.autoplayNext
  @State private var assistSkip = AssistConfig.skipIntro
  @State private var assistSeconds = AssistConfig.skipSeconds
  @State private var traktClientId = TraktConfig.clientId
  @State private var traktSecret = TraktConfig.clientSecret
  @State private var traktEnabled = TraktConfig.enabled
  @State private var traktConnected = TraktConfig.isConnected
  @State private var traktStatus = ""
  @State private var connecting = false

  @State private var tab: Tab

  init(initialTab: Tab = .server) { _tab = State(initialValue: initialTab) }

  /// An empty address is allowed (nothing configured yet); anything else must be a usable http(s) URL.
  private var urlValid: Bool {
    let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return true }
    guard let u = URL(string: text), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
          u.host != nil else { return false }
    return true
  }

  private func hint(_ text: String) -> some View {
    Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
  }

  private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) { content() }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      // A segmented control (like Apple's own settings sheets) instead of TabView, which collapses inside a sheet on macOS.
      Picker("", selection: $tab) {
        Text("Servidor").tag(Tab.server)
        Text("Reproducción").tag(Tab.playback)
        Text("Carátulas").tag(Tab.metadata)
        Text("Cuentas").tag(Tab.accounts)
      }
      .pickerStyle(.segmented).labelsHidden()
      .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
      Group {
        switch tab {
        case .server: serverTab
        case .playback: playbackTab
        case .metadata: metadataTab
        case .accounts: accountsTab
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      Divider()
      HStack {
        Spacer()
        Button("Cancelar") { presentation.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction)
        Button("Guardar") { save(); presentation.wrappedValue.dismiss() }
          .keyboardShortcut(.defaultAction).disabled(!urlValid)
      }
      .padding(14)
    }
    .frame(width: 580, height: 520)
  }

  // MARK: Tabs

  private var serverTab: some View {
    page {
      Text("Tu biblioteca").font(.headline)
      hint("La carpeta de tu servidor WebDAV que contiene tus películas y series.")
      TextField("https://servidor.com/dav/peliculas/", text: $url).textFieldStyle(.roundedBorder)
      if !urlValid {
        Label("La dirección debe empezar con http:// o https://", systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundColor(.orange)
      }
      TextField("Usuario", text: $user).textFieldStyle(.roundedBorder)
      SecureField("Contraseña", text: $password).textFieldStyle(.roundedBorder)
      hint("La contraseña se guarda en el Llavero de macOS, no en un archivo.")
      Divider().padding(.vertical, 2)
      Toggle("Abrir la biblioteca al iniciar IINA", isOn: $openOnLaunch)
    }
  }

  private var playbackTab: some View {
    page {
      Text("Al reproducir series").font(.headline)
      Toggle("Mostrar «Siguiente episodio» cuando empiezan los créditos", isOn: $assistNext)
      Toggle("Reproducir el siguiente episodio automáticamente", isOn: $assistAutoplay)
        .disabled(!assistNext).padding(.leading, 18)
      Divider().padding(.vertical, 2)
      Toggle("Mostrar el botón «Saltar intro»", isOn: $assistSkip)
      Stepper("Si el archivo no tiene capítulos, saltar \(assistSeconds) s", value: $assistSeconds, in: 10...240, step: 5)
        .disabled(!assistSkip).padding(.leading, 18)
      hint("El botón usa los capítulos «Intro» u «Opening» del archivo cuando existen.")
    }
  }

  private var metadataTab: some View {
    page {
      Text("Carátulas, sinopsis y rating").font(.headline)
      hint("La biblioteca consulta TMDB para mostrar las carátulas. Necesitas una clave gratuita; sirve la clave v3 o el token de lectura v4.")
      SecureField("Clave de TMDB", text: $tmdbKey).textFieldStyle(.roundedBorder)
      Link("Obtener una clave gratuita en themoviedb.org", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
        .font(.caption)
    }
  }

  private var accountsTab: some View {
    page {
      GroupBox(label: Text("Nuvio").font(.headline)) {
        VStack(alignment: .leading, spacing: 10) {
          hint("Lo que veas aquí aparece en Nuvio web y en tu celular, con el minuto exacto. Usa la dirección y la clave pública del servicio que usa tu Nuvio.")
          TextField("Dirección del servicio (https://…)", text: $nuvioURL).textFieldStyle(.roundedBorder)
          SecureField("Clave pública del servicio", text: $nuvioKey).textFieldStyle(.roundedBorder)
          TextField("Correo de tu cuenta de Nuvio", text: $nuvioEmail).textFieldStyle(.roundedBorder)
          SecureField("Contraseña de tu cuenta de Nuvio", text: $nuvioPassword).textFieldStyle(.roundedBorder)
          Stepper("Perfil de Nuvio: \(nuvioProfile)", value: $nuvioProfile, in: 1...6)
          Toggle("Enviar el progreso a Nuvio", isOn: $nuvioEnabled)
          HStack {
            Button(nuvioBusy ? "Probando…" : "Probar conexión") { testNuvio() }
              .disabled(nuvioBusy || nuvioURL.isEmpty || nuvioKey.isEmpty || nuvioEmail.isEmpty || nuvioPassword.isEmpty)
            if nuvioBusy { ProgressView().controlSize(.small) }
            Text(nuvioStatus).font(.caption).foregroundColor(.secondary).lineLimit(3)
          }
          if !NuvioConfig.lastStatus.isEmpty {
            hint("Último envío: \(NuvioConfig.lastStatus)")
          }
        }.padding(8)
      }
      GroupBox(label: Text("Trakt").font(.headline)) {
        VStack(alignment: .leading, spacing: 10) {
          hint("Opcional. Crea tu propia app en Trakt con la dirección de redirección urn:ietf:wg:oauth:2.0:oob y pega su Client ID; el secret es opcional.")
          Link("Crear una app en Trakt", destination: URL(string: "https://trakt.tv/oauth/applications/new")!).font(.caption)
          TextField("Client ID", text: $traktClientId).textFieldStyle(.roundedBorder)
          SecureField("Client Secret (opcional)", text: $traktSecret).textFieldStyle(.roundedBorder)
          Toggle("Enviar el progreso a Trakt", isOn: $traktEnabled)
          HStack {
            if traktConnected {
              Label("Conectado", systemImage: "checkmark.circle.fill").foregroundColor(.green)
              Button("Desconectar") { TraktAPI.shared.disconnect(); traktConnected = false; traktStatus = "" }
            } else {
              Button(connecting ? "Esperando aprobación…" : "Conectar Trakt") { connect() }
                .disabled(connecting || traktClientId.isEmpty)
              if connecting { ProgressView().controlSize(.small) }
            }
            Text(traktStatus).font(.caption).foregroundColor(.secondary).lineLimit(2)
          }
        }.padding(8)
      }
    }
  }

  private func save() {
    WebDAVConfig.url = url
    WebDAVConfig.user = user
    WebDAVConfig.password = password
    WebDAVConfig.openOnLaunch = openOnLaunch
    TMDBConfig.apiKey = tmdbKey
    NuvioConfig.backendURL = nuvioURL
    NuvioConfig.anonKey = nuvioKey
    NuvioConfig.email = nuvioEmail
    NuvioConfig.password = nuvioPassword
    NuvioConfig.profileIndex = nuvioProfile
    NuvioConfig.enabled = nuvioEnabled
    AssistConfig.showNext = assistNext
    AssistConfig.autoplayNext = assistAutoplay
    AssistConfig.skipIntro = assistSkip
    AssistConfig.skipSeconds = assistSeconds
    TraktConfig.clientId = traktClientId
    TraktConfig.clientSecret = traktSecret
    TraktConfig.enabled = traktEnabled
  }

  private func testNuvio() {
    NuvioConfig.backendURL = nuvioURL
    NuvioConfig.anonKey = nuvioKey
    NuvioConfig.email = nuvioEmail
    NuvioConfig.password = nuvioPassword
    NuvioAPI.shared.disconnect()
    nuvioBusy = true
    nuvioStatus = "Iniciando sesión…"
    Task {
      do {
        try await NuvioAPI.shared.signIn()
        let profiles = try await NuvioAPI.shared.profiles()
        let list = profiles.map { "\($0.index): \($0.name)" }.joined(separator: ", ")
        await MainActor.run { nuvioStatus = "● Conectado. Perfiles: \(list.isEmpty ? "ninguno" : list)"; nuvioBusy = false }
      } catch {
        await MainActor.run {
          nuvioStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          nuvioBusy = false
        }
      }
    }
  }

  private func connect() {
    // Credentials must be stored before the API can use them.
    TraktConfig.clientId = traktClientId
    TraktConfig.clientSecret = traktSecret
    connecting = true
    traktStatus = "Pidiendo código…"
    Task {
      do {
        let code = try await TraktAPI.shared.requestDeviceCode()
        await MainActor.run {
          traktStatus = "Ve a \(code.url) e introduce el código: \(code.userCode)"
          if let u = URL(string: code.url) { NSWorkspace.shared.open(u) }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(code.userCode, forType: .string)
        }
        try await TraktAPI.shared.waitForAuthorization(code)
        await MainActor.run { traktConnected = true; traktStatus = ""; connecting = false }
      } catch {
        await MainActor.run {
          traktStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
          connecting = false
        }
      }
    }
  }
}
