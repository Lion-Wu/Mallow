import Foundation

struct ChatModelCatalogReadiness: Equatable {
    let apiURL: String
    let apiKey: String
    let formatPreference: ChatAPIFormatPreference
    let modelIDs: [String]

    func matches(settings: ChatSettings, format: ChatAPIFormatPreference) -> Bool {
        ChatAPIEndpointResolver.normalizedAPIBaseKey(apiURL) == ChatAPIEndpointResolver.normalizedAPIBaseKey(settings.apiURL)
            && apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            && formatPreference == format
    }
}
