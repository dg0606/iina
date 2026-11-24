//
//  PlaybackAssist.swift
//  iina
//
//  Playback helpers for episodes played from the WebDAV library: "Saltar intro" and the
//  "Siguiente episodio" strip with automatic playback of the next episode.
//

import Cocoa

// MARK: - Settings

enum AssistConfig {
  private static func bool(_ key: String, default value: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? value
  }

  static var showNext: Bool {
    get { bool("assistShowNext", default: true) }
    set { UserDefaults.standard.set(newValue, forKey: "assistShowNext") }
  }
  static var autoplayNext: Bool {
    get { bool("assistAutoplayNext", default: true) }
    set { UserDefaults.standard.set(newValue, forKey: "assistAutoplayNext") }
  }
  static var skipIntro: Bool {
    get { bool("assistSkipIntro", default: true) }
    set { UserDefaults.standard.set(newValue, forKey: "assistSkipIntro") }
  }
  /// Seconds skipped by "Saltar intro" when the file has no intro chapter.
  static var skipSeconds: Int {
    get { max(10, UserDefaults.standard.object(forKey: "assistSkipSeconds") as? Int ?? 85) }
    set { UserDefaults.standard.set(newValue, forKey: "assistSkipSeconds") }
  }
}

// MARK: - Next episode lookup (shared with the library)

/// Finds the file that follows an episode: the next file of its folder, or the first file of the next season folder.
final class NextEpisodeFinder {
  private let client = WebDAVClient()
  private var cache: [String: [WebDAVEntry]] = [:]

  private func list(_ url: URL) async -> [WebDAVEntry]? {
    if let hit = cache[url.absoluteString] { return hit }
    guard let result = try? await client.list(url) else { return nil }
    cache[url.absoluteString] = result
    return result
  }

  func next(after fileURL: URL) async -> WebDAVEntry? {
    let parent = fileURL.deletingLastPathComponent()
    guard let siblings = await list(parent) else { return nil }
    let files = siblings.filter { !$0.isDirectory }
    guard let i = files.firstIndex(where: { $0.name == fileURL.lastPathComponent }) else { return nil }
    if i + 1 < files.count { return files[i + 1] }

    // Last file of the folder: try the next season folder of the same show.
    let folderName = parent.lastPathComponent
    guard let base = TraktMedia.seasonFolderBase(folderName) else { return nil }
    guard let folders = await list(parent.deletingLastPathComponent())?.filter(\.isDirectory),
          let j = folders.firstIndex(where: { $0.name == folderName }), j + 1 < folders.count else { return nil }
    let nextFolder = folders[j + 1]
    guard TraktMedia.seasonFolderBase(nextFolder.name) == base,
          let nextURL = WebDAVClient.absoluteURL(forHref: nextFolder.href),
          let inside = await list(nextURL) else { return nil }
    return inside.first { !$0.isDirectory }
  }
}

// MARK: - Assistant (one per player)

final class PlaybackAssist {
  private unowned let player: PlayerCore
  private let finder = NextEpisodeFinder()

  private struct NextInfo {
    let entry: WebDAVEntry
    let label: String        // "T1:E2"
    let title: String?
  }

  private var token = UUID()                       // invalidates async work of a previous file
  private var next: NextInfo?
  private var nextDismissed = false
  private var introRange: (start: Double, end: Double)?
  private var creditsStart: Double?
  private var chaptersChecked = false
  private var introUsed = false
  private var isEpisode = false

  private static let introRegex = try! NSRegularExpression(
    pattern: #"(?:^|[\s\-_\(\[])(intro|opening|op|apertura|título|titulo|title sequence|main title|credits? sequence)(?:$|[\s\-_\)\]\d])"#,
    options: [.caseInsensitive])
  private static let creditsRegex = try! NSRegularExpression(
    pattern: #"(?:^|[\s\-_\(\[])(credits?|ending|ed|outro|end credits|créditos|creditos|cierre)(?:$|[\s\-_\)\]\d])"#,
    options: [.caseInsensitive])

  init(player: PlayerCore) { self.player = player }

  private var overlay: AssistOverlayView? { player.mainWindow.loaded ? player.mainWindow.assistOverlay : nil }

  // MARK: Events from PlayerCore

  /// A file finished loading.
  func fileLoaded() {
    token = UUID()
    next = nil
    nextDismissed = false
    introRange = nil
    creditsStart = nil
    chaptersChecked = false
    introUsed = false
    isEpisode = false
    overlay?.configure(skip: nil, next: nil)

    guard AssistConfig.showNext || AssistConfig.skipIntro,
          let url = player.info.currentURL, !url.isFileURL,
          url.host == URL(string: WebDAVConfig.url)?.host,
          case let .episode(show, season, _)? = TraktMedia.parse(
            fileName: url.lastPathComponent, folders: Array(url.pathComponents.dropLast())) else { return }
    isEpisode = true

    let myToken = token
    Task {
      guard let entry = await finder.next(after: url) else { return }
      var label = "Siguiente"
      var title = TraktMedia.episodeTitle(fromFileName: entry.name)
      if case let .episode(nextShow, s, n)? = TraktMedia.parse(
          fileName: entry.name, folders: Array(url.pathComponents.dropLast())) {
        label = "T\(s):E\(n)"
        if let name = await MetadataStore.shared.episodes(show: nextShow, season: s)[n]?.name { title = name }
      } else {
        _ = season; _ = show
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.token == myToken else { return }
        self.next = NextInfo(entry: entry, label: label, title: title)
      }
    }
  }

  /// Called repeatedly while the video plays (main thread).
  func tick() {
    guard isEpisode, let overlay else { return }
    let pos = player.mpv.getDouble(MPVProperty.timePos)
    let duration = player.mpv.getDouble(MPVProperty.duration)
    guard duration > 0 else { return }
    detectChapters(duration: duration)

    var skip: String?
    if AssistConfig.skipIntro, !introUsed {
      if let r = introRange {
        if pos >= r.start - 0.5 && pos < r.end - 2 { skip = "Saltar intro" }
      } else if chaptersChecked, duration > 600, pos < 240 {
        skip = "Saltar \(AssistConfig.skipSeconds) s"
      }
    }

    var nextStrip: (label: String, title: String?)?
    if AssistConfig.showNext, !nextDismissed, let next {
      let start = creditsStart.map { max($0, duration * 0.6) } ?? max(duration - 45, duration * 0.6)
      if pos >= start { nextStrip = (next.label, next.title) }
    }
    overlay.configure(skip: skip, next: nextStrip)
  }

  /// mpv reached the end of the file (not a stop command).
  func reachedEnd() {
    guard isEpisode, AssistConfig.autoplayNext, !nextDismissed, next != nil else { return }
    TraktScrobbler.shared.finished()
    NuvioSync.shared.finished()
    playNext()
  }

  // MARK: Actions (from the overlay)

  func skipIntro() {
    introUsed = true
    if let r = introRange {
      player.seek(absoluteSecond: r.end)
    } else {
      player.seek(absoluteSecond: player.mpv.getDouble(MPVProperty.timePos) + Double(AssistConfig.skipSeconds))
    }
    overlay?.configure(skip: nil, next: nil)
  }

  func playNext() {
    guard let next, let url = WebDAVClient.absoluteURL(forHref: next.entry.href) else { return }
    WebDAVConfig.applyAuth(to: player)
    overlay?.configure(skip: nil, next: nil)
    self.next = nil
    player.openURLString(url.absoluteString)
  }

  func dismissNext() {
    nextDismissed = true
    overlay?.configure(skip: nil, next: nil)
  }

  // MARK: Chapters

  private func detectChapters(duration: Double) {
    guard !chaptersChecked else { return }
    let chapters = player.info.chapters
    // Chapters are loaded asynchronously: wait for them for a few seconds before falling back.
    guard !chapters.isEmpty else {
      if player.mpv.getDouble(MPVProperty.timePos) > 8 { chaptersChecked = true }
      return
    }
    chaptersChecked = true
    for (i, chapter) in chapters.enumerated() {
      let title = chapter.title
      let range = NSRange(title.startIndex..., in: title)
      let end = i + 1 < chapters.count ? chapters[i + 1].time.second : duration
      if introRange == nil, Self.introRegex.firstMatch(in: title, range: range) != nil, end > chapter.time.second {
        introRange = (chapter.time.second, end)
      }
      if creditsStart == nil, i > 0, Self.creditsRegex.firstMatch(in: title, range: range) != nil,
         chapter.time.second > duration * 0.5 {
        creditsStart = chapter.time.second
      }
    }
  }
}

// MARK: - Overlay view

/// Transparent view over the video that hosts the "Saltar intro" button and the "Siguiente episodio" strip.
/// Clicks pass through everywhere except on its own controls.
final class AssistOverlayView: NSView {
  private weak var assist: PlaybackAssist?

  private let skipButton = NSButton()
  private let nextCard = NSVisualEffectView()
  private let nextLabel = NSTextField(labelWithString: "")
  private let nextTitle = NSTextField(labelWithString: "")

  init(assist: PlaybackAssist) {
    self.assist = assist
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    buildSkipButton()
    buildNextCard()
    skipButton.isHidden = true
    nextCard.isHidden = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let view = super.hitTest(point)
    return view === self ? nil : view
  }

  private func buildSkipButton() {
    skipButton.translatesAutoresizingMaskIntoConstraints = false
    skipButton.isBordered = false
    skipButton.wantsLayer = true
    skipButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    skipButton.layer?.cornerRadius = 8
    skipButton.layer?.borderWidth = 1
    skipButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
    skipButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
    skipButton.imagePosition = .imageLeading
    skipButton.contentTintColor = .white
    skipButton.target = self
    skipButton.action = #selector(skipClicked)
    addSubview(skipButton)
    // Sit above the playback controls when there is room; in a small window stay inside it.
    let preferredBottom = skipButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -130)
    preferredBottom.priority = .defaultLow
    NSLayoutConstraint.activate([
      skipButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      skipButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
      skipButton.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
      preferredBottom,
      skipButton.heightAnchor.constraint(equalToConstant: 38),
      skipButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
    ])
  }

  private func buildNextCard() {
    let preferredBottom = nextCard.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -130)
    preferredBottom.priority = .defaultLow
    nextCard.translatesAutoresizingMaskIntoConstraints = false
    nextCard.material = .hudWindow
    nextCard.blendingMode = .withinWindow
    nextCard.state = .active
    nextCard.wantsLayer = true
    nextCard.layer?.cornerRadius = 12
    nextCard.layer?.masksToBounds = true

    let header = NSTextField(labelWithString: "SIGUIENTE EPISODIO")
    header.font = .systemFont(ofSize: 10, weight: .semibold)
    header.textColor = .secondaryLabelColor
    nextLabel.font = .systemFont(ofSize: 15, weight: .bold)
    nextLabel.textColor = .labelColor
    nextTitle.font = .systemFont(ofSize: 12)
    nextTitle.textColor = .secondaryLabelColor
    nextTitle.lineBreakMode = .byTruncatingTail

    let play = NSButton(title: "Reproducir ahora", target: self, action: #selector(playClicked))
    play.bezelStyle = .rounded
    play.keyEquivalent = ""
    play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    play.imagePosition = .imageLeading
    let close = NSButton(title: "", target: self, action: #selector(dismissClicked))
    close.bezelStyle = .circular
    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar")
    close.toolTip = "No reproducir automáticamente el siguiente"

    let buttons = NSStackView(views: [play, close])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    let stack = NSStackView(views: [header, nextLabel, nextTitle, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.setCustomSpacing(10, after: nextTitle)
    stack.translatesAutoresizingMaskIntoConstraints = false
    nextCard.addSubview(stack)
    addSubview(nextCard)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: nextCard.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: nextCard.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: nextCard.topAnchor, constant: 14),
      stack.bottomAnchor.constraint(equalTo: nextCard.bottomAnchor, constant: -14),
      nextCard.widthAnchor.constraint(equalToConstant: 300),
      nextCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
      nextCard.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
      preferredBottom,
    ])
    let keepInside = nextCard.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8)
    keepInside.priority = .defaultHigh
    keepInside.isActive = true
  }

  /// Shows or hides each control; pass nil to hide.
  func configure(skip: String?, next: (label: String, title: String?)?) {
    if let skip {
      skipButton.title = "  \(skip)  "
      skipButton.attributedTitle = NSAttributedString(
        string: "  \(skip)  ",
        attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .semibold)])
    }
    set(skipButton, visible: skip != nil)
    if let next {
      nextLabel.stringValue = next.label
      nextTitle.stringValue = next.title ?? ""
      nextTitle.isHidden = (next.title ?? "").isEmpty
    }
    set(nextCard, visible: next != nil)
  }

  private func set(_ view: NSView, visible: Bool) {
    guard view.isHidden == visible else { return }
    if visible {
      view.alphaValue = 0
      view.isHidden = false
      NSAnimationContext.runAnimationGroup { $0.duration = 0.2; view.animator().alphaValue = 1 }
    } else {
      view.isHidden = true
    }
  }

  @objc private func skipClicked() { assist?.skipIntro() }
  @objc private func playClicked() { assist?.playNext() }
  @objc private func dismissClicked() { assist?.dismissNext() }
}
