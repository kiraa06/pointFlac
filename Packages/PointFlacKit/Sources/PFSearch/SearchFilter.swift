/// The search chips (spec §4.6): All · Albums · Songs · 24-bit+ · 32-bit · ≥96 kHz.
public enum SearchFilter: String, Sendable, CaseIterable, Hashable {
    case all
    case albums
    case songs
    /// 24 bits or more.
    case hiRes24
    /// Exactly 32 bits.
    case bit32
    /// 96 kHz or more.
    case rate96
}
