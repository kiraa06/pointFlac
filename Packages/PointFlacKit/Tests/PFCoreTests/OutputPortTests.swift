import Testing

@testable import PFCore

/// The key each output's Sound settings are kept under (Task 15), and back.
@Suite("Output port profile keys")
struct OutputPortTests {
    @Test(
        "each kind of port has its key: the kind, then the device's name",
        arguments: [
            (OutputPort.usb("Test DAC"), "usb:Test DAC"),
            (.wired("Headphones"), "wired:Headphones"),
            (.bluetooth("AirPods Pro"), "bluetooth:AirPods Pro"),
            (.builtIn, "builtIn"),
            (.airPlay("Living Room"), "airPlay:Living Room"),
            (.other("HDMI"), "other:HDMI"),
        ])
    func keyForEachPort(_ port: OutputPort, _ key: String) {
        #expect(port.profileKey == key)
        #expect(OutputPort(profileKey: key) == port)
    }

    @Test("a name with a colon, or none, survives the round trip; two devices of one kind keep apart")
    func awkwardNames() {
        for port in [OutputPort.usb("Chord: Mojo 2"), .bluetooth(""), .other("a:b:c")] {
            #expect(OutputPort(profileKey: port.profileKey) == port, "\(port)")
        }
        #expect(OutputPort.usb("DAC A").profileKey != OutputPort.usb("DAC B").profileKey)
        #expect(OutputPort.usb("DAC").profileKey != OutputPort.wired("DAC").profileKey)
    }

    @Test("a key no port makes names none")
    func unknownKeys() {
        for key in ["", "builtIn:Speaker", "usb", "speaker:x", "USB:Test DAC"] {
            #expect(OutputPort(profileKey: key) == nil, "\(key)")
        }
    }
}
