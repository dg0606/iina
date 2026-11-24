//
//  LibrarySeries.swift
//  iina
//
//  Series browser: every season and episode of a show found on the WebDAV server, with titles, stills,
//  watched state and saved position, so the user can pick any episode.
//

import SwiftUI

struct EpisodeItem: Identifiable {
  let season: Int
  let number: Int
  let entry: WebDAVEntry
  var meta: EpisodeMeta?
  var progress: ProgressInfo?
  var watched = false

  var id: String { entry.href }
  var title: String {
    meta?.name ?? TraktMedia.episodeTitle(fromFileName: entry.name) ?? "Episodio \(number)"
  }
}

@MainActor
final class SeriesViewModel: ObservableObject {
  @Published var showTitle = ""
  @Published var showMeta: MediaMetadata?
  @Published var seasons: [Int: [EpisodeItem]] = [:]
  @Published var selectedSeason = 1
  @Published var loading = true
  @Published var message: String?
  /// The episode to continue with: the one in progress, or the first not watched after the last watched one.
  @Published var nextID: String?

  private let client = WebDAVClient()

  var seasonNumbers: [Int] { seasons.keys.sorted() }
  var nextItem: EpisodeItem? { seasons.values.joined().first { $0.id == nextID } }

  func load(_ entry: WebDAVEntry, trakt: [String: Double]) async {
    loading = true
    message = nil
    guard let file = await representativeFile(of: entry),
          let fileURL = WebDAVClient.absoluteURL(forHref: file.href),
          case let .episode(show, season, number)? = TraktMedia.parse(
            fileName: file.name, folders: Array(fileURL.pathComponents.dropLast())) else {
      loading = false
      message = "No encontré capítulos de una serie en esta ubicación."
      return
    }
    showTitle = show
    showMeta = await MetadataStore.shared.metadata(for: .episode(show: show, season: season, number: number))
    if let t = showMeta?.title { showTitle = t }

    let found = await collectEpisodes(around: fileURL)
    guard !found.isEmpty else {
      loading = false
      message = "No encontré capítulos de una serie en esta ubicación."
      return
    }

    var bySeason: [Int: [EpisodeItem]] = [:]
    for (s, group) in Dictionary(grouping: found, by: { $0.season }) {
      let metas = await MetadataStore.shared.episodes(show: show, season: s)
      var items: [EpisodeItem] = []
      for f in group.sorted(by: { $0.number < $1.number }) {
        var item = EpisodeItem(season: s, number: f.number, entry: f.entry, meta: metas[f.number])
        let url = WebDAVClient.absoluteURL(forHref: f.entry.href)
        let info = ProgressResolver.resolve(url: url, media: .episode(show: show, season: s, number: f.number),
                                            runtimeMinutes: item.meta?.runtime, trakt: trakt)
        if let info, info.percent < 95 {
          item.progress = info
        } else if info != nil {
          item.watched = true
        } else if let url {
          let md5 = Utility.mpvWatchLaterMd5(url, false)
          item.watched = HistoryController.shared.history.contains { $0.mpvMd5 == md5 }
        }
        items.append(item)
      }
      bySeason[s] = items
    }
    seasons = bySeason

    let ordered = seasonNumbers.flatMap { bySeason[$0] ?? [] }
    let lastTouched = ordered.lastIndex { $0.watched || $0.progress != nil }
    let next: EpisodeItem?
    if let i = lastTouched {
      next = ordered[i].progress != nil ? ordered[i] : (i + 1 < ordered.count ? ordered[i + 1] : ordered[i])
    } else {
      next = ordered.first
    }
    nextID = next?.id
    selectedSeason = next?.season ?? seasonNumbers.first ?? 1
    loading = false
  }

  // MARK: Finding the files

  /// A video file that represents the entry: the file itself, or the first one found inside a folder.
  private func representativeFile(of entry: WebDAVEntry) async -> WebDAVEntry? {
    guard entry.isDirectory else { return entry }
    guard let url = WebDAVClient.absoluteURL(forHref: entry.href) else { return nil }
    return await firstFile(in: url, depth: 2)
  }

  private func firstFile(in dir: URL, depth: Int) async -> WebDAVEntry? {
    guard let items = try? await client.list(dir) else { return nil }
    if let file = items.first(where: { !$0.isDirectory }) { return file }
    guard depth > 0 else { return nil }
    for folder in items.filter(\.isDirectory).prefix(3) {
      if let url = WebDAVClient.absoluteURL(forHref: folder.href), let f = await firstFile(in: url, depth: depth - 1) {
        return f
      }
    }
    return nil
  }

  /// Episodes of the show that contains `fileURL`: the files of its folder, plus the sibling season folders of the same show.
  private func collectEpisodes(around fileURL: URL) async -> [(season: Int, number: Int, entry: WebDAVEntry)] {
    let parent = fileURL.deletingLastPathComponent()
    var folders: [URL] = [parent]
    let parentName = parent.lastPathComponent
    if let base = TraktMedia.seasonFolderBase(parentName),
       let siblings = try? await client.list(parent.deletingLastPathComponent()) {
      folders = siblings
        .filter { $0.isDirectory && TraktMedia.seasonFolderBase($0.name) == base }
        .compactMap { WebDAVClient.absoluteURL(forHref: $0.href) }
      if folders.isEmpty { folders = [parent] }
    }

    var out: [(season: Int, number: Int, entry: WebDAVEntry)] = []
    for folder in folders {
      guard let files = try? await client.list(folder) else { continue }
      for file in files where !file.isDirectory {
        if case let .episode(_, s, n)? = TraktMedia.parse(fileName: file.name,
                                                          folders: Array(folder.pathComponents)) {
          out.append((s, n, file))
        }
      }
    }
    return out
  }
}

// MARK: - View

struct SeriesView: View {
  let entry: WebDAVEntry
  let trakt: [String: Double]
  let onPlay: (WebDAVEntry, Bool) -> Void
  let onClose: () -> Void

  @StateObject private var model = SeriesViewModel()

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      info.frame(width: 250)
      Divider()
      VStack(spacing: 0) {
        seasonBar
        Divider()
        episodes
      }
    }
    .frame(width: 1000, height: 660)
    .task { await model.load(entry, trakt: trakt) }
  }

  // MARK: Left column

  private var info: some View {
    VStack(alignment: .leading, spacing: 10) {
      PosterView(url: model.showMeta?.largePosterURL, isFolder: false)
      Text(model.showTitle.isEmpty ? entry.name : model.showTitle).font(.title3.bold()).lineLimit(3)
      HStack(spacing: 10) {
        if let y = model.showMeta?.year { Text(String(y)) }
        if let r = model.showMeta?.rating, r > 0 { Text("⭐ \(String(format: "%.1f", r))") }
      }.font(.caption).foregroundColor(.secondary)
      if let genres = model.showMeta?.genres, !genres.isEmpty {
        Text(genres.joined(separator: " · ")).font(.caption)
      }
      ScrollView {
        Text(model.showMeta?.overview ?? "").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      }
      if let next = model.nextItem {
        Button {
          onPlay(next.entry, false)
        } label: {
          Text(next.progress != nil ? "▶︎ Continuar T\(next.season):E\(next.number)" : "▶︎ Ver T\(next.season):E\(next.number)")
            .frame(maxWidth: .infinity)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
      }
    }
    .padding(18)
  }

  // MARK: Right column

  private var seasonBar: some View {
    HStack {
      if model.seasonNumbers.count > 1 {
        Picker("", selection: $model.selectedSeason) {
          ForEach(model.seasonNumbers, id: \.self) { Text(seasonName($0)).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
      } else {
        Text(model.seasonNumbers.first.map(seasonName) ?? "").font(.headline)
      }
      Text("\(model.seasons[model.selectedSeason]?.count ?? 0) capítulos").foregroundColor(.secondary)
      Spacer()
      Button("Cerrar", action: onClose).keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 18).padding(.vertical, 12)
  }

  private func seasonName(_ n: Int) -> String { n == 0 ? "Especiales" : "Temporada \(n)" }

  @ViewBuilder
  private var episodes: some View {
    if model.loading {
      ProgressView("Buscando capítulos…").padding(40).frame(maxWidth: .infinity)
      Spacer()
    } else if let message = model.message {
      Text(message).foregroundColor(.secondary).padding(30)
      Spacer()
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(model.seasons[model.selectedSeason] ?? []) { item in
              EpisodeRow(item: item, isNext: item.id == model.nextID,
                         onPlay: { fromStart in onPlay(item.entry, fromStart) })
                .id(item.id)
              Divider().padding(.leading, 160)
            }
          }
        }
        .onAppear { reveal(proxy) }
        .onChange(of: model.selectedSeason) { _ in reveal(proxy) }
      }
    }
  }

  /// Scrolls so the episode to continue is visible (a little below the top); otherwise to the top of the season.
  private func reveal(_ proxy: ScrollViewProxy) {
    let items = model.seasons[model.selectedSeason] ?? []
    // Wait a moment so the lazy stack has laid out its rows.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      if let i = items.firstIndex(where: { $0.id == model.nextID }) {
        proxy.scrollTo(items[max(i - 1, 0)].id, anchor: .top)
      } else if let first = items.first {
        proxy.scrollTo(first.id, anchor: .top)
      }
    }
  }
}

struct EpisodeRow: View {
  let item: EpisodeItem
  let isNext: Bool
  let onPlay: (Bool) -> Void

  @State private var hovering = false

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      still
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("\(item.number). \(item.title)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
          if isNext { Text("SIGUIENTE").font(.caption2.bold()).foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor)) }
          Spacer()
          if item.watched { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Visto") }
        }
        HStack(spacing: 10) {
          if let rt = item.meta?.runtime, rt > 0 { Text("\(rt) min") }
          if let r = item.meta?.rating, r > 0 { Text("⭐ \(String(format: "%.1f", r))") }
        }.font(.caption).foregroundColor(.secondary)
        if let overview = item.meta?.overview, !overview.isEmpty {
          Text(overview).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
        if let p = item.progress {
          ProgressView(value: min(p.percent, 100), total: 100).frame(maxWidth: 220)
          Text(p.label).font(.caption2).foregroundColor(.accentColor)
        }
      }
    }
    .padding(.horizontal, 18).padding(.vertical, 10)
    .background(hovering ? Color.primary.opacity(0.07) : (isNext ? Color.accentColor.opacity(0.08) : Color.clear))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .onTapGesture { onPlay(false) }
    .contextMenu {
      Button(item.progress != nil ? "Continuar" : "Reproducir") { onPlay(false) }
      if item.progress != nil || item.watched { Button("Desde el inicio") { onPlay(true) } }
    }
  }

  private var still: some View {
    ZStack {
      Rectangle().fill(Color.primary.opacity(0.08))
      if let url = item.meta?.stillURL {
        AsyncImage(url: url) { phase in
          if let image = phase.image { image.resizable().scaledToFill() } else { number }
        }
      } else {
        number
      }
      if hovering {
        Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(.white.opacity(0.9))
          .shadow(radius: 4)
      }
    }
    .frame(width: 128, height: 72)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var number: some View { Text("\(item.number)").font(.title2.bold()).foregroundColor(.secondary) }
}
