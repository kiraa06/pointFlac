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

    private var summary: String {
        switch signal.indicator {
        case .pure: "Untouched by pointFlac: no processing, and the output runs at the file's rate."
        case .idle: "Nothing is playing."
        case .pending: "Starting: the output is being set up for this track."
        default: "pointFlac or the route changes this signal, and the strip says how."
        }
    }

    private var source: String {
        guard let s = signal.source else { return "—" }
        return "\(s.formattedDepth) · \(s.formattedRate) · \(s.channels) ch"
    }

    private var processing: String {
        signal.activeProcessing.isEmpty ? "None (Pure)" : signal.activeProcessing.joined(separator: ", ")
    }

    private var handed: String {
        guard let plan = signal.plan else { return "—" }
        let client = plan.client == .float32 ? "32-bit float" : "32-bit integer"
        let rate = AudioFormat(sampleRate: plan.clientSampleRate, bitsPerSample: 0, channels: 0).formattedRate
        return "\(client) · \(rate)"
    }

    private var hardware: String {
        signal.hardwareRate.map { AudioFormat(sampleRate: $0, bitsPerSample: 0, channels: 0).formattedRate } ?? "—"
    }

    private var rateChange: String {
        guard let change = signal.plan?.resample else { return "None" }
        let from = AudioFormat(sampleRate: change.from, bitsPerSample: 0, channels: 0).formattedRate
        let to = AudioFormat(sampleRate: change.to, bitsPerSample: 0, channels: 0).formattedRate
        return "\(from) → \(to)"
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
