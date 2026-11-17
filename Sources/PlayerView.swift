import SwiftUI

struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showChapters = false

    var body: some View {
        if let book = player.book {
            content(book)
                .sheet(isPresented: $showChapters) { ChaptersView() }
        } else {
            Color.black.onAppear { dismiss() }
        }
    }

    @ViewBuilder
    private func content(_ book: Book) -> some View {
        let chapter = player.chapter
        let chapterStart = chapter?.start ?? 0
        let chapterLength = max(chapter?.duration ?? book.duration, 1)
        let elapsed = scrub ?? min(max(player.time - chapterStart, 0), chapterLength)

        VStack(spacing: 0) {
            // Top bar
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Spacer()
                if book.chapters.count > 1 {
                    Text("Chapter \(player.chapterIndex + 1) of \(book.chapters.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            CoverView(book: book, thumb: false, cornerRadius: 14)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .scaleEffect(player.isPlaying ? 1 : 0.9)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .padding(.horizontal, 32)

            Spacer(minLength: 20)

            VStack(spacing: 6) {
                Text(book.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(book.author)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            // Chapter scrubber
            VStack(spacing: 8) {
                Text(chapter?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Slider(value: Binding(get: { elapsed }, set: { scrub = $0 }),
                       in: 0...chapterLength,
                       onEditingChanged: { editing in
                           if !editing, let value = scrub {
                               player.seek(to: chapterStart + value)
                               scrub = nil
                           }
                       })
                       .tint(.white)
                HStack {
                    Text(Format.clock(elapsed))
                    Spacer()
                    Text(Format.left(book.duration - chapterStart - elapsed))
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text("-" + Format.clock(chapterLength - elapsed))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 16)

            // Transport
            HStack {
                control("backward.end.fill", size: 20) { player.previousChapter() }
                Spacer()
                control("gobackward.15", size: 32) { player.skip(by: -Player.back) }
                Spacer()
                Button {
                    player.toggle()
                    Haptics.tap()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 80, height: 80)
                        .background(Circle().fill(.white))
                        .contentShape(Circle())
                }
                Spacer()
                control("goforward.30", size: 32) { player.skip(by: Player.forward) }
                Spacer()
                control("forward.end.fill", size: 20) { player.nextChapter() }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            // Chapters + sleep timer
            HStack {
                Button { showChapters = true } label: {
                    BarLabel(icon: "list.bullet", text: "Chapters")
                }
                Spacer()
                sleepMenu
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 8)
        }
        .buttonStyle(Pressable())
        .foregroundStyle(.white)
        .background { Backdrop(book: book) }
    }

    private func control(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
    }

    private var sleepMenu: some View {
        Menu {
            if player.sleepMode != .off {
                Button("Turn off timer", systemImage: "xmark") { player.setSleep(.off) }
            }
            ForEach([5, 10, 15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("\(minutes) minutes") { player.setSleep(.minutes(minutes)) }
            }
            Button("End of chapter", systemImage: "book.closed") { player.setSleep(.endOfChapter) }
        } label: {
            BarLabel(icon: player.sleepMode == .off ? "moon.zzz" : "moon.zzz.fill",
                     text: sleepText,
                     highlighted: player.sleepMode != .off)
        }
        .menuOrder(.fixed)
    }

    private var sleepText: String {
        switch player.sleepMode {
        case .off: "Sleep timer"
        case .minutes: Format.clock(player.sleepRemaining)
        case .endOfChapter: "End of chapter"
        }
    }
}

private struct BarLabel: View {
    let icon: String
    let text: String
    var highlighted = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.title3)
            Text(text).font(.caption.weight(.medium)).monospacedDigit()
        }
        .foregroundStyle(highlighted ? Color.accent : .white)
        .frame(minWidth: 96, minHeight: 48)
        .contentShape(Rectangle())
    }
}

struct ChaptersView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let book = player.book {
                let current = player.chapterIndex
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button {
                                player.seek(to: chapter.start)
                                if !player.isPlaying { player.play() }
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        if index == current {
                                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accent)
                                        } else {
                                            Text("\(index + 1)").foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 30)
                                    Text(chapter.title)
                                        .foregroundStyle(index == current ? Color.accent : .primary)
                                        .lineLimit(2)
                                    Spacer()
                                    Text(Format.clock(chapter.duration))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
                .navigationTitle("Chapters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let open: () -> Void

    var body: some View {
        if let book = player.book {
            HStack(spacing: 12) {
                CoverView(book: book, cornerRadius: 6)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(player.chapter?.title ?? book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    player.toggle()
                    Haptics.tap()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                Button {
                    player.skip(by: Player.forward)
                    Haptics.tap()
                } label: {
                    Image(systemName: "goforward.30")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(Pressable())
            .foregroundStyle(.white)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                ProgressLine(value: book.duration > 0 ? player.time / book.duration : 0, color: .accent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 1)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }
}
