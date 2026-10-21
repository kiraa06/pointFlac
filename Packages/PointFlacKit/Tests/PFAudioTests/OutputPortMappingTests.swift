import PFCore
import Testing

@testable import PFAudio

@Suite struct OutputPortMappingTests {
    @Test(arguments: [
        ("USBAudio", OutputPort.usb("DAC")),
        ("Headphones", .wired("DAC")),
        ("LineOut", .wired("DAC")),
        ("BluetoothA2DPOutput", .bluetooth("DAC")),
        ("BluetoothLE", .bluetooth("DAC")),
        ("BluetoothHFP", .bluetooth("DAC")),
        ("Speaker", .builtIn),
        ("Receiver", .builtIn),
        ("AirPlay", .airPlay("DAC")),
        ("HDMI", .other("DAC")),
        ("", .other("DAC")),
    ])
    func mapsPortTypes(portType: String, expected: OutputPort) {
        #expect(OutputPort(portType: portType, name: "DAC") == expected)
    }
}

@Suite struct SessionEventMappingTests {
    @Test(arguments: [
        (UInt?.some(1), RouteChangeReason.newDeviceAvailable),
        (2, .oldDeviceUnavailable),
        (3, .other),
        (99, .other),
        (nil, .other),
    ])
    func mapsRouteChangeReasons(raw: UInt?, expected: RouteChangeReason) {
        #expect(RouteChangeReason(routeChangeRawValue: raw) == expected)
    }

    @Test func mapsInterruptions() {
        #expect(SessionEvent.interruption(typeRawValue: 1, optionsRawValue: nil) == .interruptionBegan)
        #expect(SessionEvent.interruption(typeRawValue: 1, optionsRawValue: 1) == .interruptionBegan)
        #expect(
            SessionEvent.interruption(typeRawValue: 0, optionsRawValue: 1) == .interruptionEnded(shouldResume: true))
        #expect(
            SessionEvent.interruption(typeRawValue: 0, optionsRawValue: 0) == .interruptionEnded(shouldResume: false))
        #expect(
            SessionEvent.interruption(typeRawValue: 0, optionsRawValue: nil) == .interruptionEnded(shouldResume: false))
        #expect(
            SessionEvent.interruption(typeRawValue: 0, optionsRawValue: 2) == .interruptionEnded(shouldResume: false))
        #expect(SessionEvent.interruption(typeRawValue: 7, optionsRawValue: 1) == nil)
        #expect(SessionEvent.interruption(typeRawValue: nil, optionsRawValue: nil) == nil)
    }
}
