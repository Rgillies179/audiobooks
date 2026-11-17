import AVFoundation
import UIKit
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case noAudio

    var errorDescription: String? {
        switch self {
        case .noAudio: "No playable audio files found."
        }
    }
}

/// Copies a picked file or folder into the app and reads its title, author, cover and chapters.
/// Runs off the main thread so the UI stays smooth during big imports.
enum Importer {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "mp4", "wav", "aif", "aiff", "caf", "flac"]
    static let fileTypes: [UTType] = [.audio, .mpeg4Audio, .mp3] + [UTType(filenameExtension: "m4b")].compactMap { $0 }

    static func makeBook(from source: URL) async throws -> Book {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let isFolder = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let files = isFolder ? audioFiles(in: source) : [source]
        guard !files.isEmpty else { throw ImportError.noAudio }

        let id = UUID()
        let folder = Storage.folder(for: id)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            var tracks: [Track] = []
            var chapters: [Chapter] = []
            var firstTitle: String?
            var album: String?
            var author: String?
            var cover: Data?
            var offset = 0.0

            for (i, file) in files.enumerated() {
                let fileName = String(format: "%03d.", i) + file.pathExtension.lowercased()
                let dest = folder.appending(path: fileName)
                try copy(file, to: dest)

                let asset = AVURLAsset(url: dest, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let seconds = (try? await asset.load(.duration))?.seconds ?? 0
                guard seconds.isFinite, seconds > 0 else {
                    try? fm.removeItem(at: dest)
                    continue
                }

                let meta = (try? await asset.load(.commonMetadata)) ?? []
                let fileTitle = await text(meta, .commonIdentifierTitle)
                if tracks.isEmpty {
                    firstTitle = fileTitle
                    album = await text(meta, .commonIdentifierAlbumName)
                }
                if author == nil { author = await text(meta, .commonIdentifierArtist) }
                if author == nil { author = await text(meta, .commonIdentifierAuthor) }
                if author == nil { author = await text(meta, .commonIdentifierCreator) }
                if cover == nil { cover = await artwork(meta) }

                let groups = (try? await asset.loadChapterMetadataGroups(
                    bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
                var added = 0
                if groups.count > 1 {
                    for group in groups {
                        let start = group.timeRange.start.seconds
                        let length = group.timeRange.duration.seconds
                        guard start.isFinite, length.isFinite, length > 0 else { continue }
                        let name = await text(group.items, .commonIdentifierTitle) ?? "Chapter \(chapters.count + 1)"
                        chapters.append(Chapter(title: name, start: offset + start, duration: length))
                        added += 1
                    }
                }
                if added == 0 {
                    let name = isFolder ? (fileTitle ?? file.deletingPathExtension().lastPathComponent)
                                        : "Chapter \(chapters.count + 1)"
                    chapters.append(Chapter(title: name, start: offset, duration: seconds))
                }

                tracks.append(Track(fileName: fileName, start: offset, duration: seconds))
                offset += seconds
            }

            guard !tracks.isEmpty else { throw ImportError.noAudio }

            if cover == nil, isFolder { cover = folderImage(in: source) }
            var hasCover = false
            if let cover, let image = UIImage(data: cover) {
                try? resized(image, maxSide: 1200).jpegData(compressionQuality: 0.9)?.write(to: Storage.coverURL(id))
                try? resized(image, maxSide: 600).jpegData(compressionQuality: 0.85)?.write(to: Storage.thumbURL(id))
                hasCover = true
            }

            let name = source.deletingPathExtension().lastPathComponent
            let title = isFolder ? (album ?? name) : (firstTitle ?? album ?? name)

            return Book(id: id, title: title, author: author ?? "Unknown author",
                        tracks: tracks, chapters: chapters, duration: offset,
                        hasCover: hasCover, position: 0, added: .now, lastPlayed: nil)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - Helpers

    /// Audio files in a folder (and its subfolders), in natural order: "2" before "10".
    private static func audioFiles(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        while let url = walker.nextObject() as? URL {
            if audioExtensions.contains(url.pathExtension.lowercased()) { result.append(url) }
        }
        return result.sorted {
            $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending
        }
    }

    /// A cover.jpg / folder.png style image sitting next to the audio files.
    private static func folderImage(in folder: URL) -> Data? {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let images = items.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        let preferred = images.first { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return ["cover", "folder", "front", "album", "art"].contains { name.contains($0) }
        }
        guard let url = preferred ?? images.first else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Copies through a file coordinator so files still in iCloud Drive get downloaded first.
    private static func copy(_ source: URL, to dest: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { url in
            do { try FileManager.default.copyItem(at: url, to: dest) } catch { copyError = error }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    private static func text(_ items: [AVMetadataItem], _ identifier: AVMetadataIdentifier) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func artwork(_ items: [AVMetadataItem]) async -> Data? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first
        else { return nil }
        return try? await item.load(.dataValue)
    }

    private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
