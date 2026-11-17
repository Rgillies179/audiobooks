import Foundation
import Observation
import UIKit

@MainActor @Observable
final class Library {
    private(set) var books: [Book] = []
    private(set) var importing = 0
    var importError: String?

    init() {
        Storage.prepare()
        load()
    }

    /// Most recently listened (or added) first.
    var sortedBooks: [Book] {
        books.sorted { ($0.lastPlayed ?? $0.added) > ($1.lastPlayed ?? $1.added) }
    }

    var lastPlayed: Book? {
        books.filter { $0.lastPlayed != nil }.max { $0.lastPlayed! < $1.lastPlayed! }
    }

    func importItems(_ urls: [URL]) {
        Task {
            for url in urls {
                importing += 1
                do {
                    let book = try await Importer.makeBook(from: url)
                    books.append(book)
                    save()
                } catch {
                    importError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
                importing -= 1
            }
        }
    }

    func updatePosition(_ id: UUID, _ position: Double) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].position = position
        books[i].lastPlayed = .now
        save()
    }

    func delete(_ book: Book) {
        try? FileManager.default.removeItem(at: Storage.folder(for: book.id))
        books.removeAll { $0.id == book.id }
        CoverCache.remove(book.id)
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Storage.libraryFile),
              let decoded = try? JSONDecoder().decode([Book].self, from: data) else { return }
        books = decoded.filter {
            FileManager.default.fileExists(atPath: Storage.folder(for: $0.id).path(percentEncoded: false))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(books) else { return }
        try? data.write(to: Storage.libraryFile, options: .atomic)
    }
}

/// Covers are read from disk once and kept in memory.
@MainActor
enum CoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ id: UUID, thumb: Bool) -> UIImage? {
        let key = "\(id.uuidString)-\(thumb)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let url = thumb ? Storage.thumbURL(id) : Storage.coverURL(id)
        guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func remove(_ id: UUID) {
        cache.removeObject(forKey: "\(id.uuidString)-true" as NSString)
        cache.removeObject(forKey: "\(id.uuidString)-false" as NSString)
    }
}
