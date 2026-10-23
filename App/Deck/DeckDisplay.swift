import PFDesign
import SwiftUI

/// The deck's dot-matrix screen and what it says: track code, title, artist, time, and the rate and depth. A view of
/// its own because it reads the player's position, which changes ten times a second: only this screen redraws.
/// Tapping it unfolds the record's tracklist (plan 9 §3), when `open` is given. Every design keeps it, in its own
/// ink and window.
struct DeckScreen: View {
    let playback: PlaybackController
    let paint: DeckPaint
    let size: CGSize
    var open: (() -> Void)?

    /// Where the screen sits on a plinth of `size`: bottom right, under the platter. The unfolding tracklist grows
    /// out of this frame.
    static func frame(in size: CGSize) -> CGRect {
        let w = size.width * 0.5
        let h: CGFloat = 38
        return CGRect(x: size.width - w - size.width * 0.045, y: size.height - h - 12, width: w, height: h)
    }

    var body: some View {
        let lines = lcdLines
        let frame = Self.frame(in: size)
        DeckDisplay(lines: lines, paint: paint)
            .frame(width: frame.width, height: frame.height)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { open?() }
            .position(x: frame.midX, y: frame.midY)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(lines.joined(separator: ", "))
            .modifier(UnfoldAction(open: open))
            .accessibilityIdentifier("deckDisplay")
    }

    /// The screen is a button only while there is a tracklist to unfold: then it says so and activates; otherwise
    /// it is plain text.
    private struct UnfoldAction: ViewModifier {
        let open: (() -> Void)?

        func body(content: Content) -> some View {
            if let open {
                content
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Unfolds the record's tracklist")
                    .accessibilityAction { open() }
            } else {
                content
            }
        }
    }

    private var sideLetter: String? {
        let sides = playback.layout.sides
        return sides.indices.contains(playback.currentSide) ? sides[playback.currentSide].letter : nil
    }

    private var lcdLines: [String] {
        guard let album = playback.album else { return ["NO RECORD", "—"] }
        let format = playback.player.signal.source.map { "\($0.sampleRate / 1000)K/\($0.bitsPerSample)" } ?? ""
        if let index = playback.trackIndex {
            let track = playback.tracks[index]
            return [
                "\(playback.layout.code(ofTrack: index)) \(track.title.uppercased())·\(track.artist.uppercased())",
                "\(ClockFormat.clock(playback.player.position.seconds))  33⅓  \(format)",
            ]
        }
        return ["\(album.title.uppercased())·\(album.artist.uppercased())", "CUE \(sideLetter ?? "A")1  33⅓"]
    }
}

/// The display as a design draws it: Glasshouse's bare dot-matrix window exactly as before, and on the other decks
/// the same window set into the plinth behind a dark bezel, its glass catching a line of light.
struct DeckDisplay: View {
    let lines: [String]
    let paint: DeckPaint

    /// A light plinth gets a lighter bezel, so the window sits in it rather than being outlined.
    private var bezel: Double {
        switch paint.design.plinth {
        case .lacquer: 0.22
        case .brushedMetal: 0.5
        default: 0.7
        }
    }

    var body: some View {
        if paint.isGlass {
            DotMatrixScreen(lines: lines, ink: paint.displayInk, back: paint.displayBack)
        } else {
            DotMatrixScreen(lines: lines, ink: paint.displayInk, back: paint.displayBack)
                .padding(1.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(bezel))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.black.opacity(0.5), .white.opacity(0.3)], startPoint: .topLeading,
                                endPoint: .bottomTrailing), lineWidth: 0.8)
                )
                .overlay(alignment: .top) {
                    // The cover glass's reflection, a thin line near its top.
                    LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                        .padding(.horizontal, 3)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
        }
    }
}

/// The deck's dot-matrix screen: SF Mono through a pixel grid, with a faint glow.
struct DotMatrixScreen: View {
    let lines: [String]
    let ink: Color
    let back: Color

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(back)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).lineLimit(1)
                }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(ink)
            .shadow(color: ink.opacity(0.6), radius: 3)
            .padding(.horizontal, 8)
            DotGrid(back: back)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The pixel grid laid over the dot-matrix faces: dark lines between the dots break the glyphs into a matrix. It
/// stays put while what is under it scrolls, as a real display's pixels do.
struct DotGrid: View {
    let back: Color

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 0.6, height: size.height)), with: .color(back.opacity(0.75)))
                x += 1.6
            }
            var y: CGFloat = 0
            while y < size.height {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.6)), with: .color(back.opacity(0.75)))
                y += 1.6
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Theme {
    /// This look with the deck's display colours: the tracklist the display unfolds into is drawn in the same ink and
    /// window as the display it grows out of.
    func withDisplay(ink: Color, back: Color) -> Theme {
        Theme(
            isDark: isDark, background: background, ink: self.ink, inkSecondary: inkSecondary, hairline: hairline,
            ok: ok, altered: altered, warn: warn, hiRes: hiRes, playFill: playFill, playGlyph: playGlyph,
            plinthTop: plinthTop, plinthBottom: plinthBottom, plinthEdge: plinthEdge, strobe: strobe, lcdBack: back,
            lcdInk: ink, glow: glow, isMonochrome: isMonochrome)
    }
}
