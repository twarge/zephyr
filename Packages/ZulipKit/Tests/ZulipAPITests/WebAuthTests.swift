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
