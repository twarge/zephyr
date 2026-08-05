import Foundation
import Testing
@testable import ZulipAPI

struct WebAuthTests {
    @Test func otpFormat() {
        let otp = WebAuth.generateOTP()
        #expect(otp.count == 64)
        #expect(otp.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) })
        #expect(WebAuth.generateOTP() != otp)
    }

    @Test func decryptWithZeroPadIsIdentity() throws {
        // XOR with an all-zero pad returns the hex-decoded input unchanged.
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"  // 32 ASCII chars
        let encrypted = apiKey.utf8.map { String(format: "%02x", $0) }.joined()
        let zeroPad = String(repeating: "0", count: 64)
        #expect(try WebAuth.decryptAPIKey(otpEncryptedAPIKey: encrypted, otp: zeroPad) == apiKey)
    }

    @Test func decryptRoundTrip() throws {
        let apiKey = "gAcQeJmQlaOAXi3UGSTCUzRWyXQ1BSfR"  // realistic 32-char key
        let otp = WebAuth.generateOTP()
        let pad = try WebAuth.hexToBytes(otp)
        let encrypted = zip(apiKey.utf8, pad)
            .map { String(format: "%02x", $0 ^ $1) }
            .joined()
        #expect(try WebAuth.decryptAPIKey(otpEncryptedAPIKey: encrypted, otp: otp) == apiKey)
    }

    @Test func decryptRejectsMismatchedLengths() {
        #expect(throws: WebAuth.Error.lengthMismatch) {
            try WebAuth.decryptAPIKey(otpEncryptedAPIKey: "aabb", otp: "aabbcc")
        }
    }

    @Test func decryptRejectsInvalidHex() {
        #expect(throws: WebAuth.Error.invalidHex) {
            try WebAuth.decryptAPIKey(otpEncryptedAPIKey: "zz", otp: "aa")
        }
    }

    @Test func loginURL() throws {
        let realm = try #require(URL(string: "https://chat.example.com"))
        let url = try #require(WebAuth.loginURL(realm: realm, otp: "ab12"))
        #expect(url.absoluteString == "https://chat.example.com/accounts/login/?mobile_flow_otp=ab12")
    }
}

@Suite struct WebAuthPayloadTests {
    private let key = String(repeating: "ab", count: 32)

    @Test func parsesCompleteCallback() throws {
        let url = URL(string:
            "zulip://login?realm=https://chat.example.com&email=user%40example.com&user_id=7&otp_encrypted_api_key=\(key)")!
        let payload = try WebAuth.parsePayload(url)
        #expect(payload.realm == URL(string: "https://chat.example.com"))
        #expect(payload.email == "user@example.com")
        #expect(payload.userId == 7)
        #expect(payload.otpEncryptedAPIKey == key)
    }

    @Test func rejectsWrongSchemeOrHost() {
        #expect(throws: WebAuth.PayloadError.notALoginCallback) {
            try WebAuth.parsePayload(URL(string: "https://login?realm=x")!)
        }
        #expect(throws: WebAuth.PayloadError.notALoginCallback) {
            try WebAuth.parsePayload(URL(string: "zulip://logout?realm=x")!)
        }
    }

    @Test func rejectsMissingOrMalformedFields() {
        #expect(throws: WebAuth.PayloadError.missingField("email")) {
            try WebAuth.parsePayload(URL(string:
                "zulip://login?realm=https://x.com&user_id=7&otp_encrypted_api_key=\(key)")!)
        }
        #expect(throws: WebAuth.PayloadError.malformed("otp_encrypted_api_key")) {
            try WebAuth.parsePayload(URL(string:
                "zulip://login?realm=https://x.com&email=e&user_id=7&otp_encrypted_api_key=zz")!)
        }
        #expect(throws: WebAuth.PayloadError.malformed("user_id")) {
            try WebAuth.parsePayload(URL(string:
                "zulip://login?realm=https://x.com&email=e&user_id=seven&otp_encrypted_api_key=\(key)")!)
        }
    }

    @Test func methodLoginURL() {
        let url = WebAuth.loginURL(
            realm: URL(string: "https://chat.example.com")!,
            loginPath: "/accounts/login/social/google/", otp: "aa")
        #expect(url?.absoluteString
            == "https://chat.example.com/accounts/login/social/google/?mobile_flow_otp=aa")
    }
}
