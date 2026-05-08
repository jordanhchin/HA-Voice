import Foundation

struct HomeAssistantClient {
    var urlSession: URLSession = .shared

    func testConnection(serverURL: String, token: String) async throws {
        let request = try authorizedRequest(serverURL: serverURL, token: token, path: "/api/")
        let (_, response) = try await urlSession.data(for: request)
        try validate(response)
    }

    func fetchMediaPlayers(serverURL: String, token: String) async throws -> [MediaPlayerTarget] {
        let request = try authorizedRequest(serverURL: serverURL, token: token, path: "/api/states")
        let (data, response) = try await urlSession.data(for: request)
        try validate(response)
        return try Self.mediaPlayers(from: data)
    }

    func sendTTS(
        serverURL: String,
        token: String,
        message: String,
        target: MediaPlayerTarget,
        voicePreset: VoicePreset
    ) async throws {
        var request = try authorizedRequest(serverURL: serverURL, token: token, path: "/api/services/tts/cloud_say")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.ttsPayload(message: message, target: target, voicePreset: voicePreset),
            options: []
        )
        let (_, response) = try await urlSession.data(for: request)
        try validate(response)
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HomeAssistantError.invalidServerURL
        }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else {
            throw HomeAssistantError.invalidServerURL
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw HomeAssistantError.invalidServerURL
        }
        return url
    }

    static func isValidToken(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func ttsPayload(
        message: String,
        target: MediaPlayerTarget,
        voicePreset: VoicePreset
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "entity_id": target.entityID,
            "message": message,
            "cache": false
        ]

        if !voicePreset.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["language"] = voicePreset.language
        }

        if let voice = voicePreset.serviceVoice {
            payload["options"] = ["voice": voice]
        }

        return payload
    }

    static func mediaPlayers(from data: Data) throws -> [MediaPlayerTarget] {
        let states = try JSONDecoder().decode([HAState].self, from: data)
        return states
            .filter { $0.entityID.hasPrefix("media_player.") }
            .map { state in
                MediaPlayerTarget(
                    entityID: state.entityID,
                    friendlyName: state.attributes.friendlyName ?? "",
                    state: state.state
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func authorizedRequest(serverURL: String, token: String, path: String) throws -> URLRequest {
        guard Self.isValidToken(token) else {
            throw HomeAssistantError.missingToken
        }

        let baseURL = try Self.normalizedBaseURL(serverURL)
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HomeAssistantError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw HomeAssistantError.authenticationFailed
            }
            throw HomeAssistantError.serviceFailed(httpResponse.statusCode)
        }
    }
}

enum HomeAssistantError: LocalizedError, Equatable {
    case invalidServerURL
    case missingToken
    case invalidResponse
    case authenticationFailed
    case serviceFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid Home Assistant server URL."
        case .missingToken:
            "Enter a long-lived access token."
        case .invalidResponse:
            "Home Assistant returned an unexpected response."
        case .authenticationFailed:
            "The Home Assistant token was rejected."
        case .serviceFailed(let statusCode):
            "Home Assistant returned status \(statusCode)."
        }
    }
}

private struct HAState: Decodable {
    let entityID: String
    let state: String
    let attributes: HAAttributes

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
    }
}

private struct HAAttributes: Decodable {
    let friendlyName: String?

    enum CodingKeys: String, CodingKey {
        case friendlyName = "friendly_name"
    }
}
