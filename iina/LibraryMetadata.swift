//
//  LibraryMetadata.swift
//  iina
//
//  Metadata (posters, overview, rating) from TMDB with an on-disk cache, and resolution of the
//  saved playback position from IINA's watch-later data and Trakt.
//

import Foundation

// MARK: - Models

struct MediaMetadata: Codable, Hashable {
  var title: String
  var year: Int?
  var overview: String
  var rating: Double?          // 0-10
  var runtimeMinutes: Int?
  var genres: [String]
  var posterPath: String?
  var episodeTitle: String?
  var season: Int?
  var number: Int?
  /// IMDb id ("tt…"); empty string when TMDB has none. nil = not looked up yet.
  var imdbId: String?

  var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
  var largePosterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w500\($0)") } }
}

/// Where a saved position came from.
enum ProgressSource { case local, trakt }

struct ProgressInfo {
  /// Exact position when known (local) or derived from the percentage and the runtime (Trakt).
  var seconds: Double?
  /// 0-100.
  var percent: Double
  var source: ProgressSource

  var label: String {
    guard let seconds else { return String(format: "%.0f%% visto", percent) }
    let pct = percent > 0 ? " (\(Int(percent.rounded()))%)" : ""
    return "Te quedaste en \(Self.format(seconds))\(pct)"
  }

  static func format(_ seconds: Double) -> String {
    let t = Int(seconds)
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}

// MARK: - TMDB

enum TMDBConfig {
  /// In-memory copy: reading the Keychain for every card would be slow.
  private static var cached: String?

  static var apiKey: String {
    get {
      if let cached { return cached }
      let value = (try? KeychainAccess.read(username: "key", forService: .tmdbKey).password) ?? ""
      cached = value
      return value
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      cached = trimmed
      do { try KeychainAccess.write(username: "key", password: trimmed, forService: .tmdbKey) }
      catch { Logger.log("Cannot save TMDB key: \(error)", level: .error) }
    }
  }

  static var isConfigured: Bool { !apiKey.isEmpty }
}

struct EpisodeMeta: Codable, Hashable {
  var number: Int
  var name: String
  var overview: String
  var stillPath: String?
  var runtime: Int?
  var rating: Double?

  var stillURL: URL? { stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w300\($0)") } }
}

private struct MetadataCacheFile: Codable {
  var entries: [String: MediaMetadata] = [:]
  var misses: Set<String> = []
  /// Episodes per season, keyed "t:<show>:<season>". Optional so older cache files still load.
  var seasons: [String: [EpisodeMeta]]?
}

actor MetadataStore {
  static let shared = MetadataStore()

  private var cache: MetadataCacheFile
  private let fileURL: URL
  private let session = URLSession(configuration: .default)
  private let language = "es-MX"

  private init() {
    let dir = Utility.appSupportDirUrl
    fileURL = dir.appendingPathComponent("library-metadata.json")
    if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(MetadataCacheFile.self, from: data) {
      cache = file
    } else {
      cache = MetadataCacheFile()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(cache) { try? data.write(to: fileURL, options: .atomic) }
  }

  /// Forget titles that were not found, so they are searched again (e.g. after setting the API key).
  func forgetMisses() {
    cache.misses.removeAll()
    save()
  }

  static func key(for media: TraktMedia) -> String {
    switch media {
    case let .movie(title, year): return "m:\(TraktMedia.normalize(title)):\(year ?? 0)"
    case let .episode(show, season, number): return "e:\(TraktMedia.normalize(show)):\(season):\(number)"
    }
  }

  /// Metadata for a parsed media, from the cache or TMDB. Returns nil when TMDB isn't configured or finds nothing.
  func metadata(for media: TraktMedia) async -> MediaMetadata? {
    let key = Self.key(for: media)
    // Entries cached before the IMDb id was stored are looked up again once.
    if let hit = cache.entries[key], hit.imdbId != nil || !TMDBConfig.isConfigured { return hit }
    if cache.misses.contains(key) || !TMDBConfig.isConfigured { return cache.entries[key] }
    do {
      let result: MediaMetadata?
      switch media {
      case let .movie(title, year): result = try await fetchMovie(title: title, year: year)
      case let .episode(show, season, number): result = try await fetchEpisode(show: show, season: season, number: number)
      }
      if let result { cache.entries[key] = result } else { cache.misses.insert(key) }
      save()
      return result
    } catch {
      // Network or auth problems are not cached, so the next attempt retries.
      Logger.log("TMDB lookup failed for \(key): \(error)", level: .warning)
      return nil
    }
  }

  /// Episode titles, stills, runtimes and overviews of one season, by episode number.
  func episodes(show: String, season: Int) async -> [Int: EpisodeMeta] {
    let key = "t:\(TraktMedia.normalize(show)):\(season)"
    func index(_ list: [EpisodeMeta]) -> [Int: EpisodeMeta] {
      Dictionary(list.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    }
    if let hit = cache.seasons?[key] { return index(hit) }
    guard TMDBConfig.isConfigured else { return [:] }
    do {
      let search = try await get("search/tv", ["query": show])
      guard let id = (search["results"] as? [[String: Any]])?.first?["id"] as? Int else { return [:] }
      let details = try await get("tv/\(id)/season/\(season)", [:])
      let list = (details["episodes"] as? [[String: Any]] ?? []).compactMap { e -> EpisodeMeta? in
        guard let n = e["episode_number"] as? Int else { return nil }
        return EpisodeMeta(number: n, name: (e["name"] as? String) ?? "Episodio \(n)",
                           overview: (e["overview"] as? String) ?? "", stillPath: e["still_path"] as? String,
                           runtime: e["runtime"] as? Int, rating: e["vote_average"] as? Double)
      }
      if cache.seasons == nil { cache.seasons = [:] }
      cache.seasons?[key] = list
      save()
      return index(list)
    } catch {
      return [:]
    }
  }

  // MARK: Requests

  private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
    var comps = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
    var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    items.append(URLQueryItem(name: "language", value: language))
    let key = TMDBConfig.apiKey
    let bearer = key.hasPrefix("eyJ")        // v4 read-access token
    if !bearer { items.append(URLQueryItem(name: "api_key", value: key)) }
    comps.queryItems = items
    var req = URLRequest(url: comps.url!)
    if bearer { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    let (data, response) = try await session.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw TraktError.http(status) }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }

  private func year(from date: Any?) -> Int? {
    guard let s = date as? String, s.count >= 4 else { return nil }
    return Int(s.prefix(4))
  }

  private func genres(_ json: [String: Any]) -> [String] {
    (json["genres"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
  }

  private func fetchMovie(title: String, year: Int?) async throws -> MediaMetadata? {
    var q = ["query": title]
    if let year { q["year"] = String(year) }
    var search = try await get("search/movie", q)
    var results = search["results"] as? [[String: Any]] ?? []
    if results.isEmpty, year != nil {       // the year in the file name may be off by one
      search = try await get("search/movie", ["query": title])
      results = search["results"] as? [[String: Any]] ?? []
    }
    guard let first = results.first, let id = first["id"] as? Int else { return nil }
    let d = try await get("movie/\(id)", ["append_to_response": "external_ids"])
    let imdb = (d["imdb_id"] as? String) ?? ((d["external_ids"] as? [String: Any])?["imdb_id"] as? String)
    return MediaMetadata(
      title: (d["title"] as? String) ?? title, year: self.year(from: d["release_date"]),
      overview: (d["overview"] as? String) ?? "", rating: d["vote_average"] as? Double,
      runtimeMinutes: d["runtime"] as? Int, genres: genres(d), posterPath: d["poster_path"] as? String,
      episodeTitle: nil, season: nil, number: nil, imdbId: imdb ?? "")
  }

  private func fetchShow(title: String) async throws -> MediaMetadata? {
    let search = try await get("search/tv", ["query": title])
    guard let first = (search["results"] as? [[String: Any]])?.first, let id = first["id"] as? Int else { return nil }
    let d = try await get("tv/\(id)", ["append_to_response": "external_ids"])
    let imdb = (d["external_ids"] as? [String: Any])?["imdb_id"] as? String
    return MediaMetadata(
      title: (d["name"] as? String) ?? title, year: year(from: d["first_air_date"]),
      overview: (d["overview"] as? String) ?? "", rating: d["vote_average"] as? Double,
      runtimeMinutes: (d["episode_run_time"] as? [Int])?.first, genres: genres(d),
      posterPath: d["poster_path"] as? String, episodeTitle: nil, season: nil, number: nil, imdbId: imdb ?? "")
  }

  private func fetchEpisode(show: String, season: Int, number: Int) async throws -> MediaMetadata? {
    guard var base = try await fetchShow(title: show) else { return nil }
    let search = try await get("search/tv", ["query": show])
    guard let id = (search["results"] as? [[String: Any]])?.first?["id"] as? Int else { return base }
    if let ep = try? await get("tv/\(id)/season/\(season)/episode/\(number)", [:]) {
      base.episodeTitle = ep["name"] as? String
      if let o = ep["overview"] as? String, !o.isEmpty { base.overview = o }
      if let r = ep["vote_average"] as? Double, r > 0 { base.rating = r }
      if let rt = ep["runtime"] as? Int { base.runtimeMinutes = rt }
    }
    base.season = season
    base.number = number
    return base
  }
}

// MARK: - Progress

extension TraktAPI {
  /// All in-progress items saved in Trakt, keyed like `MetadataStore.key(for:)`.
  func allSavedProgress() async -> [String: Double] {
    guard TraktConfig.isConnected, let list = await playbackList() else { return [:] }
    var out: [String: Double] = [:]
    for item in list {
      guard let progress = item["progress"] as? Double else { continue }
      if let m = item["movie"] as? [String: Any], let t = m["title"] as? String {
        out["m:\(TraktMedia.normalize(t)):\(m["year"] as? Int ?? 0)"] = progress
        out["m:\(TraktMedia.normalize(t)):0"] = progress          // file name without year
      } else if let s = item["show"] as? [String: Any], let st = s["title"] as? String,
                let e = item["episode"] as? [String: Any], let sn = e["season"] as? Int, let en = e["number"] as? Int {
        out["e:\(TraktMedia.normalize(st)):\(sn):\(en)"] = progress
      }
    }
    return out
  }
}

enum ProgressResolver {
  /// Best known progress for a file: exact local position first, otherwise Trakt (percent) converted using the runtime.
  static func resolve(url: URL?, media: TraktMedia?, runtimeMinutes: Int?, trakt: [String: Double]) -> ProgressInfo? {
    if let url {
      let md5 = Utility.mpvWatchLaterMd5(url, false)
      if let pos = Utility.playbackProgressFromWatchLater(md5)?.second, pos > 5 {
        let known = HistoryController.shared.history.first { $0.mpvMd5 == md5 }?.duration.second
        let duration = (known ?? 0) > 0 ? known! : Double(runtimeMinutes ?? 0) * 60
        let percent = duration > 0 ? min(pos / duration * 100, 100) : 0
        return ProgressInfo(seconds: pos, percent: percent, source: .local)
      }
    }
    if let media {
      var keys = [MetadataStore.key(for: media)]
      if case let .movie(title, _) = media { keys.append("m:\(TraktMedia.normalize(title)):0") }
      for k in keys {
        if let p = trakt[k], p > 1 {
          let seconds = runtimeMinutes.map { Double($0) * 60 * p / 100 }
          return ProgressInfo(seconds: seconds, percent: p, source: .trakt)
        }
      }
    }
    return nil
  }
}
