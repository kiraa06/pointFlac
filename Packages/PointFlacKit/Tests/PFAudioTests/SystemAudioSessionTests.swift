#if os(iOS)
    import AVFoundation
    import PFCore
    import Testing

    @testable import PFAudio

    /// Serialized: several tests set the one process-wide session's rate and activity.
    @Suite(.serialized, .audioOutputAvailable, .audioHardware) struct SystemAudioSessionTests {
        @Test func requestedRateIsReadBack() async throws {
            let session = SystemAudioSession()
            try await session.activate()
            for requested in [44_100, 48_000, 96_000] {
                let actual = await session.requestSampleRate(requested)
                #expect(actual > 0)
                #expect(actual == Int(AVAudioSession.sharedInstance().sampleRate))
                #expect(session.sampleRate == actual)
                #if targetEnvironment(simulator)
                    // The simulator honours every rate (the S3 finding), but only in what AVAudioSession reports:
                    // the unit's hardware side stays at the Mac device's rate and the simulator resamples after
                    // the unit (see S1). Not expected on a device.
                    #expect(actual == requested)
                #endif
                print("S3: requested=\(requested) actual=\(actual) port=\(session.currentPort)")
            }
        }

        /// Final review I6: asking an active session for the rate it already runs at only reads it back; no
        /// deactivate and reactivate. Another rate still goes through the full cycle.
        @Test func requestingTheRunningRateLeavesTheSessionAlone() async throws {
            let session = SystemAudioSession()
            try await session.activate()
            let running = session.sampleRate
            #expect(running > 0 && session.isActive)
            let before = session.deactivations
            #expect(await session.requestSampleRate(running) == running)
            #expect(session.deactivations == before, "the session was cycled for the rate it already had")
            let other = running == 44_100 ? 48_000 : 44_100
            _ = await session.requestSampleRate(other)
            #expect(session.deactivations == before + 1)
            #expect(session.isActive)
        }

        /// The preferred rate is set before the first activation, so a first play can come up at the file's rate.
        @Test func activationSetsThePreferredRateFirst() async throws {
            try AVAudioSession.sharedInstance().setActive(false)
            let session = SystemAudioSession()
            for preferred in [44_100, 96_000] {
                try AVAudioSession.sharedInstance().setActive(false)
                try await session.activate(preferredRate: preferred)
                #expect(session.isActive)
                #expect(session.sampleRate > 0)
                #if targetEnvironment(simulator)
                    // The simulator honours every rate (S3); a device may pick another one.
                    #expect(session.sampleRate == preferred)
                #endif
                let before = session.deactivations
                #expect(await session.requestSampleRate(session.sampleRate) == session.sampleRate)
                #expect(session.deactivations == before)
                print("S3: activated with preferred=\(preferred) actual=\(session.sampleRate)")
            }
        }

        /// The raw strings `OutputPort(portType:name:)` switches on must be Apple's real port-type values.
        @Test func portTypeStringsMatchAVAudioSession() {
            let ports: [(AVAudioSession.Port, OutputPort)] = [
                (.usbAudio, .usb("n")), (.headphones, .wired("n")), (.lineOut, .wired("n")),
                (.bluetoothA2DP, .bluetooth("n")), (.bluetoothLE, .bluetooth("n")),
                (.bluetoothHFP, .bluetooth("n")), (.builtInSpeaker, .builtIn),
                (.builtInReceiver, .builtIn), (.airPlay, .airPlay("n")),
            ]
            for (port, expected) in ports {
                #expect(OutputPort(portType: port.rawValue, name: "n") == expected, "\(port.rawValue)")
            }
        }

        /// The raw values the pure event mappers assume must match AVFoundation's enums.
        @Test func eventRawValuesMatchAVAudioSession() {
            #expect(
                RouteChangeReason(routeChangeRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
                    == .newDeviceAvailable)
            #expect(
                RouteChangeReason(routeChangeRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
                    == .oldDeviceUnavailable)
            #expect(
                SessionEvent.interruption(
                    typeRawValue: AVAudioSession.InterruptionType.began.rawValue, optionsRawValue: nil)
                    == .interruptionBegan)
            #expect(
                SessionEvent.interruption(
                    typeRawValue: AVAudioSession.InterruptionType.ended.rawValue,
                    optionsRawValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
                    == .interruptionEnded(shouldResume: true))
        }
    }
#endif
