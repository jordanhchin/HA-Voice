import Foundation

struct HomeAssistantClient {
    var urlSession: URLSession = .shared

    func testConnection(serverURL: String, token: String) async throws {
        let request = try authorizedRequest(serverURL: serverURL, token: token, path: "/api/")
        let (_, response) = try await execute(request, rawServerURL: serverURL)
        try validate(response)
    }

    func fetchMediaPlayers(serverURL: String, token: String) async throws -> [MediaPlayerTarget] {
        let request = try authorizedRequest(serverURL: serverURL, token: token, path: "/api/states")
        let (data, response) = try await execute(request, rawServerURL: serverURL)
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
        let (_, response) = try await execute(request, rawServerURL: serverURL)
        try validate(response)
    }

    static func normalizedBaseURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HomeAssistantError.invalidServerURL
        }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else {
            throw HomeAssistantError.invalidServerURL
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
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

    private func execute(_ request: URLRequest, rawServerURL: String) async throws -> (Data, URLResponse) {
        do {
            return try await urlSession.data(for: request)
        } catch let urlError as URLError where urlError.code == .appTransportSecurityRequiresSecureConnection {
            throw HomeAssistantError.insecureConnectionBlocked
        } catch let nsError as NSError where nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            throw HomeAssistantError.insecureConnectionBlocked
        } catch {
            if isTLSOrConnectionError(error) {
                let trimmed = rawServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.contains("://") {
                    var withoutTrailing = trimmed
                    while withoutTrailing.hasSuffix("/") {
                        withoutTrailing.removeLast()
                    }
                    throw HomeAssistantError.secureConnectionFailed(suggestion: "http://\(withoutTrailing)")
                } else {
                    throw HomeAssistantError.secureConnectionFailed(suggestion: nil)
                }
            }
            throw error
        }
    }

    private func isTLSOrConnectionError(_ error: Error) -> Bool {
        let code: Int? = {
            if let urlError = error as? URLError {
                return urlError.errorCode
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return nsError.code
            }
            return nil
        }()

        guard let code else { return false }

        switch code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             -1206 ... -1200:
            return true
        default:
            return false
        }
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
    case insecureConnectionBlocked
    case secureConnectionFailed(suggestion: String?)
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
        case .insecureConnectionBlocked:
            "Insecure HTTP connection blocked. Remote servers require HTTPS."
        case .secureConnectionFailed(let suggestion):
            if let suggestion {
                "Couldn't connect securely. If this is a local Home Assistant server, try \(suggestion)"
            } else {
                "Couldn't connect securely."
            }
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
