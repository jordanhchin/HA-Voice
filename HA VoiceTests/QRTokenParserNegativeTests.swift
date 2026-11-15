import Foundation
import Testing
@testable import HA_Voice

struct QRTokenParserNegativeTests {
    @Test func acceptsValidJWT() {
        let validJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgN_-_w123abc"
        #expect(QRTokenParser.token(from: validJWT) == validJWT)
        #expect(QRTokenParser.token(from: "  \(validJWT)  ") == validJWT)
    }

    @Test func rejectsRawArbitraryText() {
        #expect(QRTokenParser.token(from: "hello world") == nil)
        #expect(QRTokenParser.token(from: "just-a-plain-string") == nil)
        #expect(QRTokenParser.token(from: "1234567890") == nil)
        #expect(QRTokenParser.token(from: "not a token at all") == nil)
    }

    @Test func rejectsMalformedJWTSegmentCounts() {
        #expect(QRTokenParser.token(from: "singleSegment") == nil)
        #expect(QRTokenParser.token(from: "two.segments") == nil)
        #expect(QRTokenParser.token(from: "four.different.segments.here") == nil)
        #expect(QRTokenParser.token(from: "five.different.segments.here.now") == nil)
    }

    @Test func rejectsEmptyJWTSegments() {
        #expect(QRTokenParser.token(from: ".payload.signature") == nil)
        #expect(QRTokenParser.token(from: "header..signature") == nil)
        #expect(QRTokenParser.token(from: "header.payload.") == nil)
        #expect(QRTokenParser.token(from: "..") == nil)
    }

    @Test func rejectsDisallowedCharactersInRawJWT() {
        #expect(QRTokenParser.token(from: "header.pay!load.signature") == nil)
        #expect(QRTokenParser.token(from: "header.payload.sign@ture") == nil)
        #expect(QRTokenParser.token(from: "head er.payload.signature") == nil)
        #expect(QRTokenParser.token(from: "header.pay#load.signature") == nil)
    }

    @Test func rejectsEmptyOrWhitespaceInput() {
        #expect(QRTokenParser.token(from: "") == nil)
        #expect(QRTokenParser.token(from: "    \t \n  ") == nil)
    }

    @Test func rejectsJSONWithoutTokenKeys() {
        #expect(QRTokenParser.token(from: "{}") == nil)
        #expect(QRTokenParser.token(from: #"{"other_key":"some_value"}"#) == nil)
        #expect(QRTokenParser.token(from: #"{"token":""}"#) == nil)
        #expect(QRTokenParser.token(from: #"{"access_token":"   "}"#) == nil)
    }

    @Test func rejectsURLWithoutTokenParameters() {
        #expect(QRTokenParser.token(from: "https://homeassistant.local:8123") == nil)
        #expect(QRTokenParser.token(from: "homeassistant://auth?code=123") == nil)
        #expect(QRTokenParser.token(from: "https://example.com/login#state=xyz") == nil)
    }

    @Test func extractsFromAllSupportedJSONKeys() {
        #expect(QRTokenParser.token(from: #"{"long_lived_access_token":"token-1"}"#) == "token-1")
        #expect(QRTokenParser.token(from: #"{"access_token":"token-2"}"#) == "token-2")
        #expect(QRTokenParser.token(from: #"{"token":"token-3"}"#) == "token-3")
        #expect(QRTokenParser.token(from: #"{"ha_token":"token-4"}"#) == "token-4")
    }

    @Test func extractsFromURLQueryAndFragment() {
        #expect(QRTokenParser.token(from: "homeassistant://auth?token=my-query-token") == "my-query-token")
        #expect(QRTokenParser.token(from: "homeassistant://auth#ha_token=my-fragment-token") == "my-fragment-token")
    }
}
