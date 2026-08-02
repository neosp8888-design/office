// 이 파일은 시스템 언어에 맞는 OfficeGame UI 문구를 리소스에서 읽는다.

import Foundation

enum OfficeLocalization {
    static var usesKorean: Bool {
        languageIdentifier(for: preferredLanguages) == "ko"
    }

    static var locale: Locale {
        Locale(identifier: languageIdentifier(for: preferredLanguages))
    }

    static func languageIdentifier(for languages: [String]) -> String {
        languages.contains { $0.lowercased().hasPrefix("ko") }
            ? "ko"
            : "en"
    }

    static func string(_ key: String) -> String {
        let localization = languageIdentifier(for: preferredLanguages)

        guard
            let path = Bundle.module.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            ),
            let translations = NSDictionary(contentsOfFile: path)
                as? [String: String]
        else {
            return key
        }

        return translations[key] ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: locale,
            arguments: arguments
        )
    }

    private static var preferredLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
    }
}
