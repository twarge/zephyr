import Foundation

/// The `mobile_flow_otp` web-login flow: the client opens the realm's login
/// page with a one-time pad, and the server redirects to
/// `zulip://login?otp_encrypted_api_key=…` where the API key is recovered by
/// XOR. (The desktop flow yields only a short-lived browser session token, so
/// native clients use the mobile flow.)
public enum WebAuth {
    public enum Error: Swift.Error, Equatable {
        case invalidHex
        case lengthMismatch
        case notASCII
    }

    /// One-time pad: 32 random bytes as 64 lowercase hex characters.
    public static func generateOTP() -> String {
        var rng = SystemRandomNumberGenerator()
        return generateOTP(using: &rng)
    }

    public static func generateOTP(using rng: inout some RandomNumberGenerator) -> String {
        (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }
            .joined()
    }

    /// The URL to open in `ASWebAuthenticationSession` (callback scheme
    /// `zulip`). `loginPath` is an external method's `login_url` from
    /// /server_settings; nil means the realm's own login page (web password
    /// flow).
    public static func loginURL(realm: URL, loginPath: String? = nil, otp: String) -> URL? {
        var components = URLComponents(url: realm, resolvingAgainstBaseURL: false)
        components?.path = loginPath ?? "/accounts/login/"
        components?.queryItems = [URLQueryItem(name: "mobile_flow_otp", value: otp)]
        return components?.url
    }

    // MARK: Callback payload

    /// The parsed `zulip://login` redirect (the server includes the user id,
    /// so no follow-up /users/me call is needed).
    public struct Payload: Sendable, Equatable {
        public var realm: URL
        public var email: String
        public var userId: Int
        public var otpEncryptedAPIKey: String
    }

    public enum PayloadError: Swift.Error, Equatable {
        case notALoginCallback
        case missingField(String)
        case malformed(String)
    }

    /// Strict parse, mirroring zulip-flutter's validations: exact scheme and
    /// host, all four fields present, the encrypted key exactly 64 hex chars.
    public static func parsePayload(_ url: URL) throws -> Payload {
        guard url.scheme?.lowercased() == "zulip",
              url.host()?.lowercased() == "login",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw PayloadError.notALoginCallback }

        func field(_ name: String) throws -> String {
            guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
                  !value.isEmpty
            else { throw PayloadError.missingField(name) }
            return value
        }
        guard let realm = URL(string: try field("realm")), realm.host() != nil else {
            throw PayloadError.malformed("realm")
        }
        guard let userId = Int(try field("user_id")) else {
            throw PayloadError.malformed("user_id")
        }
        let encryptedKey = try field("otp_encrypted_api_key")
        guard encryptedKey.count == 64, encryptedKey.allSatisfy(\.isHexDigit) else {
            throw PayloadError.malformed("otp_encrypted_api_key")
        }
        return Payload(
            realm: realm, email: try field("email"), userId: userId,
            otpEncryptedAPIKey: encryptedKey)
    }

    /// Recovers the API key from the redirect's `otp_encrypted_api_key`.
    public static func decryptAPIKey(otpEncryptedAPIKey: String, otp: String) throws -> String {
        let encrypted = try hexToBytes(otpEncryptedAPIKey)
        let pad = try hexToBytes(otp)
        guard encrypted.count == pad.count else { throw Error.lengthMismatch }
        let keyBytes = zip(encrypted, pad).map(^)
        guard keyBytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { throw Error.notASCII }
        return String(decoding: keyBytes, as: UTF8.self)
    }

    static func hexToBytes(_ hex: String) throws -> [UInt8] {
        let chars = Array(hex.lowercased().utf8)
        guard chars.count.isMultiple(of: 2) else { throw Error.invalidHex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let high = hexValue(chars[index]), let low = hexValue(chars[index + 1]) else {
                throw Error.invalidHex
            }
            bytes.append(high << 4 | low)
        }
        return bytes
    }

    private static func hexValue(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): char - UInt8(ascii: "a") + 10
        default: nil
        }
    }
}
