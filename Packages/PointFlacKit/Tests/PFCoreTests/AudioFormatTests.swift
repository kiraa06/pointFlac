import Testing

@testable import PFCore

@Test func formatsRatesAndDepths() {
    #expect(AudioFormat(sampleRate: 44_100, bitsPerSample: 16, channels: 2).formattedRate == "44.1 kHz")
    #expect(AudioFormat(sampleRate: 96_000, bitsPerSample: 24, channels: 2).formattedRate == "96 kHz")
    #expect(AudioFormat(sampleRate: 352_800, bitsPerSample: 32, channels: 2).formattedRate == "352.8 kHz")
    #expect(AudioFormat(sampleRate: 48_000, bitsPerSample: 32, channels: 2).formattedDepth == "32-bit")
}
