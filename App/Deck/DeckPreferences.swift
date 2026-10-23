import PFDesign

/// Where Customize deck keeps its choices (`@AppStorage` keys), and the values they hold. Read them with
/// `@AppStorage(DeckPreferences.designKey) var designID = DeckDesign.standard.id` and
/// `@AppStorage(DeckPreferences.recordStyleKey) var recordStyle = RecordStyle.standard.rawValue`, then resolve with
/// `DeckDesign.design(id:)` and `RecordStyle(rawValue:) ?? .standard`. UI tests can set both with launch arguments,
/// e.g. `-deckDesign walnut -recordStyle picture`.
enum DeckPreferences {
    static let designKey = "deckDesign"
    static let recordStyleKey = "recordStyle"
}
