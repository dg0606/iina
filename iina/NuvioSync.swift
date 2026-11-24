//
//  NuvioSync.swift
//  iina
//
//  Reports playback progress to the user's Nuvio account, so what is watched here shows up in
//  Nuvio (web, TV, mobile) with the exact position. Mirrors the requests Nuvio Web makes:
//  Supabase password sign-in and the `sync_*_watch_progress` RPCs.
//

import Foundation

// MARK: - Settings

enum NuvioConfig {
  private static let urlKey = "nuvioBackendURL"
  private static let anonKeyKey = "nuvioAnonKey"
  private static let emailKey = "nuvioEmail"
  private static let enabledKey = "nuvioEnabled"
  private static let profileKey = "nuvioProfileIndex"
  private static let clientIdKey = "nuvioClientId"

  static var backendURL: String {
    get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                      .trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: urlKey) }
  }
  /// The backend's public ("anon") key. Not a secret, but kept out of the source code.
  static var anonKey: String {
    get { UserDefaults.standard.string(forKey: anonKeyKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: anonKeyKey) }
  }
  static var email: String {
    get { UserDefaults.standard.string(forKey: emailKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: emailKey) }
  }
  static var enabled: Bool {
    get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
  }
  /// Nuvio profile (1-6) that receives the progress.
  static var profileIndex: Int {
    get { max(1, UserDefaults.standard.object(forKey: profileKey) as? Int ?? 1) }
    set { UserDefaults.standard.set(max(1, newValue), forKey: profileKey) }
  }
  static var password: String {
    get { (try? KeychainAccess.read(username: "password", forService: .nuvioPassword).password) ?? "" }
    set {
      do { try KeychainAccess.write(username: "password", password: newValue, forService: .nuvioPassword) }
      catch { Logger.log("Cannot save Nuvio password: \(error)", level: .error) }
    }
  }
  /// Identifies this app to Nuvio ("16-96 letters, digits, - or _"), like Nuvio Web's own client id.
  static var clientId: String {
    if let id = UserDefaults.standard.string(forKey: clientIdKey), id.count >= 16 { return id }
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    let id = "iina-webdav-" + String((0..<32).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    UserDefaults.standard.set(id, forKey: clientIdKey)
    return id
  }

  struct Token: Codable {
    var access: String
    var refresh: String
    var expiresAt: Date
  }
  static var token: Token? {
    get {
      guard let json = try? KeychainAccess.read(username: "token", forService: .nuvioToken).password,
            let data = json.data(using: .utf8) else { return nil }
      return try? JSONDecoder().decode(Token.self, from: data)
    }
    set {
      guard let newValue, let data = try? JSONEncoder().encode(newValue),
            let json = String(data: data, encoding: .utf8) else { return }
      do { try KeychainAccess.write(username: "token", password: json, forService: .nuvioToken) }
      catch { Logger.log("Cannot save Nuvio token: \(error)", level: .error) }
    }
  }

  /// Result of the last progress report ("12:31:05 · OK …" or the error), shown in the settings.
  static var lastStatus: String {
    get { UserDefaults.standard.string(forKey: "nuvioLastStatus") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "nuvioLastStatus") }
  }
  static func record(_ text: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    lastStatus = "\(f.string(from: Date())) · \(text)"
  }

  static var isConfigured: Bool {
    !backendURL.isEmpty && !anonKey.isEmpty && !email.isEmpty && !password.isEmpty
  }
}

// MARK: - API

struct NuvioProgressRow {
  var contentId: String
  var contentType: String
  var videoId: String
  var season: Int?
  var episode: Int?
  var positionMs: Double
  var durationMs: Double
  var lastWatched: Double
  var progressKey: String?

  var isComplete: Bool { durationMs > 0 && positionMs / durationMs >= 0.9 }
}

struct NuvioIdentity: Equatable {
  var contentId: String       // IMDb id
  var contentType: String     // "movie" | "series"
  var videoId: String         // movie: IMDb id; episode: "<imdb>:<season>:<episode>"
  var season: Int?
  var episode: Int?
}

enum NuvioError: LocalizedError {
  case notConfigured
  case invalidBackend
  case message(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Falta la URL, la clave, el correo o la contraseña de Nuvio."
    case .invalidBackend: return "La URL del backend no es válida (debe ser https, o localhost)."
    case .message(let m): return m
    }
  }
}

final class NuvioAPI {
  static let shared = NuvioAPI()
  private let session = URLSession(configuration: .ephemeral)

  private func url(_ path: String) throws -> URL {
    guard let base = URL(string: NuvioConfig.backendURL), let host = base.host,
          base.scheme == "https" || ["localhost", "127.0.0.1"].contains(host),
          let full = URL(string: NuvioConfig.backendURL + path) else { throw NuvioError.invalidBackend }
    return full
  }

  private func send(_ path: String, body: [String: Any], bearer: String?) async throws -> (Data, Int) {
    var req = URLRequest(url: try url(path))
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(NuvioConfig.anonKey, forHTTPHeaderField: "apikey")
    if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: req)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }

  private func errorText(_ data: Data, _ status: Int) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      for key in ["error_description", "msg", "message", "error"] {
        if let m = json[key] as? String, !m.isEmpty { return "\(m) (HTTP \(status))" }
      }
    }
    return "HTTP \(status)"
  }

  // MARK: Auth

  private func store(_ data: Data) throws {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
      throw NuvioError.message("Respuesta de inicio de sesión inválida.")
    }
    let expires = (json["expires_in"] as? Double) ?? 3600
    NuvioConfig.token = NuvioConfig.Token(access: access, refresh: refresh,
                                          expiresAt: Date().addingTimeInterval(expires))
  }

  func signIn() async throws {
    guard NuvioConfig.isConfigured else { throw NuvioError.notConfigured }
    let (data, status) = try await send("/auth/v1/token?grant_type=password",
                                        body: ["email": NuvioConfig.email, "password": NuvioConfig.password], bearer: nil)
    guard status == 200 else { throw NuvioError.message(errorText(data, status)) }
    try store(data)
  }

  private func accessToken() async throws -> String {
    if let token = NuvioConfig.token, token.expiresAt.timeIntervalSinceNow > 60 { return token.access }
    if let token = NuvioConfig.token {
      let (data, status) = try await send("/auth/v1/token?grant_type=refresh_token",
                                          body: ["refresh_token": token.refresh], bearer: nil)
      if status == 200 { try store(data); if let t = NuvioConfig.token { return t.access } }
    }
    try await signIn()                       // refresh failed or no token: sign in again
    guard let token = NuvioConfig.token else { throw NuvioError.notConfigured }
    return token.access
  }

  func disconnect() { NuvioConfig.token = nil }

  // MARK: RPC

  func rpc(_ name: String, _ body: [String: Any]) async throws -> Any {
    let token = try await accessToken()
    let (data, status) = try await send("/rest/v1/rpc/\(name)", body: body, bearer: token)
    guard (200..<300).contains(status) else { throw NuvioError.message(errorText(data, status)) }
    return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? [:])
  }

  /// (profile index, name) of the account's profiles.
  func profiles() async throws -> [(index: Int, name: String)] {
    let rows = (try await rpc("sync_pull_profiles", [:])) as? [[String: Any]] ?? []
    return rows.compactMap { row in
      guard let index = (row["profile_index"] as? Int) ?? (row["profileIndex"] as? Int) else { return nil }
      return (index, (row["name"] as? String) ?? "Perfil \(index)")
    }.sorted { $0.index < $1.index }
  }

  func pullProgress(profile: Int) async throws -> [NuvioProgressRow] {
    let rows = (try await rpc("sync_pull_watch_progress", ["p_profile_id": profile, "p_limit": 1000])) as? [[String: Any]] ?? []
    return rows.map { row in
      NuvioProgressRow(
        contentId: String(describing: row["content_id"] ?? ""),
        contentType: String(describing: row["content_type"] ?? ""),
        videoId: String(describing: row["video_id"] ?? ""),
        season: (row["season"] as? NSNumber)?.intValue,
        episode: (row["episode"] as? NSNumber)?.intValue,
        positionMs: (row["position"] as? NSNumber)?.doubleValue ?? (row["position_ms"] as? NSNumber)?.doubleValue ?? 0,
        durationMs: (row["duration"] as? NSNumber)?.doubleValue ?? (row["duration_ms"] as? NSNumber)?.doubleValue ?? 0,
        lastWatched: (row["last_watched"] as? NSNumber)?.doubleValue ?? 0,
        progressKey: (row["progress_key"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
  }

  /// Same rules as Nuvio Web: ignore positions under 1 s, and pin a finished row (>= 90% or ended) to the full duration.
  @discardableResult
  func push(profile: Int, identity: NuvioIdentity, positionMs: Double, durationMs: Double, ended: Bool,
            knownRows: [NuvioProgressRow]) async throws -> Bool {
    let position = max(0, positionMs.rounded())
    let duration = max(0, durationMs.rounded())
    let completed = ended || (duration > 0 && position / duration >= 0.9)
    if !completed && position < 1000 { return false }

    // The server's own key for an existing row wins, otherwise a duplicate would be created.
    let existing = knownRows
      .filter { $0.contentId == identity.contentId && $0.season == identity.season && $0.episode == identity.episode }
      .sorted { $0.lastWatched > $1.lastWatched }.first?.progressKey
    let key = existing ?? ((identity.season != nil && identity.episode != nil)
                           ? "\(identity.contentId)_s\(identity.season!)e\(identity.episode!)" : identity.contentId)

    // All numbers must be integers: the backend columns are integers and reject "123.45".
    let entry: [String: Any] = [
      "content_id": identity.contentId,
      "content_type": identity.contentType,
      "video_id": identity.videoId,
      "season": identity.season.map { $0 as Any } ?? NSNull(),
      "episode": identity.episode.map { $0 as Any } ?? NSNull(),
      "position": Int64(completed && duration > 0 ? duration : position),
      "duration": Int64(duration),
      "last_watched": Int64((Date().timeIntervalSince1970 * 1000).rounded()),
      "progress_key": key,
    ]
    _ = try await rpc("sync_push_watch_progress", [
      "p_profile_id": profile, "p_entries": [entry], "p_origin_client_id": NuvioConfig.clientId])
    return true
  }
}

// MARK: - Playback hooks

final class NuvioSync {
  static let shared = NuvioSync()

  private var identity: NuvioIdentity?
  private var rows: [NuvioProgressRow] = []
  private var lastPositionMs: Double = 0
  private var lastDurationMs: Double = 0
  private var timer: Timer?
  private var token = UUID()
  private weak var player: PlayerCore?
  private var failureShown = false

  var isActive: Bool { NuvioConfig.enabled && NuvioConfig.isConfigured }

  private func snapshot(of player: PlayerCore) -> (pos: Double, dur: Double)? {
    let dur = player.mpv.getDouble(MPVProperty.duration)
    let pos = player.mpv.getDouble(MPVProperty.timePos)
    guard dur > 0, pos >= 0 else { return nil }
    return (pos * 1000, dur * 1000)
  }

  /// A file finished loading: identify it, resume from the exact position saved in Nuvio, and start reporting.
  func fileLoaded(_ player: PlayerCore) {
    endSession(sendFinal: true, player: nil)
    guard isActive, let url = player.info.currentURL else { return }
    let folders = Array(url.pathComponents.dropLast())
    guard let media = TraktMedia.parse(fileName: url.lastPathComponent, folders: folders) else { return }

    token = UUID()
    self.player = player
    failureShown = false
    let myToken = token
    let startPos = player.mpv.getDouble(MPVProperty.timePos)
    let skipResume = TraktScrobbler.shared.skipResumeOnce
    Task {
      guard let meta = await MetadataStore.shared.metadata(for: media), let imdb = meta.imdbId, !imdb.isEmpty else {
        Logger.log("Nuvio: no IMDb id for \(media), not reporting", level: .warning)
        NuvioConfig.record("no se encontró el código IMDb de \(media) en TMDB (¿falta la API key de TMDB?)")
        return
      }
      let ident: NuvioIdentity
      switch media {
      case .movie:
        ident = NuvioIdentity(contentId: imdb, contentType: "movie", videoId: imdb, season: nil, episode: nil)
      case let .episode(_, s, n):
        ident = NuvioIdentity(contentId: imdb, contentType: "series", videoId: "\(imdb):\(s):\(n)", season: s, episode: n)
      }
      var known: [NuvioProgressRow] = []
      do { known = try await NuvioAPI.shared.pullProgress(profile: NuvioConfig.profileIndex) }
      catch { NuvioConfig.record("ERROR al leer el progreso: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
      DispatchQueue.main.async { [weak self, weak player] in
        guard let self, let player, self.token == myToken else { return }
        self.identity = ident
        self.rows = known
        Logger.log("Nuvio: identified \(ident.videoId)", level: .debug)
        // Resume at the exact position Nuvio has (only when IINA isn't already resuming and the user didn't ask for the start).
        if startPos < 5, !skipResume,
           let row = known.filter({ $0.contentId == ident.contentId && $0.season == ident.season && $0.episode == ident.episode })
                          .sorted(by: { $0.lastWatched > $1.lastWatched }).first,
           !row.isComplete, row.positionMs > 5000 {
          Logger.log("Nuvio: resuming \(ident.videoId) at \(Int(row.positionMs / 1000)) s from the saved position", level: .debug)
          player.seek(absoluteSecond: row.positionMs / 1000)
        }
        if let snap = self.snapshot(of: player) { self.lastPositionMs = snap.pos; self.lastDurationMs = snap.dur }
        self.report(ended: false)
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak player] _ in
          guard let self, let player, let snap = self.snapshot(of: player) else { return }
          self.lastPositionMs = snap.pos; self.lastDurationMs = snap.dur
          self.report(ended: false)
        }
      }
    }
  }

  func pauseChanged(_ player: PlayerCore, paused: Bool) {
    guard identity != nil else { return }
    if let snap = snapshot(of: player) { lastPositionMs = snap.pos; lastDurationMs = snap.dur }
    if paused { report(ended: false) }
  }

  /// The file played to its end.
  func finished() {
    guard identity != nil else { return }
    report(ended: true)
    identity = nil
    timer?.invalidate()
  }

  /// The player is closing or unloading the file.
  func playbackEnding(_ player: PlayerCore) {
    guard identity != nil else { return }
    endSession(sendFinal: true, player: player)
  }

  private func endSession(sendFinal: Bool, player: PlayerCore?) {
    timer?.invalidate()
    timer = nil
    guard identity != nil else { return }
    if let player, let snap = snapshot(of: player) { lastPositionMs = snap.pos; lastDurationMs = snap.dur }
    if sendFinal { report(ended: false) }
    identity = nil
  }

  /// Tells the user on screen that progress is not being saved, once per file so it never nags.
  private func showFailureOnce(_ reason: String) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.failureShown, let player = self.player else { return }
      self.failureShown = true
      player.sendOSD(.customWithDetail("No se pudo guardar el progreso en Nuvio", String(reason.prefix(90))))
    }
  }

  private func report(ended: Bool) {
    guard let identity, lastDurationMs > 0 || ended else { return }
    let pos = lastPositionMs, dur = lastDurationMs, known = rows
    Task {
      do {
        let stored = try await NuvioAPI.shared.push(profile: NuvioConfig.profileIndex, identity: identity,
                                                    positionMs: pos, durationMs: dur, ended: ended, knownRows: known)
        Logger.log("Nuvio: pushed \(identity.videoId) \(Int(pos / 1000))s/\(Int(dur / 1000))s stored=\(stored)", level: .debug)
        if stored { NuvioConfig.record("OK \(identity.videoId) en \(Int(pos / 1000)) s") }
      } catch {
        Logger.log("Nuvio: push failed: \(error)", level: .error)
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NuvioConfig.record("ERROR al enviar \(identity.videoId): \(reason)")
        showFailureOnce(reason)
      }
    }
  }
}
