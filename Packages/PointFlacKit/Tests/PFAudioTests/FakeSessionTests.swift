import PFCore
import PFTestSupport
import Testing

@testable import PFAudio

@Suite struct FakeSessionTests {
    @Test func deliversEmittedEventsInOrder() async {
        let session = FakeSession()
        session.emit(.interruptionBegan)
        session.emit(.volumeChanged(0.5))
        session.emit(.routeChanged(.newDeviceAvailable, .usb("DAC")))
        var got: [SessionEvent] = []
        for await e in session.events {
            got.append(e)
            if got.count == 3 { break }
        }
        #expect(got == [.interruptionBegan, .volumeChanged(0.5), .routeChanged(.newDeviceAvailable, .usb("DAC"))])
    }

    @Test func recordsRequestsAndAppliesTheScriptedResponse() async throws {
        let session = FakeSession(rateResponse: { $0 > 48_000 ? 48_000 : $0 })
        try await session.activate()
        try await session.activate()
        let a = await session.requestSampleRate(96_000)
        let b = await session.requestSampleRate(44_100)
        #expect(a == 48_000)
        #expect(b == 44_100)
        #expect(session.requestedRates == [96_000, 44_100])
        #expect(session.activationCount == 2)
        // The hardware settles on the last response, until a test moves it.
        #expect(session.sampleRate == 44_100)
        session.sampleRate = 48_000
        #expect(session.sampleRate == 48_000)
        session.currentPort = .bluetooth("Buds")
        session.outputVolume = 0.25
        #expect(session.currentPort == .bluetooth("Buds"))
        #expect(session.outputVolume == 0.25)
    }

    /// An activation with a preferred rate comes up at whatever the scripted hardware makes of it, as a real session
    /// does when the rate is set before `setActive(true)`; one without leaves the rate alone.
    @Test func activationAppliesThePreferredRate() async throws {
        let session = FakeSession(rateResponse: { $0 > 48_000 ? 48_000 : $0 })
        try await session.activate(preferredRate: 96_000)
        #expect(session.sampleRate == 48_000)
        try await session.activate(preferredRate: 44_100)
        #expect(session.sampleRate == 44_100)
        try await session.activate()
        #expect(session.sampleRate == 44_100)
        #expect(session.activationRates == [96_000, 44_100, nil])
        #expect(session.activationCount == 3)
        #expect(session.requestedRates.isEmpty)
    }
}
