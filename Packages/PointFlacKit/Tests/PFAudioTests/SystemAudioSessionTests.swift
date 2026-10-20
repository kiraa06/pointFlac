#if os(iOS)
    import AVFoundation
    import PFCore
    import Testing

    @testable import PFAudio

    @Suite struct SystemAudioSessionTests {
        @Test func requestedRateIsReadBack() async throws {
            let session = SystemAudioSession()
            try await session.activate()
            for requested in [44_100, 48_000, 96_000] {
                let actual = await session.requestSampleRate(requested)
                #expect(actual > 0)
                #expect(actual == Int(AVAudioSession.sharedInstance().sampleRate))
                print("S3: requested=\(requested) actual=\(actual) port=\(session.currentPort)")
            }
        }
    }
#endif
