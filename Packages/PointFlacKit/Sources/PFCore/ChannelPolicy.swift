/// Which channel layouts v1 plays (spec §5.3): mono and stereo.
///
/// A multichannel file passes the admission rule, so the library imports and lists it, marked "not supported in v1",
/// but it is never played. pointFlac has no downmix of its own, and handing a 5.1 stream to a stereo route would leave
/// the downmix to iOS: the audio would be altered behind a strip that could not say how. Failing closed keeps the
/// strip honest until a real multichannel path exists.
public enum ChannelPolicy {
    /// The most channels v1 plays.
    public static let maximumChannels = 2

    /// Why an item with too many channels does not play, for the player's failure and the debug UI.
    public static let unsupportedMessage = "Multichannel FLAC isn't supported yet"

    public static func isPlayable(_ format: AudioFormat) -> Bool {
        format.channels >= 1 && format.channels <= maximumChannels
    }
}
