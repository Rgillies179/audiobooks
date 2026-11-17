import SwiftUI
import UIKit

/// Square cover art, or a coloured placeholder when the book has none.
struct CoverView: View {
    let book: Book
    var thumb = true
    var cornerRadius: CGFloat = 10

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if book.hasCover, let image = CoverCache.image(book.id, thumb: thumb) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Placeholder(title: book.title)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct Placeholder: View {
    let title: String

    var body: some View {
        let hue = Double(title.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % 360) / 360
        ZStack {
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.55),
                                    Color(hue: hue, saturation: 0.7, brightness: 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 8) {
                Image(systemName: "headphones").font(.system(size: 28, weight: .semibold))
                Text(title)
                    .font(.system(.footnote, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// The blurred cover behind the player.
struct Backdrop: View {
    let book: Book

    var body: some View {
        ZStack {
            Color.black
            if book.hasCover, let image = CoverCache.image(book.id, thumb: true) {
                Color.clear
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipped()
                    .blur(radius: 70)
                    .opacity(0.6)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

struct ProgressLine: View {
    let value: Double
    var color: Color = .white

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule().fill(color).frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

/// Shrinks a little while pressed, so taps feel immediate.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    static func tap() { light.impactOccurred() }
}
