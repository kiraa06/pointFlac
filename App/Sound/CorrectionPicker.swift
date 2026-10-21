import Observation
import PFDSP
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: Catalog

/// The OPRA presets the app bundles (`opra.json`, CC BY-SA 4.0, built by `scripts/build-opra.swift`), grouped by
/// vendor, with a search over vendor and product and a small preview of each preset's curve. Read once, off the main
/// actor, the first time the picker or the correction row asks.
@MainActor
@Observable
final class OPRACatalog {
    static let shared = OPRACatalog()

    struct Entry: Identifiable, Sendable {
        let preset: OPRAPreset
        /// "sennheiser hd 600", folded for matching.
        let key: String
        /// The same with no spaces, hyphens or dots, so "hd600" finds "HD 600".
        let compactKey: String
        /// The correction's shape (its bands, without its preamp), at 20 Hz to 20 kHz, in dB.
        let preview: [Double]
        var id: String { preset.id }
    }

    struct Vendor: Identifiable, Sendable {
        let name: String
        let entries: [Entry]
        var id: String { name }
    }

    enum State: Equatable {
        case idle, loading, loaded, failed
    }

    private(set) var vendors: [Vendor] = []
    private(set) var state = State.idle
    /// Observed like the rest, so a view that looked a preset up before the file was read redraws once it is.
    private var byID: [String: Entry] = [:]

    /// Starts reading the bundle's file, unless it is read or being read.
    func load() {
        guard state == .idle || state == .failed else { return }
        state = .loading
        Task {
            let built = await Task.detached(priority: .userInitiated) { Self.build() }.value
            guard let built else {
                state = .failed
                return
            }
            vendors = built
            byID = Dictionary(built.flatMap(\.entries).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            state = .loaded
        }
    }

    func entry(id: String) -> Entry? { byID[id] }

    /// The vendors and presets whose "vendor product" holds every word of `query`, or all of them for an empty query.
    func search(_ query: String) -> [Vendor] {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return vendors }
        let compact = Self.compact(Self.fold(query))
        return vendors.compactMap { vendor in
            let found = vendor.entries.filter { entry in
                words.allSatisfy { entry.key.contains($0) } || entry.compactKey.contains(compact)
            }
            return found.isEmpty ? nil : Vendor(name: vendor.name, entries: found)
        }
    }

    nonisolated private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func compact(_ s: String) -> String {
        s.filter { !" -._/".contains($0) }
    }

    nonisolated private static func build() -> [Vendor]? {
        guard let url = Bundle.main.url(forResource: "opra", withExtension: "json"),
            let data = try? Data(contentsOf: url), let presets = try? OPRAPreset.catalog(from: data)
        else { return nil }
        let entries = presets.map { preset in
            let key = fold("\(preset.vendor) \(preset.product)")
            return Entry(preset: preset, key: key, compactKey: compact(key), preview: previewCurve(preset))
        }
        let grouped = Dictionary(grouping: entries, by: \.preset.vendor)
        return grouped.map { name, entries in
            Vendor(
                name: name,
                entries: entries.sorted { a, b in
                    let product = a.preset.product.localizedStandardCompare(b.preset.product)
                    if product != .orderedSame { return product == .orderedAscending }
                    return a.preset.details.localizedStandardCompare(b.preset.details) == .orderedAscending
                })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The correction's own curve without its preamp, so every preview is centred on 0 dB.
    nonisolated static func previewCurve(_ preset: OPRAPreset) -> [Double] {
        var s = SoundSettings()
        s.pure = false
        s.correction = preset.correction
        s.correction.preampDb = 0
        return SoundResponse.curveDb(s, sampleRate: 48_000, points: 48).map(\.db)
    }
}

// MARK: Credit

/// How a correction is credited: an OPRA preset as "EQ by <author> · OPRA" (OPRA's terms: the author more prominent
/// than OPRA), an imported file by its file name.
struct CorrectionCredit {
    let correction: CorrectionSettings

    init(_ correction: CorrectionSettings) {
        self.correction = correction
    }

    var isChosen: Bool { !correction.bands.isEmpty }

    var name: String { correction.name.isEmpty ? "Headphone correction" : correction.name }

    /// "EQ by oratory1990", or "From Sennheiser HD 600 ParametricEQ.txt".
    var byline: String {
        switch correction.source {
        case .autoEq(let fileName): "From \(fileName)"
        case .opra, .none: correction.author.isEmpty ? "EQ by an unknown author" : "EQ by \(correction.author)"
        }
    }

    /// "· OPRA" after an OPRA preset's byline, smaller than it.
    var sourceMark: String? {
        if case .opra = correction.source { return "OPRA" }
        return nil
    }

    /// "Sennheiser HD 600, EQ by oratory1990, OPRA", for VoiceOver.
    var spoken: String { [name, byline, sourceMark].compactMap { $0 }.joined(separator: ", ") }

    /// The block header's line, short, since the row below names the headphones and credits the author: "OPRA preset
    /// · 10 bands", "Imported file · 10 bands".
    var summary: String {
        guard isChosen else { return "No headphones chosen" }
        let bands = correction.bands.filter(\.enabled).count
        let kind = if case .autoEq = correction.source { "Imported file" } else { "OPRA preset" }
        return "\(kind) · \(bands) band\(bands == 1 ? "" : "s")"
    }
}

// MARK: The correction row

/// The headphone correction in force: the headphones, the credit, its preamp and size, and Choose… for the picker.
struct CorrectionRows: View {
    let correction: CorrectionSettings
    let theme: Theme
    let choose: () -> Void

    private var catalog: OPRACatalog { .shared }

    private var credit: CorrectionCredit { CorrectionCredit(correction) }

    /// The OPRA preset's details ("Harman Target"), once the catalog is read.
    private var details: String? {
        guard case .opra(let id) = correction.source, let preset = catalog.entry(id: id)?.preset else { return nil }
        return preset.details.isEmpty ? nil : preset.details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if credit.isChosen {
                VStack(alignment: .leading, spacing: 3) {
                    Text(credit.name)
                        .font(.headline)
                        .foregroundStyle(theme.ink)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(credit.byline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.ink)
                        if let mark = credit.sourceMark {
                            Text("· \(mark)")
                                .font(.caption)
                                .foregroundStyle(theme.inkSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(credit.spoken)
                .accessibilityIdentifier("correctionPreset")
                Readout(
                    cells: [
                        ReadoutCell(label: "Target", value: details ?? (credit.sourceMark == nil ? "Your file" : "—")),
                        ReadoutCell(label: "Bands", value: "\(correction.bands.filter(\.enabled).count)"),
                        ReadoutCell(
                            label: "Preamp", value: SoundFormat.gain(correction.preampDb),
                            active: correction.enabled),
                    ], theme: theme
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Correction preamp")
                .accessibilityValue(
                    "\(SoundFormat.gainSpoken(correction.preampDb)), \(correction.bands.count) bands"
                        + (details.map { ", \($0)" } ?? "")
                )
                .accessibilityIdentifier("correctionDetails")
            } else {
                Text("Choose your headphones from OPRA's measured presets, or import an AutoEq ParametricEQ file.")
                    .font(.subheadline)
                    .foregroundStyle(theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(credit.isChosen ? "Choose…" : "Choose headphones…", systemImage: "headphones", action: choose)
                .buttonStyle(.glass)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.ink)
                .accessibilityIdentifier("chooseCorrectionButton")
        }
        .padding(.vertical, 4)
        .onAppear {
            if case .opra = correction.source { catalog.load() }
        }
    }
}

// MARK: The picker

/// Picks a headphone correction: every bundled OPRA preset, searchable by vendor and product, each credited "EQ by
/// <author> · OPRA" with a preview of its curve; or an AutoEq `ParametricEQ.txt` of the user's own, imported through the
/// Files picker. OPRA's logo and a link to its repository head the list, as its terms ask of a browser of its data.
struct CorrectionPicker: View {
    let store: SoundStore
    let theme: Theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var importing = false
    @State private var failure: ImportFailure?

    private var catalog: OPRACatalog { .shared }

    private var selectedID: String? {
        if case .opra(let id) = store.settings.correction.source { return id }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        opraHeader
                    }
                    .listRowBackground(SoundGlass(theme: theme))
                    Section {
                        importButton
                    } footer: {
                        Text("A ParametricEQ.txt from AutoEq or Equalizer APO: up to 20 filters and a preamp.")
                            .foregroundStyle(theme.inkSecondary)
                    }
                    .listRowBackground(SoundGlass(theme: theme))
                }
                presets
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .listSectionIndexVisibility(query.isEmpty ? .visible : .hidden)
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Vendor or model"
            )
            .navigationTitle("Headphones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("correctionPickerCancel")
                }
            }
            .overlay {
                switch catalog.state {
                case .loading, .idle:
                    ProgressView().controlSize(.large)
                case .failed:
                    ContentUnavailableView(
                        "Presets unavailable", systemImage: "exclamationmark.triangle",
                        description: Text("The OPRA presets could not be read. You can still import a file."))
                case .loaded:
                    if !query.isEmpty, catalog.search(query).isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .foregroundStyle(theme.ink)
        .tint(theme.processingTint)
        .onAppear {
            catalog.load()
            #if DEBUG
                // `-PFSoundImportFile <path>`: imports that file as if picked, for screenshots of the result or error.
                if let path = UserDefaults.standard.string(forKey: "PFSoundImportFile") {
                    imported(.success(URL(fileURLWithPath: path)))
                }
            #endif
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText]) { result in
            imported(result)
        }
        .alert(
            failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    private var opraHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let logo = UIImage(named: "opra_logo") {
                Image(uiImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 30)
                    .foregroundStyle(theme.ink)
                    .accessibilityLabel("OPRA")
            }
            Text(
                "OPRA is an open database of headphone EQ presets, each made by the person who measured the "
                    + "headphones. Pick yours to correct them toward a neutral target."
            )
            .font(.subheadline)
            .foregroundStyle(theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: "https://github.com/opra-project/OPRA") {
                Link(destination: url) {
                    Label("github.com/opra-project/OPRA", systemImage: "arrow.up.right.square")
                        .font(.footnote.monospaced())
                }
                .accessibilityIdentifier("opraLink")
            }
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("opraHeader")
    }

    private var importButton: some View {
        Button {
            importing = true
        } label: {
            Label("Import AutoEq file…", systemImage: "doc.badge.plus")
                .foregroundStyle(theme.ink)
        }
        .accessibilityIdentifier("importAutoEqButton")
    }

    @ViewBuilder
    private var presets: some View {
        let vendors = catalog.search(query)
        // One index letter per initial, on the first vendor that has it.
        let letters = Self.indexLetters(vendors.map(\.name))
        ForEach(vendors) { vendor in
            Section {
                ForEach(vendor.entries) { entry in
                    PresetRow(entry: entry, selected: entry.id == selectedID, theme: theme) {
                        store.applyCorrection(entry.preset.correction)
                        dismiss()
                    }
                }
            } header: {
                Text(vendor.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.inkSecondary)
            }
            .sectionIndexLabel(letters[vendor.name])
            .listRowBackground(SoundGlass(theme: theme))
        }
    }

    private static func indexLetters(_ names: [String]) -> [String: String] {
        var seen: Set<String> = []
        var letters: [String: String] = [:]
        for name in names {
            guard let first = name.first else { continue }
            let letter = first.isLetter ? String(first).uppercased() : "#"
            if seen.insert(letter).inserted { letters[name] = letter }
        }
        return letters
    }

    // MARK: Import

    private func imported(_ result: Result<URL, any Error>) {
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            failure = ImportFailure(
                fileName: nil, message: "The file couldn't be opened: \(error.localizedDescription)")
        case .success(let url):
            switch AutoEqImport.correction(from: url) {
            case .success(let correction):
                store.applyCorrection(correction)
                dismiss()
            case .failure(let error):
                failure = error
            }
        }
    }
}

/// One OPRA preset: the product, then the author's credit, more prominent than OPRA's mark, then what sets it apart,
/// with a preview of its curve.
private struct PresetRow: View {
    let entry: OPRACatalog.Entry
    let selected: Bool
    let theme: Theme
    let pick: () -> Void

    private var preset: OPRAPreset { entry.preset }

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.product)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.ink)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("EQ by \(preset.author)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(theme.ink)
                        Text("· OPRA")
                            .font(.caption2)
                            .foregroundStyle(theme.inkSecondary)
                    }
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(theme.inkSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    CurvePreview(points: entry.preview, theme: theme)
                        .frame(width: 64, height: 26)
                    Text(SoundFormat.gain(preset.preampDb))
                        .font(Typeface.cellLabel.monospacedDigit())
                        .foregroundStyle(theme.inkSecondary)
                }
                .accessibilityHidden(true)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.processingTint)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.displayName), EQ by \(preset.author), OPRA")
        .accessibilityValue(spokenDetail)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("opraPreset-\(preset.id)")
    }

    /// "Harman Target · 10 bands" (the preamp sits under the curve).
    private var detail: String {
        var parts: [String] = []
        if !preset.details.isEmpty { parts.append(preset.details) }
        parts.append("\(preset.bands.count) bands")
        return parts.joined(separator: " · ")
    }

    private var spokenDetail: String {
        var parts: [String] = []
        if !preset.details.isEmpty { parts.append(preset.details) }
        parts.append("\(preset.bands.count) bands")
        parts.append("preamp \(SoundFormat.gainSpoken(preset.preampDb))")
        return parts.joined(separator: ", ")
    }
}

/// A preset's curve in miniature: ±12 dB on a log axis, with the 0 dB line.
private struct CurvePreview: View {
    let points: [Double]
    let theme: Theme

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            context.fill(
                Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(theme.hairline))
            guard points.count > 1 else { return }
            var line = Path()
            for (i, db) in points.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(points.count - 1)
                let y = mid - CGFloat(min(max(db, -12), 12) / 12) * (mid - 1.5)
                if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(
                line, with: .color(theme.processingTint), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }
}

// MARK: AutoEq import

/// Why an imported file was refused, for the alert.
struct ImportFailure: Error, Identifiable, Equatable {
    let fileName: String?
    let message: String
    var id: String { (fileName ?? "") + message }
    var title: String { fileName.map { "Can't import “\($0)”" } ?? "Can't import the file" }
}

/// Reads a `ParametricEQ.txt` the user picked (AutoEq's, or any in Equalizer APO's layout) into a correction.
enum AutoEqImport {
    /// Larger than any real ParametricEQ file by far.
    static let maxBytes = 256 * 1024

    static func correction(from url: URL) -> Result<CorrectionSettings, ImportFailure> {
        let fileName = url.lastPathComponent
        func fail(_ message: String) -> Result<CorrectionSettings, ImportFailure> {
            .failure(ImportFailure(fileName: fileName, message: message))
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return fail("It couldn't be read: \(error.localizedDescription)")
        }
        guard data.count <= maxBytes else { return fail("It is too large to be a ParametricEQ file.") }
        guard let text = text(from: data) else { return fail("It isn't a text file pointFlac can read.") }
        do {
            let parsed = try AutoEqParser.parse(text)
            guard !parsed.bands.isEmpty else { return fail("It has no filters switched on.") }
            return .success(
                CorrectionSettings(
                    enabled: true, name: name(from: url), author: "", source: .autoEq(fileName: fileName),
                    preampDb: parsed.preampDb, bands: parsed.bands))
        } catch AutoEqParser.ParseError.unsupportedLine(let number) {
            let line = lines(text).dropFirst(number - 1).first.map { String($0.prefix(80)) } ?? ""
            return fail(
                "Line \(number) isn't a preamp or filter line pointFlac can read"
                    + (line.isEmpty ? "." : ":\n\(line.trimmingCharacters(in: .whitespaces))"))
        } catch AutoEqParser.ParseError.tooManyBands {
            return fail(
                "It switches on more than \(AutoEqParser.maxBands) filters, the most pointFlac's correction runs.")
        } catch {
            return fail("It couldn't be read.")
        }
    }

    /// UTF-16 with its byte-order mark, as some Windows editors save; else UTF-8, whose mark the parser skips.
    static func text(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    /// The lines as the parser numbers them (a leading byte-order mark is not a line of its own).
    private static func lines(_ text: String) -> [Substring] {
        let body = text.first == "\u{FEFF}" ? text.dropFirst() : Substring(text)
        return body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// "Sennheiser HD 600 ParametricEQ.txt" → "Sennheiser HD 600".
    static func name(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" ParametricEQ", " Parametric EQ", "_ParametricEQ", "-ParametricEQ"]
        where name.lowercased().hasSuffix(suffix.lowercased()) {
            name.removeLast(suffix.count)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Imported correction" : name
    }
}
