import PFCore
import SwiftUI

/// The strip's details (spec §5.7): every field of the signal path, each with a plain-language line, and the volume
/// advice for USB. The strongest claim it makes is "Untouched by pointFlac", never more: nothing here has been
/// verified on hardware yet.
struct SignalDetailsSheet: View {
    let signal: SignalState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(SignalStrip.text(signal)).font(.body.monospaced())
                } footer: {
                    Text(summary)
                }
                if !signal.activeProcessing.isEmpty {
                    Section("Processing, in order") {
                        ForEach(Array(signal.activeProcessing.enumerated()), id: \.offset) { index, name in
                            Text("\(index + 1). \(name)").font(.body.monospacedDigit())
                        }
                    }
                }
                Section {
                    Text(
                        "Hi-Res means the output receives at least 24 bits at a rate above 48 kHz. Lossless is "
                            + "anything up to 48 kHz, kept intact. Both describe what reaches the output, not just "
                            + "the file: a resampled file is Lossless, and Bluetooth and AirPlay are neither.")
                }
                Section("Path") {
                    row("Source", source, "The file as decoded: depth, rate and channels.")
                    row("Processing", processing, "pointFlac's own processing. Pure means none.")
                    row("Handed to iOS", handed, "What pointFlac gives the system's audio unit.")
                    row("Hardware rate", hardware, "The rate the output runs at, as iOS reports it.")
                    row(
                        "Rate change", rateChange, "pointFlac changes the rate only when the output refuses the file's."
                    )
                    row("Depth", depth, "A depth the output can't take is reduced with TPDF dither, never truncated.")
                    row("Output", output, "Bluetooth and AirPlay re-encode, so nothing on them is lossless.")
                }
                if let volume = signal.systemVolume {
                    Section {
                        row("System volume", "\(Int((volume * 100).rounded()))%", nil)
                    } footer: {
                        Text(
                            "On a USB DAC, keep the phone at 100% and turn the DAC's own volume down: below 100%, "
                                + "iOS scales the samples on their way out.")
                    }
                }
            }
            .navigationTitle("Signal")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, _ value: String, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(title, value: value).font(.body.monospacedDigit())
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// One line for the indicator the strip shows, so the sheet never contradicts it.
    private var summary: String {
        switch signal.indicator {
        case .idle: "Nothing is playing."
        case .pending: "Starting: the output is being set up for this track, so nothing about the path is known yet."
        case .pure: "Untouched by pointFlac: no processing, and the output runs at the file's rate."
        case .resampled: "The rate changes on the way out. \(rateChange)."
        case .depthReduced(let from, let to):
            "pointFlac reduces \(from)-bit to \(to)-bit with TPDF dither, because the output can't take \(from)-bit."
        case .processing(let count): "pointFlac's processing is on: \(count) block\(count == 1 ? "" : "s")."
        case .scrubbing: "A finger is on the record: the sound follows the hand."
        case .bluetoothLossy: "Bluetooth: iOS re-encodes for the headphones, so nothing on this route is lossless."
        case .airPlay: "AirPlay: the receiver gets a re-encoded stream, whatever pointFlac hands it."
        case .downmixed(let from, let to): "The output has \(to) channels, so iOS mixes the file's \(from) down."
        case .otherRoute: "This route is of a kind pointFlac doesn't know. It may alter the audio."
        }
    }

    private var source: String {
        guard let s = signal.source else { return "—" }
        return "\(s.formattedDepth) · \(s.formattedRate) · \(s.channels) ch"
    }

    /// "Pure" only when the strip says Pure; otherwise what pointFlac itself does.
    private var processing: String {
        if !signal.activeProcessing.isEmpty { return signal.activeProcessing.joined(separator: ", ") }
        return signal.indicator == .pure ? "None (Pure)" : "None by pointFlac"
    }

    private var handed: String {
        guard let plan = signal.plan else { return "—" }
        let client = plan.client == .float32 ? "32-bit float" : "32-bit integer"
        let rate = AudioFormat.formatRate(plan.clientSampleRate)
        return "\(client) · \(rate)"
    }

    private var hardware: String {
        signal.hardwareRate.map { AudioFormat.formatRate($0) } ?? "—"
    }

    /// The rate change the strip shows, and who makes it: pointFlac before the output, or iOS after it.
    private var rateChange: String {
        guard case .resampled(let change) = signal.indicator else { return "None" }
        let from = AudioFormat.formatRate(change.from)
        let to = AudioFormat.formatRate(change.to)
        let byPointFlac = signal.plan?.resample.map { $0 == change } ?? false
        return "\(from) → \(to), by \(byPointFlac ? "pointFlac" : "iOS, after pointFlac's output")"
    }

    private var depth: String {
        guard let plan = signal.plan else { return "—" }
        return plan.reduceTo24 ? "Reduced to 24-bit, dithered" : "Unchanged"
    }

    private var output: String {
        switch signal.port {
        case .usb(let name): "USB · \(name)"
        case .wired(let name): "Wired · \(name)"
        case .bluetooth(let name): "Bluetooth · \(name)"
        case .builtIn: "Built-in speaker"
        case .airPlay(let name): "AirPlay · \(name)"
        case .other(let name): "Other · \(name)"
        case nil: "—"
        }
    }
}
