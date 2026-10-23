import PFDesign
import SwiftUI

/// The dark loupe that follows a hand on the deck: what is under the needle, to the millisecond, over a waveform
/// hint. The waveform is a placeholder drawn from the track's index until the library supplies real peaks.
struct Loupe: View {
    let heading: String
    let value: String
    let detail: String?
    let seed: Int
    let phase: Double
    @Environment(\.isMonochrome) private var mono

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heading).font(.system(size: 10, weight: .semibold, design: .monospaced)).lineLimit(1)
            Text(value).font(.system(size: 22, weight: .bold, design: .monospaced)).monospacedDigit()
                .accessibilityIdentifier("loupeValue")
            if let detail {
                Text(detail).font(.system(size: 11, design: .monospaced)).opacity(0.75)
            }
            Canvas { context, size in
                let bars = 44
                let w = size.width / CGFloat(bars)
                for i in 0..<bars {
                    let x = Double(i) + phase * 8
                    let h = 0.25 + 0.75 * abs(sin(x * 0.37 + Double(seed)) * cos(x * 0.11 + Double(seed) * 0.7))
                    let fade = 1 - abs(Double(i) - Double(bars) / 2) / Double(bars) * 1.4
                    let bar = CGRect(
                        x: CGFloat(i) * w, y: size.height * (1 - h) / 2, width: w * 0.55, height: size.height * h)
                    context.fill(
                        Path(bar),
                        with: .color(
                            (mono ? Color(white: 0.9) : Color(red: 0.49, green: 1, blue: 0.7)).opacity(max(0.2, fade))))
                }
                context.fill(
                    Path(CGRect(x: size.width / 2 - 0.75, y: -2, width: 1.5, height: size.height + 4)),
                    with: .color(.white))
            }
            .frame(width: 150, height: 20)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.07)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deckLoupe")
    }
}
