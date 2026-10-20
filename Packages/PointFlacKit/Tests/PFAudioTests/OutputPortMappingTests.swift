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
