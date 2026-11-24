//
//  LibraryLists.swift
//  iina
//
//  User-defined lists for the WebDAV library ("Favoritos" and any list the user creates).
//  Stored locally as JSON in the app's support folder.
//

import Foundation

struct ListItem: Codable, Hashable, Identifiable {
  /// Percent-encoded absolute path on the server, same as `WebDAVEntry.href`.
  var href: String
  var name: String
  var isDirectory: Bool
  var id: String { href }

  var entry: WebDAVEntry { WebDAVEntry(href: href, name: name, isDirectory: isDirectory, size: nil) }
}

struct LibraryList: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var items: [ListItem] = []
}

@MainActor
final class ListsStore: ObservableObject {
  static let shared = ListsStore()

  @Published private(set) var lists: [LibraryList]

  private let fileURL = Utility.appSupportDirUrl.appendingPathComponent("library-lists.json")

  private init() {
    if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([LibraryList].self, from: data) {
      lists = saved
    } else {
      lists = [LibraryList(name: "Favoritos")]
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(lists) { try? data.write(to: fileURL, options: .atomic) }
  }

  func list(_ id: UUID) -> LibraryList? { lists.first { $0.id == id } }

  @discardableResult
  func create(name: String) -> UUID? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let list = LibraryList(name: trimmed)
    lists.append(list)
    save()
    return list.id
  }

  func rename(_ id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let i = lists.firstIndex(where: { $0.id == id }) else { return }
    lists[i].name = trimmed
    save()
  }

  func delete(_ id: UUID) {
    lists.removeAll { $0.id == id }
    save()
  }

  func contains(_ entry: WebDAVEntry, in listID: UUID) -> Bool {
    list(listID)?.items.contains { $0.href == entry.href } ?? false
  }

  /// Adds the entry if it isn't in the list, otherwise removes it.
  func toggle(_ entry: WebDAVEntry, in listID: UUID) {
    guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
    if let j = lists[i].items.firstIndex(where: { $0.href == entry.href }) {
      lists[i].items.remove(at: j)
    } else {
      lists[i].items.insert(ListItem(href: entry.href, name: entry.name, isDirectory: entry.isDirectory), at: 0)
    }
    save()
  }
}
