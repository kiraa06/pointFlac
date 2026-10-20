import Foundation

public enum FlacIntegrityResult: Sendable, Equatable {
    /// Every frame decoded cleanly and the audio matches the STREAMINFO MD5 signature.
    case intact
    /// A frame failed to decode, or the audio does not match the signature.
    case damaged
    /// The encoder left the signature all zero, so there is nothing to verify against.
    case noSignature
}

public enum FlacIntegrity {
    /// Fully decodes the file and checks the audio against the MD5 signature in its STREAMINFO.
    /// A file without a signature is reported as `.noSignature` without decoding any audio.
    public static func verify(fileAt url: URL) throws(FlacDecodeError) -> FlacIntegrityResult {
        let decoder = try FlacDecoder(url: url, verifyingMD5: true)
        guard decoder.streamInfo.hasMD5 else { return .noSignature }
        try decoder.decodeRemainder()
        let signatureMatches = decoder.finish()
        return signatureMatches && decoder.decodeErrorCount == 0 ? .intact : .damaged
    }
}
