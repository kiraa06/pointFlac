import Testing

@testable import PFCore

private func fmt(_ rate: Int, _ bits: Int) -> AudioFormat {
    AudioFormat(sampleRate: rate, bitsPerSample: bits, channels: 2)
}

@Test func plans() {
    let cap = OutputCapabilities(int32Passthrough: true)
    let no32 = OutputCapabilities(int32Passthrough: false)
    #expect(
        OutputFormatPolicy.plan(source: fmt(44_100, 16), hardwareRate: 44_100, capabilities: cap)
            == OutputPlan(client: .float32, clientSampleRate: 44_100, resample: nil, reduceTo24: false))
    #expect(
        OutputFormatPolicy.plan(source: fmt(96_000, 24), hardwareRate: 48_000, capabilities: cap)
            == OutputPlan(
                client: .float32, clientSampleRate: 48_000, resample: .init(from: 96_000, to: 48_000),
                reduceTo24: false))
    #expect(OutputFormatPolicy.plan(source: fmt(96_000, 32), hardwareRate: 96_000, capabilities: cap).client == .int32)
    #expect(
        OutputFormatPolicy.plan(source: fmt(96_000, 32), hardwareRate: 96_000, capabilities: no32)
            == OutputPlan(client: .float32, clientSampleRate: 96_000, resample: nil, reduceTo24: true))
    #expect(
        OutputFormatPolicy.plan(source: fmt(192_000, 32), hardwareRate: 48_000, capabilities: cap)
            == OutputPlan(
                client: .float32, clientSampleRate: 48_000, resample: .init(from: 192_000, to: 48_000),
                reduceTo24: true))
}

@Test(arguments: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 384_000])
func clientRateAlwaysEqualsHardware(_ hw: Int) {
    for bits in [16, 24, 32] {
        for source in [44_100, 96_000, 192_000] {
            for int32 in [true, false] {
                let plan = OutputFormatPolicy.plan(
                    source: fmt(source, bits), hardwareRate: hw,
                    capabilities: OutputCapabilities(int32Passthrough: int32))
                #expect(plan.clientSampleRate == hw)
            }
        }
    }
}

@Test func currentCapabilitiesAreConservative() {
    #expect(OutputCapabilities.current.int32Passthrough == false)
}
