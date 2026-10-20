import Testing

@testable import PFCore

@Test func formatsRatesAndDepths() {
    #expect(AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2).formattedRate == "44.1 kHz")
    #expect(AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2).formattedRate == "96 kHz")
    #expect(AudioFormat(sampleRate: 352_800, bitsPerSample: 32, channels: 2).formattedRate == "352.8 kHz")
    #expect(AudioFormat(sampleRate: 48_000, bitsPerSample: 32, channels: 2).formattedDepth == "32-bit")
}

/// Ledger T1/T7: up to three decimals, trailing zeros trimmed, so no rate is rounded into another one.
@Test(arguments: [
    (22_050, "22.05 kHz"), (11_025, "11.025 kHz"), (352_800, "352.8 kHz"), (44_100, "44.1 kHz"),
    (88_200, "88.2 kHz"), (176_400, "176.4 kHz"), (8_000, "8 kHz"), (384_000, "384 kHz"), (1, "0.001 kHz"),
    (32_000, "32 kHz"), (7_350, "7.35 kHz"),
])
func formatsOddRatesExactly(_ rate: Int, _ expected: String) {
    #expect(AudioFormat(sampleRate: rate, bitsPerSample: 16, channels: 2).formattedRate == expected)
}

/// v1 plays mono and stereo only (spec §5.3).
@Test func channelPolicyAllowsMonoAndStereoOnly() {
    for channels in [1, 2] {
        #expect(ChannelPolicy.isPlayable(AudioFormat(sampleRate: 48_000, bitsPerSample: 16, channels: channels)))
    }
    for channels in [0, 3, 4, 6, 8] {
        #expect(!ChannelPolicy.isPlayable(AudioFormat(sampleRate: 48_000, bitsPerSample: 16, channels: channels)))
    }
    #expect(ChannelPolicy.unsupportedMessage == "Multichannel FLAC isn't supported yet")
}
