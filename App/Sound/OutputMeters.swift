import PFAudio
import PFDSP
import SwiftUI

extension Theme {
    /// The Sound tab's accent for whatever processes the sound: the strip's violet, or Monochrome's control grey.
    var processingTint: Color { isMonochrome ? Theme.monochromeTint : altered }

    /// The clip LED: red, or under Monochrome a bright grey on dark and a dark grey on light.
    var clip: Color {
        if isMonochrome { return Color(white: isDark ? 0.97 : 0.1) }
        return isDark ? Color(red: 1, green: 0.32, blue: 0.30) : Color(red: 0.84, green: 0.12, blue: 0.12)
    }
}

/// The deck's screen, as a panel: the dot-matrix display's dark glass, which the EQ graph and the meters draw on in
/// light and dark alike.
struct ScreenPanel: View {
    let theme: Theme
    var cornerRadius: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.lcdBack)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(theme.lcdInk.opacity(0.12), lineWidth: 1)
            )
    }
}

/// The meters' ballistics. `Player.soundMeters` starts a new peak interval on every read, so this is its one reader:
/// the output and gain-reduction meters share it, and every read feeds it, so no peak between two frames is lost.
///
/// - Output: the bar rises at once and falls at 24 dB/s; a peak-hold mark stays 1.5 s, then falls at 20 dB/s.
/// - Gain reduction: the limiter reports each render block's deepest reduction, too brief to see, so it gets the same
///   instant rise with a 12 dB/s fall, and a 1.5 s hold mark of its own.
/// - Clip: lit for 2 s whenever the clip count goes up (from the first reading on, so old overs never light it).
@MainActor
final class MeterBallistics {
    static let floorDb = -120.0
    static let fallDbPerSecond = 24.0
    static let holdFallDbPerSecond = 20.0
    static let reductionFallDbPerSecond = 12.0
    static let holdSeconds = 1.5
    static let clipSeconds = 2.0

    private(set) var level = floorDb
    private(set) var peakHold = floorDb
    private(set) var reduction = 0.0
    private(set) var reductionHold = 0.0
    private var peakHoldUntil = Date.distantPast
    private var reductionHoldUntil = Date.distantPast
    private var clipUntil = Date.distantPast
    private var lastClipCount: Int?
    private var lastRead: Date?

    /// Reads the player's meters, unless they were read for this frame already.
    func poll(_ player: Player, at now: Date) {
        if let lastRead, abs(now.timeIntervalSince(lastRead)) < 0.004 { return }
        feed(player.soundMeters, at: now)
    }

    func feed(_ m: SoundMeters, at now: Date) {
        let dt = lastRead.map { min(max(now.timeIntervalSince($0), 0), 0.25) } ?? 0
        lastRead = now
        let peak = m.peakDbFS.isFinite ? max(m.peakDbFS, Self.floorDb) : Self.floorDb
        level = max(peak, level - Self.fallDbPerSecond * dt)
        if peak >= peakHold {
            peakHold = peak
            peakHoldUntil = now + Self.holdSeconds
        } else if now > peakHoldUntil {
            peakHold = max(peakHold - Self.holdFallDbPerSecond * dt, level)
        }
        let gr = m.gainReductionDb.isFinite ? max(m.gainReductionDb, 0) : 0
        reduction = max(gr, reduction - Self.reductionFallDbPerSecond * dt)
        if gr >= reductionHold {
            reductionHold = gr
            reductionHoldUntil = now + Self.holdSeconds
        } else if now > reductionHoldUntil {
            reductionHold = max(reductionHold - Self.reductionFallDbPerSecond * dt, reduction)
        }
        if let lastClipCount, m.clipCount > lastClipCount { clipUntil = now + Self.clipSeconds }
        lastClipCount = m.clipCount
    }

    func clipLit(at now: Date) -> Bool { now < clipUntil }
}

/// A row of LED segments, for both meters. `fromRight` fills from the right-hand end (gain reduction).
private struct SegmentBar: View {
    let fraction: Double
    let holdFraction: Double
    let segments: Int
    var fromRight = false
    let color: (Double) -> Color

    var body: some View {
        Canvas { context, size in
            let gap: CGFloat = 1.5
            let w = (size.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
            let lit = Int((fraction * Double(segments)).rounded(.up))
            let hold = min(Int((holdFraction * Double(segments)).rounded(.up)), segments)
            for i in 0..<segments {
                let position = Double(i) / Double(segments - 1)
                let x = fromRight ? size.width - CGFloat(i + 1) * w - CGFloat(i) * gap : CGFloat(i) * (w + gap)
                let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                let on = i < lit || (hold > 0 && i == hold - 1)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1), with: .color(color(position).opacity(on ? 1 : 0.13)))
            }
        }
    }
}

/// The output meter after the whole chain, in dBFS, with its clip LED.
struct OutputMeter: View {
    let meters: MeterBallistics
    let player: Player
    /// The screen's look (always dark).
    let theme: Theme
    let polling: Bool

    static let rangeDb = 60.0
    private static let marks: [Double] = [-48, -36, -24, -12, -6, 0]

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !polling)) { context in
            let _ = meters.poll(player, at: context.date)
            let clip = meters.clipLit(at: context.date)
            panel(level: meters.level, hold: meters.peakHold, clip: clip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Output level")
                .accessibilityValue(spoken(hold: meters.peakHold, clip: clip))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("outputMeter")
        }
    }

    private func panel(level: Double, hold: Double, clip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("OUTPUT").font(Typeface.cellLabel).tracking(1.4).foregroundStyle(theme.lcdInk.opacity(0.65))
                Spacer(minLength: 4)
                Text(SoundFormat.level(hold))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.lcdInk)
                    .contentTransition(.identity)
                Text("dBFS").font(Typeface.cellLabel).foregroundStyle(theme.lcdInk.opacity(0.6))
                ClipLED(lit: clip, theme: theme)
                    .padding(.leading, 6)
            }
            SegmentBar(
                fraction: fraction(level), holdFraction: fraction(hold), segments: 40,
                color: { position in segmentColor(position * Self.rangeDb - Self.rangeDb) }
            )
            .frame(height: 9)
            scale
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ScreenPanel(theme: theme))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var scale: some View {
        Canvas { context, size in
            for db in Self.marks {
                let x = (db + Self.rangeDb) / Self.rangeDb * size.width
                let label = Text(db == 0 ? "0" : SoundFormat.signed(db, decimals: 0))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.lcdInk.opacity(0.5))
                context.draw(label, at: CGPoint(x: x, y: 0), anchor: db == 0 ? .topTrailing : .top)
            }
        }
        .frame(height: 10)
    }

    private func fraction(_ db: Double) -> Double {
        min(max((db + Self.rangeDb) / Self.rangeDb, 0), 1)
    }

    /// Green to −12 dBFS, amber to −3, then the clip colour.
    private func segmentColor(_ db: Double) -> Color {
        if db >= -3 { return theme.clip }
        if db >= -12 { return theme.warn }
        return theme.ok
    }

    private func spoken(hold: Double, clip: Bool) -> String {
        let peak = hold <= MeterBallistics.floorDb + 0.05 ? "silent" : "peak \(Int(hold.rounded())) decibels full scale"
        return clip ? "Clipped, \(peak)" : peak
    }
}

/// The clip indicator: lit for two seconds after an over.
struct ClipLED: View {
    let lit: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(theme.clip.opacity(lit ? 1 : 0.18))
                .frame(width: 8, height: 8)
                .shadow(color: theme.clip.opacity(lit ? 0.9 : 0), radius: lit ? 4 : 0)
            Text("CLIP")
                .font(Typeface.cellLabel)
                .tracking(1)
                .foregroundStyle(lit ? theme.clip : theme.lcdInk.opacity(0.45))
        }
        .accessibilityHidden(true)
    }
}

/// The limiter's gain reduction, filling leftward from 0 dB.
struct GainReductionMeter: View {
    let meters: MeterBallistics
    let source: Player
    /// The screen's look (always dark).
    let theme: Theme
    let polling: Bool

    static let rangeDb = 12.0
    private static let marks: [Double] = [12, 9, 6, 3, 0]

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !polling)) { context in
            let _ = meters.poll(source, at: context.date)
            panel(reduction: meters.reduction, hold: meters.reductionHold)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Limiter gain reduction")
                .accessibilityValue(
                    meters.reductionHold < 0.05
                        ? "none" : "\(SoundFormat.trimmed(SoundFormat.tenth(meters.reductionHold))) decibels"
                )
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("gainReductionMeter")
        }
    }

    private func panel(reduction: Double, hold: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("GAIN REDUCTION").font(Typeface.cellLabel).tracking(1.4)
                    .foregroundStyle(theme.lcdInk.opacity(0.65))
                Spacer(minLength: 4)
                Text(hold < 0.05 ? "0.0" : SoundFormat.signed(-hold))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.lcdInk)
                Text("dB").font(Typeface.cellLabel).foregroundStyle(theme.lcdInk.opacity(0.6))
            }
            SegmentBar(
                fraction: min(reduction / Self.rangeDb, 1), holdFraction: min(hold / Self.rangeDb, 1), segments: 24,
                fromRight: true, color: { _ in theme.warn }
            )
            .frame(height: 9)
            Canvas { context, size in
                for db in Self.marks {
                    let x = size.width - db / Self.rangeDb * size.width
                    let label = Text(db == 0 ? "0" : SoundFormat.signed(-db, decimals: 0))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.lcdInk.opacity(0.5))
                    context.draw(
                        label, at: CGPoint(x: x, y: 0),
                        anchor: db == 0 ? .topTrailing : db == Self.rangeDb ? .topLeading : .top)
                }
            }
            .frame(height: 10)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ScreenPanel(theme: theme))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}
