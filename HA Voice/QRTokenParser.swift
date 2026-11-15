import Foundation

enum QRTokenParser {
    private static let tokenKeys = [
        "long_lived_access_token",
        "access_token",
        "token",
        "ha_token"
    ]

    static func token(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let jsonToken = tokenFromJSON(trimmed) {
            return jsonToken
        }

        if let urlToken = tokenFromURL(trimmed) {
            return urlToken
        }

        if isJWT(trimmed) {
            return trimmed
        }

        return nil
    }

    static func isJWT(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=")
        for part in parts {
            guard !part.isEmpty else { return false }
            if part.unicodeScalars.contains(where: { !allowed.contains($0) }) {
                return false
            }
        }
        return true
    }

    private static func tokenFromJSON(_ rawValue: String) -> String? {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        for key in tokenKeys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    private static func tokenFromURL(_ rawValue: String) -> String? {
        guard let components = URLComponents(string: rawValue) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        let fragmentItems = URLComponents(string: "?\(components.fragment ?? "")")?.queryItems ?? []

        for item in queryItems + fragmentItems {
            guard tokenKeys.contains(item.name),
                  let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }

        return nil
    }
}
