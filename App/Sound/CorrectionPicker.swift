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

    /// An OPRA correction's target or variant ("Harman Target"), once the file is read; nil for none, or a file.
    func details(of correction: CorrectionSettings) -> String? {
        guard case .opra(let id) = correction.source, let details = entry(id: id)?.preset.details, !details.isEmpty
        else { return nil }
        return details
    }

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

    /// The block header's line, short, since the row below names the headphones, credits the author and gives the
    /// bands and preamp: the OPRA preset's target ("Harman Target") once the catalog is read, else what it is.
    func summary(details: String?) -> String {
        guard isChosen else { return "No headphones chosen" }
        if case .autoEq = correction.source { return "Imported file" }
        return details ?? "OPRA preset"
    }
}

/// The OPRA project, which its terms ask every credit to link to.
enum OPRAProject {
    static let repository = URL(string: "https://github.com/opra-project/OPRA")!
    static let repositoryLabel = "github.com/opra-project/OPRA"
}

// MARK: The correction row

/// The headphone correction in force: the headphones, the credit, its preamp and size, and Choose… for the picker.
struct CorrectionRows: View {
    let correction: CorrectionSettings
    let theme: Theme
    let choose: () -> Void
    @Environment(\.openURL) private var openURL

    private var catalog: OPRACatalog { .shared }

    private var credit: CorrectionCredit { CorrectionCredit(correction) }

    /// The OPRA preset's details ("Harman Target"), once the catalog is read.
    private var details: String? { catalog.details(of: correction) }

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
                        // OPRA's terms: a link to the project with the credit, smaller than the author's.
                        if let mark = credit.sourceMark {
                            Text("·").font(.caption).foregroundStyle(theme.inkSecondary)
                            Link(destination: OPRAProject.repository) {
                                Text(mark).underline().font(.caption).foregroundStyle(theme.inkSecondary)
                            }
                            // Its own tap target, not the whole row's.
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("opraCreditLink")
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(credit.spoken)
                .modifier(OPRALinkAction(shown: credit.sourceMark != nil, open: { openURL(OPRAProject.repository) }))
                .accessibilityIdentifier("correctionPreset")
                Readout(
                    cells: [
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

/// VoiceOver's way to the OPRA link of a credit it reads as one element: a named action.
private struct OPRALinkAction: ViewModifier {
    let shown: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if shown {
            content.accessibilityAction(named: "Open OPRA on GitHub", open)
        } else {
            content
        }
    }
}

// MARK: The picker

/// Picks a headphone correction: every bundled OPRA preset, searchable by vendor and product, each credited "EQ by
/// <author> · OPRA" with a preview of its curve; or an AutoEq `ParametricEQ.txt` of the user's own, imported through the
/// Files picker. OPRA's logo and a link to its repository head the list, as its terms ask of a browser of its data;
/// while searching, a compact row of the two stays above the results.
struct CorrectionPicker: View {
    let store: SoundStore
    let theme: Theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The presets `query` finds, worked out once per query (and once the catalog is read).
    @State private var results: [OPRACatalog.Vendor] = []
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
                } else {
                    Section {
                        compactOPRAHeader
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
                    if !query.isEmpty, results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .foregroundStyle(theme.ink)
        .tint(theme.processingTint)
        .onChange(of: query, initial: true) { results = catalog.search(query) }
        .onChange(of: catalog.state) { results = catalog.search(query) }
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

    private func logo(height: CGFloat) -> some View {
        Group {
            if let logo = UIImage(named: "opra_logo") {
                Image(uiImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(height: height)
                    .foregroundStyle(theme.ink)
                    .accessibilityLabel("OPRA")
            }
        }
    }

    /// The repository link, in the tint so it reads as one, and its own tap target rather than its row's.
    private var repositoryLink: some View {
        Link(destination: OPRAProject.repository) {
            Label(OPRAProject.repositoryLabel, systemImage: "arrow.up.right.square")
                .font(.footnote.monospaced())
                .foregroundStyle(theme.processingTint)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("opraLink")
    }

    /// The logo and the link, above search results.
    private var compactOPRAHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                logo(height: 16)
                Spacer(minLength: 12)
                repositoryLink
            }
            VStack(alignment: .leading, spacing: 6) {
                logo(height: 16)
                repositoryLink
            }
        }
        .accessibilityIdentifier("opraHeader")
    }

    private var opraHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            logo(height: 30)
            Text(
                "OPRA is an open database of headphone EQ presets, each made by the person who measured the "
                    + "headphones. Pick yours to correct them toward a neutral target."
            )
            .font(.subheadline)
            .foregroundStyle(theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            repositoryLink
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
        let vendors = results
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
            // Its size checked, then read and parsed, off the main actor: a file picked by mistake can be large, or
            // on a slow provider.
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    AutoEqImport.correction(contentsOf: url)
                }.value
                switch result {
                case .success(let correction):
                    store.applyCorrection(correction)
                    dismiss()
                case .failure(let reason):
                    failure = ImportFailure(fileName: url.lastPathComponent, message: reason.message)
                }
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
struct ImportFailure: Identifiable, Equatable {
    let fileName: String?
    let message: String
    var id: String { (fileName ?? "") + message }
    var title: String { fileName.map { "Can't import “\($0)”" } ?? "Can't import the file" }
}

extension AutoEqImport.Failure {
    /// The alert's explanation, naming the line the parser could not read.
    var message: String {
        switch self {
        case .unreadable(let reason): "It couldn't be read: \(reason)"
        case .tooLarge: "It is too large to be a ParametricEQ file."
        case .notText: "It isn't a text file pointFlac can read."
        case .unsupportedLine(let number, let text):
            "Line \(number) isn't a preamp or filter line pointFlac can read" + (text.isEmpty ? "." : ":\n\(text)")
        case .tooManyBands:
            "It switches on more than \(AutoEqParser.maxBands) filters, the most pointFlac's correction runs."
        case .noFilters: "It has no filters switched on."
        }
    }
}
