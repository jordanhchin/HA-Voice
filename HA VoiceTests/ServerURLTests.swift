import Foundation
import Testing
@testable import HA_Voice

struct ServerURLTests {
    @Test func normalizesHTTPScheme() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("http://homeassistant.local:8123")
        #expect(url.absoluteString == "http://homeassistant.local:8123")
    }

    @Test func normalizesHTTPSScheme() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://homeassistant.local:8123")
        #expect(url.absoluteString == "https://homeassistant.local:8123")
    }

    @Test func defaultsToHTTPSWhenSchemeOmitted() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("homeassistant.local:8123")
        #expect(url.absoluteString == "https://homeassistant.local:8123")
    }

    @Test func preservesPort() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://myha.net:8443")
        #expect(url.absoluteString == "https://myha.net:8443")
    }

    @Test func preservesSubpathWithoutTrailingSlash() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://example.com/ha")
        #expect(url.absoluteString == "https://example.com/ha")
    }

    @Test func preservesSubpathWithTrailingSlash() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://example.com/ha/")
        #expect(url.absoluteString == "https://example.com/ha")
    }

    @Test func preservesSubpathWithPortAndHTTP() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("http://192.168.1.50:8123/ha/")
        #expect(url.absoluteString == "http://192.168.1.50:8123/ha")
    }

    @Test func handlesIPv6WithPort() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://[::1]:8123")
        #expect(url.absoluteString == "https://[::1]:8123")
    }

    @Test func handlesIPv6WithSubpath() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://[::1]:8123/ha/")
        #expect(url.absoluteString == "https://[::1]:8123/ha")
    }

    @Test func handlesIPv6WithoutScheme() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("[::1]:8123")
        #expect(url.absoluteString == "https://[::1]:8123")
    }

    @Test func handlesLocalDomain() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("http://homeassistant.local:8123/")
        #expect(url.absoluteString == "http://homeassistant.local:8123")
    }

    @Test func stripsQueryAndFragment() throws {
        let url = try HomeAssistantClient.normalizedBaseURL("https://homeassistant.local:8123/ha?token=123#section")
        #expect(url.absoluteString == "https://homeassistant.local:8123/ha")
    }

    @Test func rejectsEmptyOrWhitespaceURL() {
        #expect(throws: HomeAssistantError.invalidServerURL) {
            _ = try HomeAssistantClient.normalizedBaseURL("")
        }
        #expect(throws: HomeAssistantError.invalidServerURL) {
            _ = try HomeAssistantClient.normalizedBaseURL("   \n\t  ")
        }
    }
}
