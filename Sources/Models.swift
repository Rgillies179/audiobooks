import Foundation

/// One audio file of a book. `start` is where it begins on the book's timeline.
struct Track: Codable, Hashable {
    var fileName: String
    var start: Double
    var duration: Double
}

/// A chapter on the book's timeline (seconds from the start of the book).
struct Chapter: Codable, Hashable, Identifiable {
    var title: String
    var start: Double
    var duration: Double

    var id: Double { start }
    var end: Double { start + duration }
}

struct Book: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var author: String
    var tracks: [Track]
    var chapters: [Chapter]
    var duration: Double
    var hasCover: Bool
    var position: Double
    var added: Date
    var lastPlayed: Date?

    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
    var isFinished: Bool { duration > 0 && position >= duration - 1 }

    func chapterIndex(at time: Double) -> Int {
        chapters.lastIndex(where: { $0.start <= time + 0.05 }) ?? 0
    }

    func trackIndex(at time: Double) -> Int {
        tracks.lastIndex(where: { $0.start <= time + 0.001 }) ?? 0
    }
}

/// Where everything lives on disk.
enum Storage {
    static let booksDirectory = URL.documentsDirectory.appending(path: "Books", directoryHint: .isDirectory)
    static let libraryFile = URL.applicationSupportDirectory.appending(path: "library.json")

    static func folder(for id: UUID) -> URL {
        booksDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func fileURL(_ id: UUID, _ fileName: String) -> URL {
        folder(for: id).appending(path: fileName)
    }

    static func coverURL(_ id: UUID) -> URL { folder(for: id).appending(path: "cover.jpg") }
    static func thumbURL(_ id: UUID) -> URL { folder(for: id).appending(path: "thumb.jpg") }

    static func prepare() {
        let fm = FileManager.default
        try? fm.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        // Audiobooks are big and already exist elsewhere; keep them out of iCloud backups.
        var url = booksDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.isFinite ? max(0, seconds) : 0)
        let h = t / 3600, m = t % 3600 / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func length(_ seconds: Double) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(.up))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(minutes, 1))m"
    }

    static func left(_ seconds: Double) -> String { length(seconds) + " left" }
}
