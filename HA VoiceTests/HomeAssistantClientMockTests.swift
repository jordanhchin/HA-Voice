import Foundation
import Testing
@testable import HA_Voice

final class ClientMockURLProtocol: URLProtocol {
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
    private let office = MediaPlayerTarget(
        entityID: "media_player.office",
        friendlyName: "Office Speaker",
        state: "idle"
    )
    private let bedroom = MediaPlayerTarget(
        entityID: "media_player.bedroom",
        friendlyName: "Bedroom Speaker",
        state: "idle"
    )

    private func makeClient() -> HomeAssistantClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClientMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return HomeAssistantClient(urlSession: session)
    }

    @Test func authenticationFailure401ThrowsAuthenticationFailed() async {
        let token = "test-token-401"
        ClientMockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        await #expect(throws: HomeAssistantError.authenticationFailed) {
            try await client.testConnection(serverURL: "https://ha.local:8123", token: token)
        }
    }

    @Test func authenticationFailure403ThrowsAuthenticationFailed() async {
        let token = "test-token-403"
        ClientMockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        await #expect(throws: HomeAssistantError.authenticationFailed) {
            try await client.fetchMediaPlayers(serverURL: "https://ha.local:8123", token: token)
        }
    }

    @Test func emptyStatesReturnsNoPlayers() async throws {
        let token = "test-token-empty-states"
        ClientMockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = "[]".data(using: .utf8)!
            return (response, data)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

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

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, nonPlayersJSON)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let players = try await client.fetchMediaPlayers(serverURL: "https://ha.local:8123", token: token)
        #expect(players.isEmpty)
    }

    @Test func cloudSay500ThrowsServiceFailedWithUsefulMessage() async {
        let token = "test-token-500"
        ClientMockURLProtocol.setHandler(forToken: token) { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let voice = VoicePreset(id: UUID(), name: "Maisie", language: "en-GB", voice: "MaisieNeural", isCustom: false)
        do {
            try await client.sendTTS(
                serverURL: "https://ha.local:8123",
                token: token,
                message: "Test message",
                targets: [kitchen],
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

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let voice = VoicePreset(id: UUID(), name: "Guy", language: "en-US", voice: "GuyNeural", isCustom: true)
        try await client.sendTTS(
            serverURL: "https://myha.org:8123/ha/",
            token: token,
            message: "Hello World",
            targets: [kitchen],
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

    @Test func sendTTSSpeakUsesSpeakEndpointWithMultipleSpeakers() async throws {
        let token = "speak-token-multi"
        var capturedRequests: [URLRequest] = []

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            capturedRequests.append(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let engines = [
            TTSEngine(entityID: "tts.piper", name: "Piper"),
            TTSEngine(entityID: "tts.home_assistant_cloud", name: "Home Assistant Cloud")
        ]
        let voice = VoicePreset(
            id: UUID(),
            name: "Piper Voice",
            language: "en-US",
            voice: "en_US-lessac-medium",
            isCustom: true,
            engineID: "tts.piper"
        )

        try await client.sendTTS(
            serverURL: "https://myha.org:8123",
            token: token,
            message: "Announcement for everyone",
            targets: [kitchen, office],
            voicePreset: voice,
            ttsEngines: engines
        )

        #expect(capturedRequests.count == 1)
        let request = try #require(capturedRequests.first)
        #expect(request.url?.absoluteString == "https://myha.org:8123/api/services/tts/speak")

        let bodyData = try #require(request.extractBodyData())
        let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(json["entity_id"] as? String == "tts.piper")
        #expect(json["media_player_entity_id"] as? [String] == ["media_player.kitchen", "media_player.office"])
        #expect(json["message"] as? String == "Announcement for everyone")
        #expect(json["language"] as? String == "en-US")
        #expect(json["cache"] as? Bool == false)
        let options = try #require(json["options"] as? [String: String])
        #expect(options["voice"] == "en_US-lessac-medium")
    }

    @Test func cloudSayFallbackSendsOneRequestPerSpeakerWhenNoEnginesExist() async throws {
        let token = "fallback-multi-token"
        var capturedRequests: [URLRequest] = []

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            capturedRequests.append(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        try await client.sendTTS(
            serverURL: "https://ha.local:8123",
            token: token,
            message: "Legacy broadcast",
            targets: [kitchen, office, bedroom],
            voicePreset: .defaultPreset,
            ttsEngines: []
        )

        #expect(capturedRequests.count == 3)
        var targetEntityIDs: [String] = []
        for request in capturedRequests {
            #expect(request.url?.absoluteString == "https://ha.local:8123/api/services/tts/cloud_say")
            let bodyData = try #require(request.extractBodyData())
            let json = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            if let entityID = json["entity_id"] as? String {
                targetEntityIDs.append(entityID)
            }
            #expect(json["message"] as? String == "Legacy broadcast")
            #expect(json["cache"] as? Bool == false)
        }
        #expect(targetEntityIDs == ["media_player.kitchen", "media_player.office", "media_player.bedroom"])
    }

    @Test func missingEngineThrowsClearErrorAndSendsNoRequest() async {
        let token = "missing-engine-token"
        var requestCount = 0

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let engines = [TTSEngine(entityID: "tts.google_translate", name: "Google Translate")]
        let missingPreset = VoicePreset(
            id: UUID(),
            name: "Removed Piper",
            language: "en-US",
            voice: "",
            isCustom: true,
            engineID: "tts.piper"
        )

        do {
            try await client.sendTTS(
                serverURL: "https://ha.local:8123",
                token: token,
                message: "Should fail before network",
                targets: [kitchen, office],
                voicePreset: missingPreset,
                ttsEngines: engines
            )
            #expect(Bool(false), "Expected missingTTSEngine error to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .missingTTSEngine("tts.piper"))
            #expect(error.errorDescription == "Speech engine tts.piper isn't available on this server.")
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }

        #expect(requestCount == 0)
    }

    @Test @MainActor func refreshMediaPlayersUpdatesEnginesDropsStaleTargetsAndFallsBackToFirstSpeaker() async throws {
        let token = "refresh-state-token"
        var statesFetchCount = 0
        var statesPayload = """
        [
          {
            "entity_id": "media_player.office",
            "state": "idle",
            "attributes": { "friendly_name": "Office" }
          },
          {
            "entity_id": "media_player.kitchen",
            "state": "idle",
            "attributes": { "friendly_name": "Kitchen" }
          },
          {
            "entity_id": "tts.piper",
            "state": "unknown",
            "attributes": { "friendly_name": "Piper" }
          }
        ]
        """.data(using: .utf8)!

        ClientMockURLProtocol.setHandler(forToken: token) { request in
            statesFetchCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, statesPayload)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        let defaults = UserDefaults(suiteName: "SpeakRefreshTests-\(UUID().uuidString)")!
        let state = AppState(
            client: client,
            keychain: KeychainTokenStore(),
            defaults: defaults
        )
        state.serverProfile = ServerProfile(
            serverURL: "https://ha.local:8123",
            displayName: "HA",
            lastConnectionStatus: .connected
        )
        state.token = token
        state.selectedTargetIDs = ["media_player.removed", "media_player.office"]

        await state.refreshMediaPlayers()

        // Single network call populates both mediaPlayers and ttsEngines, drops "media_player.removed", keeps "media_player.office"
        #expect(statesFetchCount == 1)
        #expect(state.mediaPlayers.map(\.entityID) == ["media_player.kitchen", "media_player.office"])
        #expect(state.ttsEngines == [TTSEngine(entityID: "tts.piper", name: "Piper")])
        #expect(state.selectedTargetIDs == ["media_player.office"])
        #expect(state.selectedTargets.map(\.entityID) == ["media_player.office"])

        // Second refresh where none of the selected IDs remain falls back to first speaker ("media_player.kitchen")
        state.selectedTargetIDs = ["media_player.gone_1", "media_player.gone_2"]
        await state.refreshMediaPlayers()

        #expect(statesFetchCount == 2)
        #expect(state.selectedTargetIDs == ["media_player.kitchen"])
        #expect(state.selectedTargets.map(\.entityID) == ["media_player.kitchen"])

        // Test multi-select toggle, select all, and clear behaviors
        state.selectAllTargets()
        #expect(state.selectedTargetIDs == ["media_player.kitchen", "media_player.office"])

        state.clearTargetSelection()
        #expect(state.selectedTargetIDs == ["media_player.kitchen"])

        // Deselecting the last remaining speaker is prevented
        state.toggleTargetSelection(kitchen)
        #expect(state.selectedTargetIDs == ["media_player.kitchen"])
    }

    @Test func atsBlockedInsecureHTTPThrowsClearError() async {
        let token = "test-token-ats"
        ClientMockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

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

    @Test func tlsFailureOnSchemelessHostSuggestsHTTP() async {
        let token = "test-token-tls-schemeless"
        ClientMockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(.secureConnectionFailed)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        do {
            try await client.testConnection(serverURL: "homeassistant.local:8123", token: token)
            #expect(Bool(false), "Expected secureConnectionFailed to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .secureConnectionFailed(suggestion: "http://homeassistant.local:8123"))
            let desc = error.errorDescription ?? ""
            #expect(desc.contains("try http://homeassistant.local:8123"))
            #expect(desc.contains("Couldn't connect securely."))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test(arguments: [URLError.Code.cannotFindHost, .timedOut, .networkConnectionLost])
    func dnsOrTimeoutFailureOnSchemelessHostDoesNotSuggestHTTP(code: URLError.Code) async {
        let token = "test-token-dns-schemeless-\(code.rawValue)"
        ClientMockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(code)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        do {
            try await client.testConnection(serverURL: "homeassitant.local:8123", token: token)
            #expect(Bool(false), "Expected an error to be thrown")
        } catch let error as HomeAssistantError {
            if case .secureConnectionFailed = error {
                #expect(Bool(false), "DNS/timeout failures must not suggest http://")
            }
        } catch {
            // Non-HomeAssistantError network failures are fine; they carry no http suggestion.
        }
    }

    @Test func connectionFailureOnSchemelessHostWithSlashSuggestsHTTPWithoutTrailingSlash() async {
        let token = "test-token-conn-schemeless"
        ClientMockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        do {
            try await client.testConnection(serverURL: "homeassistant.local:8123/", token: token)
            #expect(Bool(false), "Expected secureConnectionFailed to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .secureConnectionFailed(suggestion: "http://homeassistant.local:8123"))
            let desc = error.errorDescription ?? ""
            #expect(desc.contains("try http://homeassistant.local:8123"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test func tlsFailureOnExplicitHTTPSDoesNotSuggestHTTP() async {
        let token = "test-token-tls-explicit"
        ClientMockURLProtocol.setHandler(forToken: token) { _ in
            throw URLError(.secureConnectionFailed)
        }
        defer { ClientMockURLProtocol.removeHandler(forToken: token) }

        let client = makeClient()
        do {
            try await client.testConnection(serverURL: "https://homeassistant.local:8123", token: token)
            #expect(Bool(false), "Expected secureConnectionFailed to be thrown")
        } catch let error as HomeAssistantError {
            #expect(error == .secureConnectionFailed(suggestion: nil))
            let desc = error.errorDescription ?? ""
            #expect(desc == "Couldn't connect securely.")
            #expect(!desc.contains("http:"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }
}
