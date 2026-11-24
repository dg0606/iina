//
//  MediaQuality.swift
//  iina
//
//  Quality tags read from a release file name ("2160p", "HDR", "Remux", "DTS-HD"...).
//

import Foundation

enum MediaQuality {
  private static let b = #"(?<![A-Za-z0-9])"#     // not preceded by a letter or digit
  private static let e = #"(?![A-Za-z0-9])"#      // not followed by a letter or digit

  /// (label, pattern) in display order: resolution, HDR kind, source, audio, codec.
  private static let rules: [(label: String, regex: NSRegularExpression)] = [
    ("4K", b + #"(2160p|4k|uhd)"# + e),
    ("1080p", b + #"1080[pi]"# + e),
    ("720p", b + #"720p"# + e),
    ("Dolby Vision", b + #"(dv|dovi|dolby[ ._-]?vision)"# + e),
    ("HDR10+", b + #"hdr10\+"#),
    ("HDR", b + #"hdr(10)?"# + e),
    ("Remux", b + #"remux"# + e),
    ("Atmos", b + #"atmos"# + e),
    ("TrueHD", b + #"true[ ._-]?hd"# + e),
    ("DTS-HD", b + #"dts[ ._-]?hd"#),
    ("DTS", b + #"dts"# + #"(?![A-Za-z0-9]|[ ._-]hd)"#),
    ("DD+", b + #"(ddp|dd\+|e[ ._-]?ac[ ._-]?3)"# + #"(?![A-Za-z])"#),
    ("HEVC", b + #"(hevc|x265|h[ ._]?265)"# + e),
  ].compactMap { label, pattern in
    (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (label, $0) }
  }

  /// Short forms for tight spaces such as card captions ("Dolby Vision" -> "DV").
  static func compactBadges(for name: String) -> [String] {
    badges(for: name).map { $0 == "Dolby Vision" ? "DV" : $0 }
  }

  /// Tags found in `name`, in display order, without duplicates (HDR10+ replaces plain HDR).
  static func badges(for name: String) -> [String] {
    let text = name.removingPercentEncoding ?? name
    let range = NSRange(text.startIndex..., in: text)
    var found = rules.filter { $0.regex.firstMatch(in: text, range: range) != nil }.map(\.label)
    if found.contains("HDR10+") { found.removeAll { $0 == "HDR" } }
    return found
  }
}
