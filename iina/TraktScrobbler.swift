//
//  TraktScrobbler.swift
//  iina
//
//  Trakt integration: device authorization, scrobbling (start/pause/stop) and resuming from the
//  progress saved in Trakt. Progress in Trakt is a percentage, not seconds.
//

import CryptoKit
import Foundation

// MARK: - Configuration

enum TraktConfig {
  private static let clientIdKey = "traktClientId"
  private static let enabledKey = "traktEnabled"

  static var clientId: String {
    get { UserDefaults.standard.string(forKey: clientIdKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: clientIdKey) }
  }

  static var enabled: Bool {
    get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }

  static var clientSecret: String {
    get { (try? KeychainAccess.read(username: "secret", forService: .traktSecret).password) ?? "" }
    set {
      do { try KeychainAccess.write(username: "secret", password: newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    forService: .traktSecret) }
      catch { Logger.log("Cannot save Trakt client secret: \(error)", level: .error) }
    }
  }

  struct Token: Codable {
    var access: String
    var refresh: String
    var expiresAt: Date
  }

  static var token: Token? {
    get {
      guard let json = try? KeychainAccess.read(username: "token", forService: .traktToken).password,
            let data = json.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode(Token.self, from: data)
    }
    set {
      guard let newValue, let data = try? JSONEncoder().encode(newValue),
            let json = String(data: data, encoding: .utf8) else { return }
      do { try KeychainAccess.write(username: "token", password: json, forService: .traktToken) }
      catch { Logger.log("Cannot save Trakt token: \(error)", level: .error) }
    }
  }

  static var isConnected: Bool { token != nil && !clientId.isEmpty }
}

// MARK: - Media identification from file names

enum TraktMedia: Equatable {
  case movie(title: String, year: Int?)
  case episode(show: String, season: Int, number: Int)

  /// Normalized key used to compare titles coming from file names and from Trakt.
  static func normalize(_ s: String) -> String {
    s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
  }

  private static let junk = try! NSRegularExpression(
    pattern: #"[\.\s_\-\(\[](?:2160p|1080p|720p|480p|4k|web[\.\-]?dl|webrip|bluray|brrip|bdrip|hdrip|dvdrip|x264|x265|h\.?264|h\.?265|hevc|hdr|remux|proper|repack)\b.*$"#,
    options: [.caseInsensitive])
  private static let episodeRegex = try! NSRegularExpression(pattern: #"[Ss](\d{1,2})[\s\.\-_]?[Ee](\d{1,3})"#)
  private static let altEpisodeRegex = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})x(\d{2,3})(?!\d)"#)
  private static let yearRegex = try! NSRegularExpression(pattern: #"[\(\[\.\s_]((?:19|20)\d{2})[\)\]\.\s_]?"#)

  private static func clean(_ s: String) -> String {
    var t = s.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    t = t.replacingOccurrences(of: #"[\(\[\)\]]"#, with: " ", options: .regularExpression)
    t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return t.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
  }

  /// Best-effort parse of a file name like `Show.Name.S01E02.1080p.mkv` or `Movie Name (2020).mkv`.
  /// Folder names that only describe a season, not the show (e.g. "Season 1", "Temporada 02").
  private static let seasonFolder = try! NSRegularExpression(
    pattern: #"^(?:season|temporada|specials?|especiales|s\d{1,2})[\s\.\-_]*\d*$"#, options: [.caseInsensitive])

  private static let seasonToken = try! NSRegularExpression(
    pattern: #"(?:^|[\s\.\-_\(\[])(?:s|season|temporada)[\s\.\-_]?(\d{1,2})(?=$|[\s\.\-_\)\]])"#,
    options: [.caseInsensitive])

  /// Text before the season marker ("Dexter S01 (2006)" -> "dexter"), or nil when the name has no season marker.
  /// Two folders with the same base belong to the same show.
  static func seasonFolderBase(_ name: String) -> String? {
    let range = NSRange(name.startIndex..., in: name)
    guard let m = seasonToken.firstMatch(in: name, range: range), let whole = Range(m.range, in: name) else { return nil }
    return normalize(String(name[..<whole.lowerBound]))
  }

  /// Title, year and kind read from a release folder name such as
  /// "[SITE] 10 Cloverfield Lane 2016 UHD BluRay 2160p HDR10" or "The Office US S01-S09 1080p AMZN WEB-DL".
  static func folderTitle(_ name: String) -> (title: String, year: Int?, isSeries: Bool)? {
    var text = name.removingPercentEncoding ?? name
    // Leading "[tracker]" tags and web addresses are noise.
    text = text.replacingOccurrences(of: #"^(\s*[\[【][^\]】]*[\]】])+"#, with: "", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)\bwww\.[a-z0-9.\-]+\.[a-z]{2,}\b"#, with: " ", options: .regularExpression)
    let range = NSRange(text.startIndex..., in: text)
    var cut = text.endIndex
    var isSeries = false
    if let m = seasonToken.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
      isSeries = true
      cut = r.lowerBound
    }
    var year: Int?
    let years = yearRegex.matches(in: text, range: range).filter {
      guard let whole = Range($0.range, in: text) else { return false }
      return !clean(String(text[..<whole.lowerBound])).isEmpty
    }
    if let m = years.last, let yr = Range(m.range(at: 1), in: text), let whole = Range(m.range, in: text),
       whole.lowerBound < cut {
      year = Int(text[yr])
      cut = whole.lowerBound
    }
    if let m = junk.firstMatch(in: text, range: range), let r = Range(m.range, in: text), r.lowerBound < cut {
      cut = r.lowerBound
    }
    let title = clean(String(text[..<cut]))
    return title.count >= 2 ? (title, year, isSeries) : nil
  }

  /// Episode title written in a file name: "The.Office.US.S04E15.Night.Out.1080p.WEB-DL.mkv" -> "Night Out".
  static func episodeTitle(fromFileName fileName: String) -> String? {
    var base = (fileName as NSString).deletingPathExtension
    base = base.removingPercentEncoding ?? base
    let range = NSRange(base.startIndex..., in: base)
    for regex in [episodeRegex, altEpisodeRegex] {
      guard let m = regex.firstMatch(in: base, range: range), let whole = Range(m.range, in: base) else { continue }
      var tail = String(base[whole.upperBound...])
      let tailRange = NSRange(tail.startIndex..., in: tail)
      if let j = junk.firstMatch(in: tail, range: tailRange), let jr = Range(j.range, in: tail) {
        tail = String(tail[..<jr.lowerBound])
      }
      let title = clean(tail)
      return title.isEmpty ? nil : title
    }
    return nil
  }

  /// Season number written in a folder name ("Dexter S02 (2007)" -> 2, "Temporada 3" -> 3).
  static func seasonNumber(inFolder name: String) -> Int? {
    let range = NSRange(name.startIndex..., in: name)
    guard let m = seasonToken.firstMatch(in: name, range: range), let r = Range(m.range(at: 1), in: name) else { return nil }
    return Int(name[r])
  }

  /// Show name taken from the nearest ancestor folder that isn't a season folder.
  private static func showName(fromFolders folders: [String]) -> String? {
    for folder in folders.reversed() {
      let name = folder.removingPercentEncoding ?? folder
      if name == "/" || name.isEmpty { continue }
      if seasonFolder.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { continue }
      var t = clean(name)
      if let m = junk.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) {
        t = clean(String(t[..<r.lowerBound]))
      }
      t = t.replacingOccurrences(of: #"\s+(?:19|20)\d{2}$"#, with: "", options: .regularExpression)
      return t.isEmpty ? nil : t
    }
    return nil
  }

  /// `folders` are the ancestor folder names of the file (outermost first), used when the file name has no show name.
  static func parse(fileName: String, folders: [String] = []) -> TraktMedia? {
    var base = (fileName as NSString).deletingPathExtension
    base = base.removingPercentEncoding ?? base
    let range = NSRange(base.startIndex..., in: base)

    for regex in [episodeRegex, altEpisodeRegex] {
      if let m = regex.firstMatch(in: base, range: range),
         let sr = Range(m.range(at: 1), in: base), let nr = Range(m.range(at: 2), in: base),
         let season = Int(base[sr]), let number = Int(base[nr]),
         let whole = Range(m.range, in: base) {
        var show = clean(String(base[..<whole.lowerBound]))
        // Drop a trailing year such as "Show 2019".
        show = show.replacingOccurrences(of: #"\s+(?:19|20)\d{2}$"#, with: "", options: .regularExpression)
        if show.isEmpty { show = showName(fromFolders: folders) ?? "" }
        if !show.isEmpty { return .episode(show: show, season: season, number: number) }
      }
    }

    var year: Int?
    var title = base
    // Use the LAST year-like token: "Blade Runner 2049 (2017)" is a 2017 movie.
    let yearMatches = yearRegex.matches(in: base, range: range).filter {
      guard let whole = Range($0.range, in: base) else { return false }
      return !clean(String(base[..<whole.lowerBound])).isEmpty
    }
    if let m = yearMatches.last,
       let yr = Range(m.range(at: 1), in: base), let whole = Range(m.range, in: base) {
      year = Int(base[yr])
      title = String(base[..<whole.lowerBound])
    } else if let m = junk.firstMatch(in: base, range: range), let whole = Range(m.range, in: base) {
      title = String(base[..<whole.lowerBound])
    }
    title = clean(title)
    return title.isEmpty ? nil : .movie(title: title, year: year)
  }

  /// JSON fragment that identifies this media in a Trakt scrobble request.
  var payload: [String: Any] {
    switch self {
    case let .movie(title, year):
      var movie: [String: Any] = ["title": title]
      if let year { movie["year"] = year }
      return ["movie": movie]
    case let .episode(show, season, number):
      return ["show": ["title": show], "episode": ["season": season, "number": number]]
    }
  }
}

// MARK: - API client

enum TraktError: LocalizedError {
  case notConnected
  case http(Int)
  case message(String)

  var errorDescription: String? {
    switch self {
    case .notConnected: return "Trakt no está conectado."
    case .http(let c): return "Trakt respondió con HTTP \(c)."
    case .message(let m): return m
    }
  }
}

final class TraktAPI {
  static let shared = TraktAPI()
  private let base = URL(string: "https://api.trakt.tv")!
  private let session = URLSession(configuration: .ephemeral)

  private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                       auth: Bool) async throws -> (Data, Int) {
    var req = URLRequest(url: base.appendingPathComponent(path))
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("2", forHTTPHeaderField: "trakt-api-version")
    req.setValue(TraktConfig.clientId, forHTTPHeaderField: "trakt-api-key")
    if auth {
      try await refreshIfNeeded()
      guard let token = TraktConfig.token else { throw TraktError.notConnected }
      req.setValue("Bearer \(token.access)", forHTTPHeaderField: "Authorization")
    }
    if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let (data, response) = try await session.data(for: req)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  private func refreshIfNeeded() async throws {
    guard let token = TraktConfig.token else { throw TraktError.notConnected }
    guard token.expiresAt.timeIntervalSinceNow < 3600 else { return }
    var body: [String: Any] = ["refresh_token": token.refresh, "client_id": TraktConfig.clientId,
                                "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token"]
    if !TraktConfig.clientSecret.isEmpty { body["client_secret"] = TraktConfig.clientSecret }
    let (data, status) = try await request("oauth/token", method: "POST", body: body, auth: false)
    guard status == 200 else { throw TraktError.http(status) }
    TraktConfig.token = try Self.decodeToken(data)
  }

  private static func decodeToken(_ data: Data) throws -> TraktConfig.Token {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
      throw TraktError.message("Respuesta de token inválida.")
    }
    let created = (json["created_at"] as? Double) ?? Date().timeIntervalSince1970
    let expires = (json["expires_in"] as? Double) ?? 7_776_000
    return TraktConfig.Token(access: access, refresh: refresh, expiresAt: Date(timeIntervalSince1970: created + expires))
  }

  // Device authorization

  struct DeviceCode {
    let userCode: String; let url: String; let deviceCode: String; let interval: Int; let expiresIn: Int
    /// PKCE verifier, used instead of the client secret for apps that don't have one.
    let verifier: String?
  }

  private static func makeVerifier() -> String {
    let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return String((0..<64).map { _ in chars[Int.random(in: 0..<chars.count)] })
  }

  private static func challenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  func requestDeviceCode() async throws -> DeviceCode {
    var body: [String: Any] = ["client_id": TraktConfig.clientId]
    var verifier: String?
    if TraktConfig.clientSecret.isEmpty {      // app without a secret: use PKCE
      let v = Self.makeVerifier()
      verifier = v
      body["code_challenge"] = Self.challenge(for: v)
      body["code_challenge_method"] = "S256"
    }
    let (data, status) = try await request("oauth/device/code", method: "POST", body: body, auth: false)
    guard status == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let user = j["user_code"] as? String, let device = j["device_code"] as? String else {
      let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
      throw TraktError.message("No se pudo pedir el código (revisa el Client ID). HTTP \(status) \(detail)")
    }
    return DeviceCode(userCode: user, url: (j["verification_url"] as? String) ?? "https://trakt.tv/activate",
                      deviceCode: device, interval: (j["interval"] as? Int) ?? 5, expiresIn: (j["expires_in"] as? Int) ?? 600,
                      verifier: verifier)
  }

  /// Polls until the user approves the code (or it expires).
  func waitForAuthorization(_ code: DeviceCode) async throws {
    let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
    var interval = code.interval
    while Date() < deadline {
      try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
      var body: [String: Any] = ["code": code.deviceCode, "client_id": TraktConfig.clientId]
      if let verifier = code.verifier { body["code_verifier"] = verifier } else { body["client_secret"] = TraktConfig.clientSecret }
      let (data, status) = try await request("oauth/device/token", method: "POST", body: body, auth: false)
      switch status {
      case 200:
        TraktConfig.token = try Self.decodeToken(data)
        return
      case 400: continue                       // pending
      case 429: interval += 1; continue        // slow down
      case 404, 409, 410, 418: throw TraktError.message("Código rechazado o expirado.")
      default: throw TraktError.http(status)
      }
    }
    throw TraktError.message("El código expiró.")
  }

  func disconnect() { TraktConfig.token = nil }

  // Scrobble

  func scrobble(_ action: String, media: TraktMedia, progress: Double) async {
    var body = media.payload
    body["progress"] = min(max(progress, 0), 100)
    do {
      let (_, status) = try await request("scrobble/\(action)", method: "POST", body: body, auth: true)
      Logger.log("Trakt scrobble/\(action) \(media) \(String(format: "%.1f", progress))% -> HTTP \(status)", level: .debug)
    } catch {
      Logger.log("Trakt scrobble/\(action) failed: \(error)", level: .error)
    }
  }

  /// Raw `sync/playback` list (items in progress).
  func playbackList() async -> [[String: Any]]? {
    guard let (data, status) = try? await request("sync/playback", auth: true), status == 200 else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  }

  /// Progress (0-100) saved in Trakt for `media`, if any.
  func savedProgress(for media: TraktMedia) async -> Double? {
    guard let (data, status) = try? await request("sync/playback", auth: true), status == 200,
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    for item in list {
      guard let progress = item["progress"] as? Double else { continue }
      switch media {
      case let .movie(title, year):
        guard let m = item["movie"] as? [String: Any], let t = m["title"] as? String,
              TraktMedia.normalize(t) == TraktMedia.normalize(title) else { continue }
        if let year, let y = m["year"] as? Int, y != year { continue }
        return progress
      case let .episode(show, season, number):
        guard let s = item["show"] as? [String: Any], let st = s["title"] as? String,
              let e = item["episode"] as? [String: Any],
              e["season"] as? Int == season, e["number"] as? Int == number,
              TraktMedia.normalize(st) == TraktMedia.normalize(show) else { continue }
        return progress
      }
    }
    return nil
  }
}

// MARK: - Scrobbler (called from PlayerCore)

final class TraktScrobbler {
  static let shared = TraktScrobbler()

  private var media: TraktMedia?
  private var lastProgress: Double = 0
  private var timer: Timer?
  /// Set when the user explicitly asked to play from the beginning: don't jump to the saved Trakt position.
  var skipResumeOnce = false

  private var enabled: Bool { TraktConfig.enabled && TraktConfig.isConnected }

  private func progress(of player: PlayerCore) -> Double? {
    let duration = player.mpv.getDouble(MPVProperty.duration)
    let pos = player.mpv.getDouble(MPVProperty.timePos)
    guard duration > 0, pos >= 0 else { return nil }
    return pos / duration * 100
  }

  /// A file finished loading: identify it, resume from Trakt if near the start, and send `start`.
  func fileLoaded(_ player: PlayerCore) {
    guard enabled else { return }
    endSession(sendStop: true, player: nil)
    let folders = Array((player.info.currentURL?.pathComponents ?? []).dropLast())
    guard let name = player.info.currentURL?.lastPathComponent,
          let parsed = TraktMedia.parse(fileName: name, folders: folders) else {
      Logger.log("Trakt: cannot identify title for \(player.info.currentURL?.lastPathComponent ?? "?")", level: .warning)
      return
    }
    media = parsed
    lastProgress = 0
    Logger.log("Trakt: identified \(parsed)", level: .debug)

    let startPos = player.mpv.getDouble(MPVProperty.timePos)
    let skipResume = skipResumeOnce
    skipResumeOnce = false
    Task {
      // Only jump when IINA itself isn't already resuming (position near the start).
      if startPos < 5, !skipResume, !NuvioSync.shared.isActive, let saved = await TraktAPI.shared.savedProgress(for: parsed), saved > 1, saved < 95 {
        await MainActor.run { player.seek(percent: saved) }
        self.lastProgress = saved
      }
      await TraktAPI.shared.scrobble("start", media: parsed, progress: self.lastProgress)
    }
    DispatchQueue.main.async { [weak self, weak player] in
      self?.timer?.invalidate()
      self?.timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
        guard let player, let p = self?.progress(of: player) else { return }
        self?.lastProgress = p
      }
    }
  }

  /// The file played to its end: make sure the closing `stop` reports 100%.
  func finished() { lastProgress = 100 }

  func pauseChanged(_ player: PlayerCore, paused: Bool) {
    guard enabled, let media else { return }
    let p = progress(of: player) ?? lastProgress
    lastProgress = p
    Task { await TraktAPI.shared.scrobble(paused ? "pause" : "start", media: media, progress: p) }
  }

  /// The player is closing or unloading the file. Idempotent.
  func playbackEnding(_ player: PlayerCore) {
    guard enabled, media != nil else { return }
    endSession(sendStop: true, player: player)
  }

  private func endSession(sendStop: Bool, player: PlayerCore?) {
    timer?.invalidate()
    timer = nil
    guard let media else { return }
    self.media = nil
    var p = lastProgress
    if let player, let live = progress(of: player) { p = live }
    guard sendStop else { return }
    // `stop` must complete even while quitting, so don't tie it to the player's lifetime.
    Task { await TraktAPI.shared.scrobble("stop", media: media, progress: p) }
  }
}
