//
//  AppLocalization.swift
//  Mallow
//
//  Created by Lion Wu on 2023/12/25.
//

import Foundation

enum AppLocalization {
    static var supportedLocalizationIdentifiers: [String] {
        Bundle.main.localizations
    }

    static func localizedPlaceholderTitles() -> Set<String> {
        var identifiers = Set(supportedLocalizationIdentifiers)
        identifiers.insert("en")
        identifiers.insert(Locale.current.identifier)

        return Set(
            identifiers.map { identifier in
                String(localized: "CHAT_TITLE_NEW", defaultValue: "New Chat", locale: Locale(identifier: identifier))
            }
        )
    }
}
