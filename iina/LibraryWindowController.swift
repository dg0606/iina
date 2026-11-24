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
    if let auth = WebDAVConfig.basicAuthHeader {
      player.mpv.setString(MPVOption.Network.httpHeaderFields, "Authorization: \(auth)")
    }
    player.openURLString(url.absoluteString)
    window?.close()
  }
}

// MARK: - View model

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
  @Published var tab: LibraryTab = .home
  /// In-progress items, newest first ("Continuar viendo").
  @Published var resumeEntries: [WebDAVEntry] = []
  /// Recently played items that are not in progress ("Vistos recientemente").
  @Published var recentEntries: [WebDAVEntry] = []

  private(set) var stack: [URL] = []
  private var trakt: [String: Double] = [:]
  private let client = WebDAVClient()

  var canGoUp: Bool { !stack.isEmpty }

  func matches(_ entry: WebDAVEntry) -> Bool {
    filter.isEmpty || entry.name.localizedCaseInsensitiveContains(filter)
  }

  var visibleLibrary: [WebDAVEntry] { entries.filter(matches) }

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
  func loadRecents() {
    guard let host = URL(string: WebDAVConfig.url)?.host else { return }
    let recent = HistoryController.shared.history
      .filter { !$0.url.isFileURL && $0.url.host == host }
      .sorted { $0.addedDate > $1.addedDate }
    var resume: [WebDAVEntry] = []
    var others: [WebDAVEntry] = []
    for item in recent {
      let href = URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? item.url.path
      let name = item.url.lastPathComponent
      guard !href.isEmpty, !name.isEmpty else { continue }
      let entry = WebDAVEntry(href: href, name: name, isDirectory: false, size: nil)
      let media = TraktMedia.parse(fileName: name, folders: Array(item.url.pathComponents.dropLast()))
      if let info = ProgressResolver.resolve(url: item.url, media: media, runtimeMinutes: nil, trakt: trakt),
         info.percent < 95 {
        resume.append(entry)
        progress[entry.id] = info
      } else {
        others.append(entry)
      }
    }
    resumeEntries = Array(resume.prefix(40))
    recentEntries = Array(others.prefix(60))
  }

  /// Fetches poster/info and the saved position for a file. Called lazily by each visible card.
  func enrich(_ entry: WebDAVEntry) async {
    guard !entry.isDirectory else { return }
    // The folders the file lives in help when the file name has no show name (e.g. "S01E01.mkv").
    let folders = (WebDAVClient.absoluteURL(forHref: entry.href)?.pathComponents ?? []).dropLast()
    let media = TraktMedia.parse(fileName: entry.name, folders: Array(folders))
    var meta: MediaMetadata?
    if let media {
      meta = await MetadataStore.shared.metadata(for: media)
      if let meta { metadata[entry.id] = meta }
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
  @State private var showSettings = false
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
          Text("Añade tu API key de TMDB en Ajustes para ver carátulas, sinopsis y rating.")
            .font(.caption).foregroundColor(.orange).padding(.horizontal, 24).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        content
      }
    }
    .background(LibraryBackground().ignoresSafeArea())
    .frame(minWidth: 760, minHeight: 460)
    .sheet(isPresented: $showSettings, onDismiss: { model.start() }) { WebDAVSettingsView() }
    .sheet(item: $selected) { entry in
      LibraryDetailView(entry: entry, meta: model.metadata[entry.id], progress: model.progress[entry.id],
                        onPlay: { fromStart in selected = nil; onPlay(entry, fromStart) },
                        onClose: { selected = nil })
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
                Button("Eliminar lista", role: .destructive) {
                  if model.tab == .list(list.id) { model.tab = .home }
                  lists.delete(list.id)
                }
              }
          }
        }
      }
      .listStyle(.sidebar)
      Divider()
      HStack {
        Button { showNewList = true } label: { Label("Nueva lista", systemImage: "plus") }
        Spacer()
        Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Ajustes")
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

  private var header: some View {
    HStack(spacing: 12) {
      if model.tab == .library && model.canGoUp {
        Button { model.goUp() } label: { Image(systemName: "chevron.left") }.help("Subir")
      }
      Text(title).font(.system(size: 26, weight: .bold)).lineLimit(1)
      Spacer()
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
        TextField("Buscar", text: $model.filter).textFieldStyle(.plain)
      }
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
      .frame(width: 240)
      Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Actualizar")
    }
    .buttonStyle(.borderless)
    .font(.system(size: 14))
    .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 12)
  }

  private func nameSheet(title: String, text: Binding<String>, onOK: @escaping () -> Void,
                         onCancel: @escaping () -> Void) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      TextField("Nombre", text: text).textFieldStyle(.roundedBorder).onSubmit(onOK)
      HStack {
        Spacer()
        Button("Cancelar", action: onCancel)
        Button("Aceptar", action: onOK).keyboardShortcut(.defaultAction)
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
        LibraryCard(entry: entry, meta: model.metadata[entry.id], progress: model.progress[entry.id])
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
    ForEach(lists.lists) { list in
      let inList = lists.contains(entry, in: list.id)
      Button(inList ? "Quitar de \(list.name)" : "Agregar a \(list.name)") { lists.toggle(entry, in: list.id) }
    }
    Button("Nueva lista…") { showNewList = true }
  }

  private func section(_ title: String, _ items: [WebDAVEntry]) -> some View {
    let shown = items.filter(model.matches)
    return Group {
      if !shown.isEmpty {
        Text(title).font(.title3.bold()).padding(.top, 4)
        grid(shown)
      }
    }
  }

  private var homeContent: some View {
    let nothing = model.resumeEntries.isEmpty && model.recentEntries.isEmpty
    return Group {
      if nothing {
        VStack(spacing: 12) {
          Text("Aún no has visto nada de este servidor.").foregroundColor(.secondary)
          Button("Ir a la biblioteca") { model.tab = .library }
        }.padding(40).frame(maxWidth: .infinity)
        Spacer()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            section("Continuar viendo", model.resumeEntries)
            section("Vistos recientemente", model.recentEntries)
          }.padding(24)
        }
      }
    }
  }

  @ViewBuilder
  private var libraryContent: some View {
    if let message = model.errorMessage {
      Text(message).foregroundColor(.red).padding(24).frame(maxWidth: .infinity, alignment: .leading)
      Spacer()
    } else if model.loading {
      ProgressView().padding(24)
      Spacer()
    } else if model.visibleLibrary.isEmpty {
      Text(model.entries.isEmpty ? "Carpeta vacía" : "Sin resultados").foregroundColor(.secondary).padding(24)
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
      Rectangle().fill(Color.primary.opacity(0.08))
      if let url {
        AsyncImage(url: url) { phase in
          if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
        }
      } else {
        placeholder
      }
    }
    .aspectRatio(2.0 / 3.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
  }

  private var placeholder: some View {
    Text(isFolder ? "📁" : "🎬").font(.system(size: 42))
  }
}

struct LibraryCard: View {
  let entry: WebDAVEntry
  let meta: MediaMetadata?
  let progress: ProgressInfo?

  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      PosterView(url: meta?.posterURL, isFolder: entry.isDirectory)
        .overlay(alignment: .bottom) {
          if let progress, progress.percent > 0 {
            ProgressView(value: min(progress.percent, 100), total: 100)
              .progressViewStyle(.linear).padding(6)
          }
        }
      Text(displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2)
      HStack(spacing: 6) {
        if let sub = subtitle { Text(sub).foregroundColor(.secondary) }
        if let rating = meta?.rating, rating > 0 { Text("⭐ \(String(format: "%.1f", rating))") }
      }.font(.caption)
      if let progress {
        Text(progress.label).font(.caption2).foregroundColor(.accentColor).lineLimit(1)
      }
    }
    .contentShape(Rectangle())
    .scaleEffect(hovering ? 1.03 : 1)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
  }

  private var displayTitle: String {
    if let meta {
      if let ep = meta.episodeTitle, let s = meta.season, let n = meta.number {
        return "\(meta.title) · S\(String(format: "%02d", s))E\(String(format: "%02d", n)) \(ep)"
      }
      return meta.title
    }
    return entry.name
  }

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
  let onClose: () -> Void

  @ObservedObject private var lists = ListsStore.shared

  var body: some View {
    HStack(alignment: .top, spacing: 20) {
      PosterView(url: meta?.largePosterURL, isFolder: false).frame(width: 220)
      VStack(alignment: .leading, spacing: 10) {
        Text(meta?.title ?? entry.name).font(.title2.bold())
        if let ep = meta?.episodeTitle, let s = meta?.season, let n = meta?.number {
          Text("Temporada \(s) · Episodio \(n) — \(ep)").foregroundColor(.secondary)
        }
        HStack(spacing: 12) {
          if let y = meta?.year { Text(String(y)) }
          if let rt = meta?.runtimeMinutes, rt > 0 { Text("\(rt) min") }
          if let r = meta?.rating, r > 0 { Text("⭐ \(String(format: "%.1f", r))/10") }
        }.foregroundColor(.secondary)
        if let genres = meta?.genres, !genres.isEmpty { Text(genres.joined(separator: " · ")).font(.caption) }
        ScrollView {
          Text(meta?.overview.isEmpty == false ? meta!.overview : "Sin sinopsis disponible.")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let progress {
          VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(progress.percent, 100), total: 100)
            Text(progress.label + (progress.source == .trakt ? " · desde Trakt" : "")).font(.caption)
          }
        }
        HStack {
          Button(progress != nil ? "▶︎ Continuar" : "▶︎ Reproducir") { onPlay(false) }
            .keyboardShortcut(.defaultAction)
          if progress != nil { Button("Desde el inicio") { onPlay(true) } }
          Menu("★ Listas") {
            ForEach(lists.lists) { list in
              Button((lists.contains(entry, in: list.id) ? "✓ " : "") + list.name) { lists.toggle(entry, in: list.id) }
            }
          }.fixedSize()
          Spacer()
          Button("Cerrar", action: onClose)
        }
      }
    }
    .padding(22)
    .frame(width: 700, height: 400)
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
  @Environment(\.presentationMode) private var presentation
  @State private var url = WebDAVConfig.url
  @State private var user = WebDAVConfig.user
  @State private var password = WebDAVConfig.password
  @State private var openOnLaunch = WebDAVConfig.openOnLaunch
  @State private var tmdbKey = TMDBConfig.apiKey
  @State private var traktClientId = TraktConfig.clientId
  @State private var traktSecret = TraktConfig.clientSecret
  @State private var traktEnabled = TraktConfig.enabled
  @State private var traktConnected = TraktConfig.isConnected
  @State private var traktStatus = ""
  @State private var connecting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Servidor WebDAV").font(.headline)
      TextField("https://servidor.com/dav/peliculas/", text: $url).textFieldStyle(.roundedBorder)
      TextField("Usuario", text: $user).textFieldStyle(.roundedBorder)
      SecureField("Contraseña", text: $password).textFieldStyle(.roundedBorder)
      Toggle("Abrir la biblioteca al iniciar", isOn: $openOnLaunch)

      Divider().padding(.vertical, 4)
      Text("TMDB (carátulas, sinopsis y rating)").font(.headline)
      Text("API key gratuita en themoviedb.org → Ajustes → API. Acepta la clave v3 o el token de lectura v4.")
        .font(.caption).foregroundColor(.secondary)
      SecureField("API key de TMDB", text: $tmdbKey).textFieldStyle(.roundedBorder)

      Divider().padding(.vertical, 4)
      Text("Trakt (progreso sincronizado)").font(.headline)
      Text("Crea una app en trakt.tv/oauth/applications (redirect: urn:ietf:wg:oauth:2.0:oob) y pega sus credenciales.")
        .font(.caption).foregroundColor(.secondary)
      TextField("Client ID", text: $traktClientId).textFieldStyle(.roundedBorder)
      SecureField("Client Secret", text: $traktSecret).textFieldStyle(.roundedBorder)
      Toggle("Enviar progreso a Trakt", isOn: $traktEnabled)
      HStack {
        if traktConnected {
          Text("● Conectado").foregroundColor(.green)
          Button("Desconectar") { TraktAPI.shared.disconnect(); traktConnected = false; traktStatus = "" }
        } else {
          Button(connecting ? "Esperando aprobación…" : "Conectar Trakt") { connect() }
            .disabled(connecting || traktClientId.isEmpty || traktSecret.isEmpty)
        }
        Text(traktStatus).font(.caption).foregroundColor(.secondary).lineLimit(2)
      }

      HStack {
        Spacer()
        Button("Cancelar") { presentation.wrappedValue.dismiss() }
        Button("Guardar") {
          save()
          presentation.wrappedValue.dismiss()
        }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480)
  }

  private func save() {
    WebDAVConfig.url = url
    WebDAVConfig.user = user
    WebDAVConfig.password = password
    WebDAVConfig.openOnLaunch = openOnLaunch
    TMDBConfig.apiKey = tmdbKey
    TraktConfig.clientId = traktClientId
    TraktConfig.clientSecret = traktSecret
    TraktConfig.enabled = traktEnabled
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
