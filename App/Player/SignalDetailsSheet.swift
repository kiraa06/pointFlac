import PFCore
import SwiftUI

/// The strip's details (spec §5.7): every field of the signal path, each with a plain-language line, and the volume
/// advice for USB. The strongest claim it makes is "Untouched by pointFlac", never more: nothing here has been
/// verified on hardware yet. While blocks are processing, Open Sound goes to the chain (spec §5.7: tapping
/// Processing opens it).
struct SignalDetailsSheet: View {
    let signal: SignalState
    /// Closes the sheet and shows the Sound tab.
    var openSound: (() -> Void)?

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
                        if let openSound {
                            Button("Open Sound", systemImage: "slider.vertical.3", action: openSound)
                                .accessibilityHint("Shows the Sound tab, where the blocks are switched")
                                .accessibilityIdentifier("openSoundButton")
                        }
                    }
                }
                Section {
                    Text(
                        "Hi-Res means the file's 24 bits or more leave pointFlac intact at a hardware rate above "
                            + "48 kHz, on a route iOS doesn't tune (USB or wired). Lossless is the same hand-off at "
                            + "48 kHz or below. The built-in speaker is tuned by iOS, and Bluetooth and AirPlay "
                            + "re-encode, so none of them gets either claim.")
                }
                if !outputFacts.isEmpty {
                    Section("Output") {
                        ForEach(outputFacts, id: \.label) { fact in
                            if fact.value.isEmpty {
                                Text(fact.label).font(.callout)
                            } else {
                                LabeledContent(fact.label, value: fact.value)
                                    .font(.callout)
                                    .accessibilityElement(children: .combine)
                            }
                        }
                    }
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
        case .resampled: "The rate changes on the way out. \(rateChange ?? "")."
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

    /// Only what pointFlac can state as fact: what the file is, what pointFlac does, what it sends iOS, what iOS
    /// reports, and what it can't see. Nothing here claims the converter's bit depth, which iOS does not report.
    /// A fact with an empty value is a sentence on its own.
    private var outputFacts: [(label: String, value: String)] {
        guard let source = signal.source, let plan = signal.plan else { return [] }
        var facts: [(label: String, value: String)] = [
            ("File", "FLAC \(source.formattedDepth) \(source.formattedRate) · \(source.channels) ch"),
            ("pointFlac's processing", processing),
        ]
        var changes: [String] = []
        let change = rateChange
        if change == nil, let resample = plan.resample, resample.from != resample.to {
            changes.append("resampled from \(AudioFormat.formatRate(resample.from))")
        }
        if plan.reduceTo24 { changes.append("dithered from \(source.bitsPerSample)-bit to 24-bit") }
        let format = plan.client == .float32 ? "32-bit float" : "32-bit integer"
        let note = changes.isEmpty ? "unchanged" : changes.joined(separator: "; ")
        facts.append(("pointFlac sends iOS", "\(format) at \(AudioFormat.formatRate(plan.clientSampleRate)) (\(note))"))
        if let change { facts.append(("Rate change", change)) }
        if let rate = signal.hardwareRate {
            facts.append(("Hardware rate", "\(AudioFormat.formatRate(rate)) (reported by iOS)"))
        }
        facts.append(("Converter bit depth", "not reported by iOS"))
        switch signal.port {
        case .builtIn:
            facts.append(("After pointFlac", "iOS speaker tuning, which apps can't inspect or turn off"))
        case .usb, .wired:
            facts.append(
                ("After pointFlac", "iOS converts to the DAC's format. Below full volume it scales the samples."))
        default: break
        }
        facts.append(
            (
                "iOS audio settings such as Headphone Accommodations can also change the sound; pointFlac can't see them.",
                ""
            ))
        return facts
    }

    /// "Pure" only when the strip says Pure; otherwise what pointFlac itself does.
    private var processing: String {
        if !signal.activeProcessing.isEmpty { return signal.activeProcessing.joined(separator: ", ") }
        return signal.indicator == .pure ? "None (Pure)" : "None by pointFlac"
    }

    /// The rate change the strip shows, and who makes it: pointFlac before the output, or iOS after it.
    private var rateChange: String? {
        guard case .resampled(let change) = signal.indicator else { return nil }
        let from = AudioFormat.formatRate(change.from)
        let to = AudioFormat.formatRate(change.to)
        let byPointFlac = signal.plan?.resample.map { $0 == change } ?? false
        return "\(from) → \(to), by \(byPointFlac ? "pointFlac" : "iOS, after pointFlac's output")"
    }
}
