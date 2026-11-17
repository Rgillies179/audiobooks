import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    let open: (Book) -> Void

    @State private var showImporter = false
    @State private var importFolder = false
    @State private var bookToDelete: Book?

    var body: some View {
        ScrollView {
            if library.importing > 0 {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Importing…").foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 26) {
                ForEach(library.sortedBooks) { book in
                    Button { open(book) } label: {
                        BookCell(book: book, isCurrent: player.book?.id == book.id)
                    }
                    .buttonStyle(Pressable())
                    .contextMenu {
                        Button(role: .destructive) { bookToDelete = book } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .overlay {
            if library.books.isEmpty && library.importing == 0 {
                ContentUnavailableView {
                    Label("No audiobooks yet", systemImage: "books.vertical")
                } description: {
                    Text("Import audiobook files, or a folder per book, from the Files app.")
                } actions: {
                    Button("Import files") { pick(folder: false) }.buttonStyle(.borderedProminent)
                    Button("Import a folder") { pick(folder: true) }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { pick(folder: false) } label: { Label("Import files", systemImage: "doc.badge.plus") }
                    Button { pick(folder: true) } label: { Label("Import folder", systemImage: "folder.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importFolder ? [.folder] : Importer.fileTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importItems(urls) }
        }
        .confirmationDialog("Delete \u{201C}\(bookToDelete?.title ?? "")\u{201D}?",
                            isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: bookToDelete) { book in
            Button("Delete", role: .destructive) {
                if player.book?.id == book.id { player.unload() }
                library.delete(book)
            }
        } message: { _ in
            Text("Its audio files are removed from this app. The originals in Files are not touched.")
        }
        .alert("Import failed",
               isPresented: Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.importError ?? "")
        }
    }

    private func pick(folder: Bool) {
        importFolder = folder
        showImporter = true
    }
}

private struct BookCell: View {
    let book: Book
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverView(book: book)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            ProgressLine(value: book.progress, color: isCurrent ? .accent : .white)
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var status: String {
        if book.isFinished { return "Finished" }
        if book.position < 1 { return "\(book.author) · \(Format.length(book.duration))" }
        return Format.left(book.duration - book.position)
    }
}
