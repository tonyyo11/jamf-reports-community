import CryptoKit
import Foundation
import Security

/// RFC 3161 time-stamp request and reply: the request the app sends (a SHA-256 and a nonce,
/// nothing else) and the reading of a reply (`.tsr`), whose token is CMS SignedData checked
/// with Security.framework's `CMSDecoder`.
enum TimestampToken {

    enum Failure: LocalizedError, Equatable {
        case malformed(String)
        case refused(status: Int)
        case signature(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what): "the reply is not an RFC 3161 time-stamp reply (\(what))"
            case .refused(let status): "the authority refused the request (status \(status))"
            case .signature(let what): "the token's signature does not verify (\(what))"
            }
        }
    }

    /// What a token says, and how far it can be trusted.
    struct Inspection: Sendable, Equatable {
        /// The hash the authority signed, lowercase hex.
        let imprint: String
        let nonce: [UInt8]?
        /// TSTInfo `genTime`: when the authority signed.
        let signedAt: Date
        /// The signer certificate's subject summary, as the token carries it: any text a
        /// self-signed certificate chose.
        let signer: String?
        /// SHA-256 of the signer certificate's DER, to compare with the authority's published
        /// fingerprint; unlike the subject, it cannot be chosen.
        let signerSHA256: String?
        /// The signature verifies against the certificate in the token.
        let signatureValid: Bool
        /// The signer's chain validates against this Mac's trust settings at `signedAt`.
        let chainTrusted: Bool
    }

    /// DER of id-sha256 with NULL parameters, as RFC 3161 clients send it.
    private static let sha256Algorithm: [UInt8] =
        [0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00]
    private static let sha256OID: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
    /// id-ct-TSTInfo, 1.2.840.113549.1.9.16.1.4.
    private static let tstInfoOID: [UInt8] =
        [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x10, 0x01, 0x04]

    /// A TimeStampReq for `sha256` (32 bytes): version 1, the imprint, `nonce` and certReq, so
    /// the reply carries the signer's certificate for `verify`.
    static func request(sha256: [UInt8], nonce: [UInt8]) -> Data {
        let imprint = DER.tlv(0x30, sha256Algorithm + DER.tlv(0x04, sha256))
        let body = DER.tlv(0x02, [0x01]) + imprint + DER.tlv(0x02, DER.positiveInteger(nonce))
            + DER.tlv(0x01, [0xff])
        return Data(DER.tlv(0x30, body))
    }

    /// Eight random bytes for a request's nonce.
    static func randomNonce() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return withUnsafeBytes(of: generator.next() as UInt64) { Array($0) }
    }

    /// The token of a TimeStampResp, refused unless its status is granted (0) or granted with
    /// modifications (1).
    static func token(fromReply reply: Data) throws -> Data {
        let response = try DER.children(of: DER.single(Array(reply)), expecting: 0x30)
        guard let statusInfo = response.first,
              let status = try DER.children(of: statusInfo, expecting: 0x30).first,
              status.tag == 0x02 else { throw Failure.malformed("no status") }
        let code = DER.integerValue(status.content)
        guard code == 0 || code == 1 else { throw Failure.refused(status: code) }
        guard response.count > 1, response[1].tag == 0x30 else {
            throw Failure.malformed("no token")
        }
        return Data(response[1].encoded)
    }

    /// Reads a reply: the token's TSTInfo, its signature, and its chain at the signing time.
    static func inspect(reply: Data) throws -> Inspection {
        let decoded = try CMSToken(token: token(fromReply: reply))
        let info = try TSTInfo(der: decoded.content)
        let trust = decoded.chainTrusted(at: info.genTime)
        return Inspection(
            imprint: info.imprint.hexString,
            nonce: info.nonce, signedAt: info.genTime, signer: decoded.signer,
            signerSHA256: decoded.signerSHA256,
            signatureValid: decoded.signatureValid,
            chainTrusted: trust)
    }

    // MARK: - TSTInfo

    private struct TSTInfo {
        let imprint: [UInt8]
        let nonce: [UInt8]?
        let genTime: Date

        /// version, policy, messageImprint, serialNumber, genTime, then optional fields; the
        /// nonce is the one INTEGER after genTime.
        init(der: [UInt8]) throws {
            let fields = try DER.children(of: DER.single(der), expecting: 0x30)
            guard fields.count >= 5, fields[2].tag == 0x30, fields[4].tag == 0x18 else {
                throw Failure.malformed("TSTInfo fields")
            }
            let imprint = try DER.children(of: fields[2], expecting: 0x30)
            guard imprint.count == 2, imprint[1].tag == 0x04,
                  let algorithm = try DER.children(of: imprint[0], expecting: 0x30).first,
                  algorithm.tag == 0x06, Array(algorithm.content) == TimestampToken.sha256OID
            else { throw Failure.malformed("the imprint is not SHA-256") }
            self.imprint = Array(imprint[1].content)
            guard let time = DER.generalizedTime(fields[4].content) else {
                throw Failure.malformed("genTime")
            }
            genTime = time
            let nonce = fields.dropFirst(5).first { $0.tag == 0x02 }
            self.nonce = nonce.map { DER.unsignedMagnitude($0.content) }
        }
    }

    // MARK: - CMS

    /// The token's eContent and signer, decoded by Security.framework.
    private final class CMSToken {
        let content: [UInt8]
        let signatureValid: Bool
        let signer: String?
        let signerSHA256: String?
        private let trust: SecTrust?

        init(token: Data) throws {
            let decoder = try Self.decoder(token, detached: nil)
            var type: CFData?
            guard CMSDecoderCopyEncapsulatedContentType(decoder, &type) == errSecSuccess,
                  let type, Array(type as Data) == TimestampToken.tstInfoOID
            else { throw Failure.malformed("content is not TSTInfo") }
            var data: CFData?
            guard CMSDecoderCopyContent(decoder, &data) == errSecSuccess, let data else {
                throw Failure.malformed("no TSTInfo")
            }
            content = Array(data as Data)
            var signers = 0
            guard CMSDecoderGetNumSigners(decoder, &signers) == errSecSuccess, signers == 1 else {
                throw Failure.signature("expected one signer")
            }
            // CMSDecoder reports an embedded eContent of a type other than id-data as needing
            // detached content, so the signature is checked over the content the token carries.
            let checker = try Self.decoder(token, detached: data)
            // Signature only here; the chain is evaluated at the signing time in chainTrusted.
            var status = CMSSignerStatus.unsigned
            var trust: SecTrust?
            guard CMSDecoderCopySignerStatus(
                checker, 0, SecPolicyCreateBasicX509(), false, &status, &trust, nil)
                == errSecSuccess else { throw Failure.signature("signer status") }
            signatureValid = status == .valid
            self.trust = trust
            var certificate: SecCertificate?
            if CMSDecoderCopySignerCert(decoder, 0, &certificate) != errSecSuccess {
                certificate = nil
            }
            signer = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            signerSHA256 = certificate.map {
                SHA256.hash(data: SecCertificateCopyData($0) as Data).hexString
            }
        }

        private static func decoder(_ token: Data, detached: CFData?) throws -> CMSDecoder {
            var made: CMSDecoder?
            guard CMSDecoderCreate(&made) == errSecSuccess, let decoder = made else {
                throw Failure.malformed("CMS decoder")
            }
            let updated = token.withUnsafeBytes { bytes in
                bytes.baseAddress.map { CMSDecoderUpdateMessage(decoder, $0, bytes.count) }
                    ?? errSecParam
            }
            if let detached, CMSDecoderSetDetachedContent(decoder, detached) != errSecSuccess {
                throw Failure.malformed("content")
            }
            guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess
            else { throw Failure.malformed("not CMS SignedData") }
            return decoder
        }

        /// The signer's chain under the time-stamping policy at `date`, against this Mac's
        /// trust settings. A self-signed authority (FreeTSA) is not trusted.
        func chainTrusted(at date: Date) -> Bool {
            guard let trust else { return false }
            let policy = SecPolicyCreateWithProperties(kSecPolicyAppleTimeStamping, nil)
                ?? SecPolicyCreateBasicX509()
            guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
                  SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess
            else { return false }
            return SecTrustEvaluateWithError(trust, nil)
        }
    }
}

/// The few DER rules a time-stamp request and reply need: definite lengths, one-byte tags.
enum DER {
    struct Node {
        let tag: UInt8
        let content: ArraySlice<UInt8>
        let encoded: ArraySlice<UInt8>
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        let length: [UInt8] = switch count {
        case ..<0x80: [UInt8(count)]
        case ..<0x100: [0x81, UInt8(count)]
        default: [0x82, UInt8(count >> 8), UInt8(count & 0xff)]
        }
        return [tag] + length + content
    }

    /// `magnitude` as a positive INTEGER's content: leading zeros dropped, one 0x00 put back
    /// when the top bit is set.
    static func positiveInteger(_ magnitude: [UInt8]) -> [UInt8] {
        let trimmed = Array(magnitude.drop { $0 == 0 })
        guard let first = trimmed.first else { return [0x00] }
        return first & 0x80 != 0 ? [0x00] + trimmed : trimmed
    }

    static func unsignedMagnitude(_ content: ArraySlice<UInt8>) -> [UInt8] {
        let trimmed = Array(content.drop { $0 == 0 })
        return trimmed.isEmpty ? [0x00] : trimmed
    }

    /// A small INTEGER (a status); anything over four bytes reads as -1.
    static func integerValue(_ content: ArraySlice<UInt8>) -> Int {
        guard !content.isEmpty, content.count <= 4 else { return -1 }
        return content.reduce(0) { $0 << 8 | Int($1) }
    }

    /// The one element `bytes` holds, with nothing after it.
    static func single(_ bytes: [UInt8]) throws -> Node {
        let (node, rest) = try read(bytes[...])
        guard rest.isEmpty else { throw TimestampToken.Failure.malformed("trailing bytes") }
        return node
    }

    static func children(of node: Node, expecting tag: UInt8) throws -> [Node] {
        guard node.tag == tag else { throw TimestampToken.Failure.malformed("unexpected tag") }
        var rest = node.content
        var nodes: [Node] = []
        while !rest.isEmpty {
            let (child, after) = try read(rest)
            nodes.append(child)
            rest = after
        }
        return nodes
    }

    private static func read(_ bytes: ArraySlice<UInt8>) throws -> (Node, ArraySlice<UInt8>) {
        let bad = TimestampToken.Failure.malformed("DER")
        var index = bytes.startIndex
        guard bytes.count >= 2, bytes[index] & 0x1f != 0x1f else { throw bad }
        let tag = bytes[index]
        index += 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let octets = length & 0x7f
            guard (1...3).contains(octets), bytes.endIndex - index >= octets else { throw bad }
            length = bytes[index..<index + octets].reduce(0) { $0 << 8 | Int($1) }
            index += octets
        }
        guard bytes.endIndex - index >= length else { throw bad }
        let end = index + length
        return (Node(tag: tag, content: bytes[index..<end], encoded: bytes[bytes.startIndex..<end]),
                bytes[end...])
    }

    /// `YYYYMMDDHHMMSS[.fff]Z`, the form RFC 3161 requires.
    static func generalizedTime(_ content: ArraySlice<UInt8>) -> Date? {
        let text = String(decoding: content, as: UTF8.self)
        guard text.hasSuffix("Z"), text.count >= 15 else { return nil }
        let whole = String(text.prefix(14))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        guard let date = formatter.date(from: whole) else { return nil }
        let fraction = text.dropFirst(14).dropLast()
        guard fraction.isEmpty || fraction.hasPrefix("."),
              let seconds = Double("0" + fraction) else { return nil }
        return date.addingTimeInterval(seconds)
    }
}
