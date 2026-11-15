import Foundation
import Testing
@testable import HA_Voice

final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

    static func setHandler(forToken token: String, handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handlers["Bearer \(token)"] = handler
    }

    static func removeHandler(forToken token: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: "Bearer \(token)")
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        Self.lock.lock()
        let handler = Self.handlers[auth]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func extractBodyData() -> Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

@Suite(.serialized)
struct HomeAssistantClientMockTests {
    private let kitchen = MediaPlayerTarget(
        entityID: "media_player.kitchen",
        friendlyName: "Kitchen Speaker",
        state: "idle"
    )

    private func makeClient() -> HomeAssistantClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HomeAssistantClient(urlSession: session)
    }

    @Test func authenticationFailure401ThrowsAuthenticationFailed() async {
        let token = "test-token-401"
        MockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        await #expect(throws: HomeAssistantError.authenticationFailed) {
            try await client.testConnection(serverURL: "https://ha.local:8123", token: token)
        }
    }

    @Test func authenticationFailure403ThrowsAuthenticationFailed() async {
        let token = "test-token-403"
        MockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        await #expect(throws: HomeAssistantError.authenticationFailed) {
            try await client.fetchMediaPlayers(serverURL: "https://ha.local:8123", token: token)
        }
    }

    @Test func emptyStatesReturnsNoPlayers() async throws {
        let token = "test-token-empty-states"
        MockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = "[]".data(using: .utf8)!
            return (response, data)
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let players = try await client.fetchMediaPlayers(serverURL: "https://ha.local:8123", token: token)
        #expect(players.isEmpty)
    }

    @Test func statesWithoutMediaPlayersReturnsNoPlayers() async throws {
        let token = "test-token-non-players"
        let nonPlayersJSON = """
        [
            {
                "entity_id": "light.living_room",
                "state": "on",
                "attributes": { "friendly_name": "Living Room Light" }
            },
            {
                "entity_id": "switch.coffee_maker",
                "state": "off",
                "attributes": { "friendly_name": "Coffee Maker" }
            }
        ]
        """.data(using: .utf8)!

        MockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, nonPlayersJSON)
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let players = try await client.fetchMediaPlayers(serverURL: "https://ha.local:8123", token: token)
        #expect(players.isEmpty)
    }

    @Test func cloudSay500ThrowsServiceFailedWithUsefulMessage() async {
        let token = "test-token-500"
        MockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let voice = VoicePreset(id: UUID(), name: "Maisie", language: "en-GB", voice: "MaisieNeural", isCustom: false)
        do {
            try await client.sendTTS(
                serverURL: "https://ha.local:8123",
                token: token,
                message: "Test message",
                target: kitchen,
                voicePreset: voice
            )
            #expect(Bool(false), "Expected serviceFailed error to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .serviceFailed(500))
            #expect(error.errorDescription?.contains("500") == true)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func sendTTSCarriesCorrectHeadersBodyAndSubpath() async throws {
        let token = "secret-token-xyz"
        var capturedRequest: URLRequest?

        MockURLProtocol.setHandler(forToken: token) { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let voice = VoicePreset(id: UUID(), name: "Guy", language: "en-US", voice: "GuyNeural", isCustom: true)
        try await client.sendTTS(
            serverURL: "https://myha.org:8123/ha/",
            token: token,
            message: "Hello World",
            target: kitchen,
            voicePreset: voice
        )

        let request = try #require(capturedRequest)
        #expect(request.url?.absoluteString == "https://myha.org:8123/ha/api/services/tts/cloud_say")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(request.extractBodyData())
        let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(json["entity_id"] as? String == "media_player.kitchen")
        #expect(json["message"] as? String == "Hello World")
        #expect(json["cache"] as? Bool == false)
        #expect(json["language"] as? String == "en-US")
        let options = try #require(json["options"] as? [String: String])
        #expect(options["voice"] == "GuyNeural")
    }

    @Test func atsBlockedInsecureHTTPThrowsClearError() async {
        let token = "test-token-ats"
        MockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        defer { MockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        do {
            try await client.testConnection(serverURL: "http://remoteha.com:8123", token: token)
            #expect(Bool(false), "Expected insecureConnectionBlocked to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .insecureConnectionBlocked)
            #expect(error.errorDescription == "Insecure HTTP connection blocked. Remote servers require HTTPS.")
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }
}
