//
//  LibraryHome.swift
//  iina
//
//  Visual building blocks of the library home: featured hero, horizontal shelves, folder tiles, quality tags.
//

import SwiftUI

/// Title shown for a file: the series/movie name, always naming the episode (from TMDB or the file name).
func libraryDisplayTitle(entry: WebDAVEntry, meta: MediaMetadata?) -> String {
  guard let meta else {
    // A release folder without a match still reads better with the noise removed.
    if entry.isDirectory, let info = TraktMedia.folderTitle(entry.name) {
      return info.year.map { "\(info.title) (\($0))" } ?? info.title
    }
    return entry.name
  }
  if let s = meta.season, let n = meta.number {
    let code = "S\(String(format: "%02d", s))E\(String(format: "%02d", n))"
    let episode = meta.episodeTitle ?? TraktMedia.episodeTitle(fromFileName: entry.name)
    return "\(meta.title) · \(code)" + (episode.map { " \($0)" } ?? "")
  }
  return meta.title
}

/// Remote image that fades in and shows a neutral placeholder while loading or when there is no URL.
struct RemoteImage: View {
  let url: URL?

  var body: some View {
    ZStack {
      Color.primary.opacity(0.08)
      if let url {
        AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.25))) { phase in
          if let image = phase.image { image.resizable().scaledToFill() }
        }
      }
    }
  }
}

/// Small outlined tag such as "4K" or "Dolby Vision".
struct QualityBadge: View {
  let text: String
  var onImage = false

  var body: some View {
    Text(text)
      .font(.system(size: 10, weight: .bold))
      .padding(.horizontal, 6).padding(.vertical, 2)
      .foregroundColor(onImage ? .white : .secondary)
      .background(RoundedRectangle(cornerRadius: 4).fill(onImage ? Color.black.opacity(0.55) : Color.clear))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(onImage ? Color.white.opacity(0.5) : Color.secondary.opacity(0.6), lineWidth: 1))
  }
}

/// Placeholder for a folder: tinted gradient with a folder symbol instead of an empty gray box.
struct FolderTile: View {
  var body: some View {
    ZStack {
      LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.18)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
      Image(systemName: "folder.fill").font(.system(size: 46)).foregroundColor(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }
  }
}

struct HeroButtonStyle: ButtonStyle {
  var primary: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .semibold))
      .padding(.horizontal, 18).padding(.vertical, 9)
      .foregroundColor(primary ? .white : .white)
      .background(Capsule().fill(primary ? Color.accentColor : Color.white.opacity(0.22)))
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

/// Large featured card at the top of Inicio: what to continue watching, over its backdrop.
struct HeroView: View {
  let entry: WebDAVEntry
  let meta: MediaMetadata?
  let backdrop: URL?
  let progress: ProgressInfo?
  let isNextUp: Bool
  let onPlay: () -> Void
  let onDetails: () -> Void

  private var heading: String {
    if isNextUp { return "SIGUIENTE EPISODIO" }
    return progress != nil ? "CONTINUAR VIENDO" : "VISTO RECIENTEMENTE"
  }

  private var title: String { meta?.title ?? entry.name }

  private var subtitle: String? {
    if let s = meta?.season, let n = meta?.number {
      let episode = meta?.episodeTitle ?? TraktMedia.episodeTitle(fromFileName: entry.name)
      return "Temporada \(s) · Episodio \(n)" + (episode.map { " — \($0)" } ?? "")
    }
    let parts = [meta?.year.map(String.init), meta?.genres.prefix(2).joined(separator: ", ")]
      .compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private var remaining: String? {
    guard let p = progress, let rt = meta?.runtimeMinutes, rt > 0 else { return nil }
    let left = Int((Double(rt) * (1 - p.percent / 100)).rounded())
    return left > 0 ? "Quedan \(left) min" : nil
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      Group {
        if let backdrop {
          RemoteImage(url: backdrop)
        } else {
          LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.black.opacity(0.6)],
                         startPoint: .topLeading, endPoint: .bottomTrailing)
        }
      }
      .frame(maxWidth: .infinity).frame(height: 340).clipped()

      // Darken the left (text) side and the bottom so the text always reads, whatever the image.
      LinearGradient(colors: [Color.black.opacity(0.78), Color.black.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
      LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)], startPoint: .center, endPoint: .bottom)

      VStack(alignment: .leading, spacing: 8) {
        Text(heading).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(.white.opacity(0.75))
        Text(title).font(.system(size: 38, weight: .bold)).foregroundColor(.white).lineLimit(2)
          .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
        if let subtitle { Text(subtitle).font(.system(size: 15)).foregroundColor(.white.opacity(0.88)).lineLimit(1) }
        if let progress {
          HStack(spacing: 10) {
            ProgressView(value: min(progress.percent, 100), total: 100).progressViewStyle(.linear).frame(width: 220)
            Text([progress.label, remaining].compactMap { $0 }.joined(separator: " · "))
              .font(.system(size: 12)).foregroundColor(.white.opacity(0.85))
          }.padding(.top, 2)
        }
        HStack(spacing: 10) {
          Button(action: onPlay) { Label(progress != nil ? "Continuar" : "Reproducir", systemImage: "play.fill") }
            .buttonStyle(HeroButtonStyle(primary: true))
          Button(action: onDetails) { Label("Detalles", systemImage: "info.circle") }
            .buttonStyle(HeroButtonStyle(primary: false))
        }.padding(.top, 8)
      }
      .frame(maxWidth: 560, alignment: .leading)
      .padding(28)
    }
    .frame(height: 340)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
  }
}

/// Wide (16:9) card for the "Continuar viendo" shelf: the episode still or backdrop, with progress and time left.
struct ShelfCard<MenuContent: View>: View {
  let entry: WebDAVEntry
  let meta: MediaMetadata?
  let still: URL?
  let progress: ProgressInfo?
  var badge: String? = nil
  let menuContent: MenuContent

  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static var width: CGFloat { 290 }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ZStack(alignment: .bottomLeading) {
        RemoteImage(url: still ?? meta?.backdropURL ?? meta?.posterURL)
          .frame(width: Self.width, height: Self.width * 9 / 16).clipped()
        LinearGradient(colors: [.clear, Color.black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
        if let progress, progress.percent > 0 {
          ProgressView(value: min(progress.percent, 100), total: 100).progressViewStyle(.linear).padding(8)
        }
        if hovering {
          Image(systemName: "play.circle.fill").font(.system(size: 38)).foregroundColor(.white.opacity(0.95))
            .shadow(radius: 6).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(width: Self.width, height: Self.width * 9 / 16)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
      .overlay(alignment: .topTrailing) {
        if hovering {
          Menu { menuContent } label: {
            Image(systemName: "ellipsis.circle.fill").font(.system(size: 22)).foregroundColor(.white)
              .shadow(color: .black.opacity(0.6), radius: 3)
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .padding(6).help("Más opciones").accessibilityLabel("Más opciones")
        }
      }
      .shadow(color: .black.opacity(0.28), radius: 6, y: 3)

      Text(libraryDisplayTitle(entry: entry, meta: meta)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
      if let badge {
        Text(badge).font(.caption.weight(.semibold)).foregroundColor(.accentColor)
      } else if let progress {
        Text(progress.label).font(.caption).foregroundColor(.secondary).lineLimit(1)
      }
    }
    .frame(width: Self.width)
    .contentShape(Rectangle())
    .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}
