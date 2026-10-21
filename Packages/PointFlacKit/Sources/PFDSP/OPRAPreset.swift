import Foundation

/// One headphone-correction preset from the OPRA database, as `scripts/build-opra.swift` writes it into the app's
/// `opra.json`: a product, the person who measured and tuned it, and their parametric EQ.
///
/// OPRA's data is CC BY-SA 4.0, and its terms ask that every preset credit its author, more prominently than OPRA
/// itself ("EQ by <author> · OPRA"), so the author travels with the correction.
///
/// Values are as published, never clamped here: 24 presets have a band below the chain's 20 Hz floor. The Sound store
/// runs `SoundSettings.clamped()` on everything it is given, which lifts those to 20 Hz.
public struct OPRAPreset: Decodable, Identifiable, Hashable, Sendable {
    public struct Band: Decodable, Hashable, Sendable {
        /// A `FilterType` raw value: a type the chain cannot run fails the whole load rather than being guessed.
        public var type: FilterType
        public var fc: Double
        public var gain: Double
        public var q: Double
    }

    /// OPRA's own id, "vendor:product::author_target", which `CorrectionSource.opra` keeps.
    public var id: String
    public var vendor: String
    public var product: String
    public var author: String
    /// What sets this preset apart from the author's others for the same product: the target ("Harman Target"),
    /// earpads, a mode. Empty when OPRA gives none.
    public var details: String
    public var preampDb: Double
    public var bands: [Band]

    private enum CodingKeys: String, CodingKey { case id, vendor, product, author, details, preampDb, bands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vendor = try c.decode(String.self, forKey: .vendor)
        product = try c.decode(String.self, forKey: .product)
        author = try c.decode(String.self, forKey: .author)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        preampDb = try c.decode(Double.self, forKey: .preampDb)
        bands = try c.decode([Band].self, forKey: .bands)
    }

    /// The whole file: an array of presets.
    public static func catalog(from data: Data) throws -> [OPRAPreset] {
        try JSONDecoder().decode([OPRAPreset].self, from: data)
    }

    /// "Sennheiser HD 600": the vendor and the product, once, for a product whose name does not already carry it.
    public var displayName: String {
        product.lowercased().hasPrefix(vendor.lowercased()) ? product : "\(vendor) \(product)"
    }

    /// The bands as the chain's, all switched on.
    public var eqBands: [EQBand] {
        bands.map { EQBand(type: $0.type, frequency: $0.fc, gainDb: $0.gain, q: $0.q) }
    }

    /// The preset as the chain's headphone correction, switched on, with its name and author for the credit.
    public var correction: CorrectionSettings {
        CorrectionSettings(
            enabled: true, name: displayName, author: author, source: .opra(id: id), preampDb: preampDb,
            bands: eqBands)
    }
}
