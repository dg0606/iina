//
//  WebDAVClient.swift
//  iina
//
//  WebDAV library support: configuration, PROPFIND listing and auth helpers.
//

import Foundation

struct WebDAVEntry: Identifiable, Hashable {
  /// Percent-encoded absolute path on the server (as returned in `href`).
  let href: String
  let name: String
  let isDirectory: Bool
  let size: Int64?

  var id: String { href }
}

/// Persistent settings for the WebDAV library. URL and user live in `UserDefaults`; the password lives
/// in the macOS Keychain.
enum WebDAVConfig {
  private static let urlKey = "webdavURL"
  private static let userKey = "webdavUser"
  private static let openOnLaunchKey = "webdavOpenOnLaunch"

  static var url: String {
    get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
  }

  static var user: String {
    get { UserDefaults.standard.string(forKey: userKey) ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: userKey) }
  }

  static var openOnLaunch: Bool {
    get { UserDefaults.standard.object(forKey: openOnLaunchKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: openOnLaunchKey) }
  }

  static var password: String {
    get {
      guard !user.isEmpty else { return "" }
      return (try? KeychainAccess.read(username: user, forService: .webdav).password) ?? ""
    }
    set {
      guard !user.isEmpty else { return }
      do {
        try KeychainAccess.write(username: user, password: newValue, forService: .webdav)
      } catch {
        Logger.log("Cannot save WebDAV password: \(error)", level: .error)
      }
    }
  }

  static var isConfigured: Bool { URL(string: url)?.host != nil }

  /// Makes mpv send the WebDAV credentials as a header when it opens files from the server.
  static func applyAuth(to player: PlayerCore) {
    guard let auth = basicAuthHeader else { return }
    player.mpv.setString(MPVOption.Network.httpHeaderFields, "Authorization: \(auth)")
  }

  /// `Authorization: Basic ...` header value, or nil when no user is configured.
  static var basicAuthHeader: String? {
    guard !user.isEmpty, let data = "\(user):\(password)".data(using: .utf8) else { return nil }
    return "Basic " + data.base64EncodedString()
  }
}

enum WebDAVError: LocalizedError {
  case notConfigured
  case http(Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Configura la URL del servidor WebDAV."
    case .http(401), .http(403): return "Credenciales incorrectas o sin permiso (HTTP \(self.statusCode))."
    case .http(let code): return "El servidor respondió con HTTP \(code)."
    case .invalidResponse: return "Respuesta inválida del servidor."
    }
  }

  private var statusCode: Int {
    if case .http(let c) = self { return c }
    return 0
  }
}

final class WebDAVClient: NSObject, URLSessionTaskDelegate {
  static let videoExtensions: Set<String> = [
    "mkv", "mp4", "m4v", "avi", "mov", "wmv", "webm", "ts", "m2ts", "flv", "mpg", "mpeg"
  ]

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 25
    return URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }()

  /// Answers Basic/Digest challenges with the stored credentials.
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    let method = challenge.protectionSpace.authenticationMethod
    guard (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest),
          challenge.previousFailureCount == 0, !WebDAVConfig.user.isEmpty else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(.useCredential, URLCredential(user: WebDAVConfig.user, password: WebDAVConfig.password,
                                                    persistence: .none))
  }

  /// Lists the entries inside the collection at `url` (one level deep). Only folders and video files are returned.
  func list(_ url: URL) async throws -> [WebDAVEntry] {
    var request = URLRequest(url: url)
    request.httpMethod = "PROPFIND"
    request.setValue("1", forHTTPHeaderField: "Depth")
    request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("""
      <?xml version="1.0" encoding="utf-8"?>
      <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
      """.utf8)
    if let auth = WebDAVConfig.basicAuthHeader {
      request.setValue(auth, forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw WebDAVError.invalidResponse }
    // 207 Multi-Status is the normal answer to PROPFIND.
    guard http.statusCode == 207 || http.statusCode == 200 else { throw WebDAVError.http(http.statusCode) }

    let parser = PropfindParser(selfPath: url.path)
    let xml = XMLParser(data: data)
    xml.shouldProcessNamespaces = true
    xml.delegate = parser
    guard xml.parse() else { throw WebDAVError.invalidResponse }

    return parser.entries
      .filter { $0.isDirectory || Self.videoExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
      .sorted { a, b in
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
      }
  }

  /// Builds the absolute URL for an entry from the configured server and the entry's `href`.
  static func absoluteURL(forHref href: String) -> URL? {
    guard let base = URL(string: WebDAVConfig.url) else { return nil }
    if let absolute = URL(string: href), absolute.scheme != nil { return absolute }
    var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
    comps?.percentEncodedPath = href
    comps?.user = nil
    comps?.password = nil
    return comps?.url
  }
}

private final class PropfindParser: NSObject, XMLParserDelegate {
  private(set) var entries: [WebDAVEntry] = []
  private let selfPath: String

  private var inResponse = false
  private var text = ""
  private var href = ""
  private var isCollection = false
  private var size: Int64?

  init(selfPath: String) {
    self.selfPath = selfPath.hasSuffix("/") ? String(selfPath.dropLast()) : selfPath
  }

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
              qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
    text = ""
    switch elementName {
    case "response": inResponse = true; href = ""; isCollection = false; size = nil
    case "collection": if inResponse { isCollection = true }
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
    switch elementName {
    case "href": if inResponse { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    case "getcontentlength": size = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    case "response":
      inResponse = false
      appendCurrent()
    default: break
    }
  }

  private func appendCurrent() {
    // `href` may be absolute (with host) or an absolute path.
    var path = href
    if let comps = URLComponents(string: href), comps.scheme != nil { path = comps.percentEncodedPath }
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    // Skip the collection itself. Compare decoded paths so encoding differences don't matter.
    if (trimmed.removingPercentEncoding ?? trimmed) == (selfPath.removingPercentEncoding ?? selfPath) { return }
    guard !trimmed.isEmpty else { return }
    let name = (trimmed.removingPercentEncoding ?? trimmed).split(separator: "/").last.map(String.init) ?? trimmed
    entries.append(WebDAVEntry(href: path, name: name, isDirectory: isCollection, size: size))
  }
}
