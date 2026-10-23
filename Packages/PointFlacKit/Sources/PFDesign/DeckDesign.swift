import Foundation

/// One of the turntables the deck can be drawn as (Customize deck). A design is data only: what the plinth, platter,
/// mat, tonearm, controls and display are made of, and their colours. The app draws every design from code, so no
/// third-party artwork ships, and every design is an original take on a style, never a copy of a real product. Names
/// carry no brand words.
///
/// Colours are 0xRRGGBB. The app turns them into its own colour type, and maps them to greys in Monochrome.
public struct DeckDesign: Sendable, Hashable, Identifiable {
    public enum Plinth: String, Sendable, CaseIterable {
        /// Frosted glass that follows the app's light or dark look (the original deck).
        case frostedGlass
        case brushedMetal
        case matteBlack
        case walnut
        /// Gloss lacquer with ash wood cheeks and a clear lid.
        case lacquer
        case smokedAcrylic
        case leatherette
    }

    public enum Platter: String, Sendable, CaseIterable {
        case aluminium
        case black
        case cream
        case smoke
        /// A thick, mass-loaded black platter, a little smaller than the others.
        case massBlack
    }

    public enum Mat: String, Sendable, CaseIterable {
        case none
        case rubber
        case rubberLight
        case felt
        case feltRed
    }

    public enum ArmStyle: String, Sendable, CaseIterable {
        case sShaped
        case jShaped
        case straight
        /// A carriage on a rail that moves straight along a radius: no arc and no offset angle.
        case linear
    }

    public enum ArmFinish: String, Sendable, CaseIterable {
        case chrome
        case black
        case silver
        case brass
    }

    /// The fixed furniture around the platter: buttons, fader, lamps, knobs, pods. Decorative, except the start/stop
    /// button where a layout has one.
    public enum Controls: String, Sendable, CaseIterable {
        case glass
        case dj
        case minimal
        case bauhaus
        case acrylic
        case linear
        case portable
    }

    /// The dot-matrix display's colours: lit dots and the window behind them.
    public struct Display: Sendable, Hashable {
        public var ink: UInt32
        public var back: UInt32

        public init(ink: UInt32, back: UInt32) {
            self.ink = ink
            self.back = back
        }
    }

    public var id: String
    public var name: String
    /// A few words under the name, e.g. "direct-drive DJ".
    public var tagline: String
    /// One or two sentences for the picker.
    public var blurb: String
    public var plinth: Plinth
    public var plinthBase: UInt32
    public var plinthEdge: UInt32
    public var platter: Platter
    /// The strobe dots and the strobe lamp; nil for a platter without a strobe ring.
    public var strobe: UInt32?
    public var mat: Mat
    public var armStyle: ArmStyle
    public var armFinish: ArmFinish
    public var cartridge: UInt32
    /// The design's one accent: lamps, the lit button, the centre tick.
    public var accent: UInt32
    public var controls: Controls
    public var display: Display

    public init(
        id: String, name: String, tagline: String, blurb: String, plinth: Plinth, plinthBase: UInt32,
        plinthEdge: UInt32, platter: Platter, strobe: UInt32?, mat: Mat, armStyle: ArmStyle, armFinish: ArmFinish,
        cartridge: UInt32, accent: UInt32, controls: Controls, display: Display
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.blurb = blurb
        self.plinth = plinth
        self.plinthBase = plinthBase
        self.plinthEdge = plinthEdge
        self.platter = platter
        self.strobe = strobe
        self.mat = mat
        self.armStyle = armStyle
        self.armFinish = armFinish
        self.cartridge = cartridge
        self.accent = accent
        self.controls = controls
        self.display = display
    }
}

extension DeckDesign {
    /// The designs the app ships, in picker order. The first is the default.
    public static let catalogue: [DeckDesign] = [
        DeckDesign(
            id: "glasshouse", name: "Glasshouse", tagline: "the original, rebuilt",
            blurb: "Frosted glass, an edge-lit rim and the green dot-matrix display, redrawn with real proportions.",
            plinth: .frostedGlass, plinthBase: 0xD9DEE6, plinthEdge: 0xFFFFFF, platter: .smoke, strobe: 0x7DFFA6,
            mat: .none, armStyle: .sShaped, armFinish: .chrome, cartridge: 0x26292E, accent: 0x7DFFA6, controls: .glass,
            display: Display(ink: 0x7DFFA6, back: 0x0C1A10)),
        DeckDesign(
            id: "studioSilver", name: "Studio Silver", tagline: "direct-drive DJ",
            blurb:
                "Brushed silver over graphite, a four-row strobe, a pitch fader with a centre click and a target lamp.",
            plinth: .brushedMetal, plinthBase: 0xC3C6CB, plinthEdge: 0xE9EBEE, platter: .aluminium, strobe: 0xFF3B30,
            mat: .rubber, armStyle: .sShaped, armFinish: .chrome, cartridge: 0x1F1F22, accent: 0xFF3B30, controls: .dj,
            display: Display(ink: 0xFF453A, back: 0x1A0B0A)),
        DeckDesign(
            id: "nightShift", name: "Night Shift", tagline: "matte black DJ",
            blurb: "The DJ layout in matte black, with an amber strobe, slim glowing ticks and a dim cue lamp.",
            plinth: .matteBlack, plinthBase: 0x141518, plinthEdge: 0x2A2C31, platter: .black, strobe: 0xFFB84D,
            mat: .rubber, armStyle: .sShaped, armFinish: .black, cartridge: 0xFFB84D, accent: 0xFFB84D, controls: .dj,
            display: Display(ink: 0xFFB84D, back: 0x1A1206)),
        DeckDesign(
            id: "walnut", name: "Walnut", tagline: "wooden box, belt drive",
            blurb: "A walnut box with a felt mat, a brass spindle and a plain J-arm. Quiet and warm.",
            plinth: .walnut, plinthBase: 0x5B3A29, plinthEdge: 0x7A5038, platter: .aluminium, strobe: nil, mat: .felt,
            armStyle: .jShaped, armFinish: .silver, cartridge: 0xB8452F, accent: 0xC9A24B, controls: .minimal,
            display: Display(ink: 0xFFC46B, back: 0x1C120B)),
        DeckDesign(
            id: "bauhausWhite", name: "Bauhaus White", tagline: "radiogram",
            blurb:
                "Off-white lacquer with ash cheeks, a clear lid catching the light, a row of tiny knobs, one orange dot.",
            plinth: .lacquer, plinthBase: 0xF1EFE8, plinthEdge: 0xFFFFFF, platter: .cream, strobe: nil,
            mat: .rubberLight, armStyle: .straight, armFinish: .silver, cartridge: 0xE8590C, accent: 0xE8590C,
            controls: .bauhaus, display: Display(ink: 0x2B2A27, back: 0xD9D6CC)),
        DeckDesign(
            id: "midnightAcrylic", name: "Midnight Acrylic", tagline: "mass-loaded",
            blurb: "Smoked acrylic, a thick black platter, an outboard motor pod, champagne bolts and a heavy clamp.",
            plinth: .smokedAcrylic, plinthBase: 0x17171D, plinthEdge: 0x5A5A6A, platter: .massBlack, strobe: nil,
            mat: .none, armStyle: .straight, armFinish: .black, cartridge: 0xD9C9A3, accent: 0xD9C9A3,
            controls: .acrylic, display: Display(ink: 0xE8DCC0, back: 0x0B0B0F)),
        DeckDesign(
            id: "linear", name: "Linear", tagline: "linear-tracking slab",
            blurb: "A low aluminium slab. The carriage rides a rail straight toward the spindle: no arc, no offset.",
            plinth: .brushedMetal, plinthBase: 0xB8BCC2, plinthEdge: 0xDCDFE3, platter: .black, strobe: nil, mat: .none,
            armStyle: .linear, armFinish: .black, cartridge: 0x101113, accent: 0xD07A3B, controls: .linear,
            display: Display(ink: 0xFF9A4D, back: 0x150C06)),
        DeckDesign(
            id: "portable", name: "Portable", tagline: "suitcase",
            blurb: "Teal leatherette, a cream platter, brass latches and a grille. Built for the picnic.",
            plinth: .leatherette, plinthBase: 0x2F6F6A, plinthEdge: 0x3F8A84, platter: .cream, strobe: nil,
            mat: .feltRed, armStyle: .straight, armFinish: .brass, cartridge: 0xE8DFC8, accent: 0xC9A24B,
            controls: .portable, display: Display(ink: 0xE8DFC8, back: 0x16302E)),
    ]

    /// The default design.
    public static var standard: DeckDesign { catalogue[0] }

    /// The design with `id`, or the default when there is none (a design removed in a later version).
    public static func design(id: String) -> DeckDesign {
        catalogue.first { $0.id == id } ?? standard
    }
}

/// What the record on the deck looks like (Customize deck).
public enum RecordStyle: String, Sendable, CaseIterable {
    /// Black vinyl, with the album's art on the centre label only, as on a real LP. The default: black grooves show
    /// almost no motion at 33⅓, so the deck looks as calm as a real one.
    case black
    /// Translucent vinyl tinted from the album's colours, with the art on the label.
    case coloured
    /// The album's art across the whole record.
    case picture

    public static let standard = RecordStyle.black
}

/// A 12-inch LP's proportions, relative to the record's radius, for drawing the record, platter and arm true to life.
/// Real sizes: record 302 mm, platter 332 mm, label 100 mm, spindle hole 7.24 mm, outermost groove about 297.6 mm, the
/// innermost recorded groove about 120.6 mm.
public enum VinylGeometry {
    public static let platterToRecord = 332.0 / 302.0
    /// A mass-loaded platter sits a little smaller than the standard one.
    public static let massPlatterToRecord = 1.08
    public static let labelToRecord = 100.0 / 302.0
    public static let spindleHoleToRecord = 7.24 / 302.0
    /// Where the lead-in groove starts and the music ends; the dead wax lies between the innermost groove and the
    /// label.
    public static let outerGrooveToRecord = 297.6 / 302.0
    public static let innerGrooveToRecord = 120.6 / 302.0
    /// A pivoted arm's headshell is turned toward the spindle by about this much, so the stylus meets the groove
    /// square on.
    public static let offsetAngleDegrees = 22.0
    /// How far a pivoted arm's stylus would reach past the spindle (overhang), as a fraction of the record's radius:
    /// about 15 mm on a 151 mm radius.
    public static let overhangToRecord = 15.0 / 151.0
    /// Strobe rows on the platter rim: the dot count that stands still for a speed under a mains-frequency lamp.
    public static let strobeRows: [(rpm: Double, mainsHz: Int, dots: Int)] = [
        (100.0 / 3.0, 50, 180), (100.0 / 3.0, 60, 216), (45, 50, 133), (45, 60, 160),
    ]
}
