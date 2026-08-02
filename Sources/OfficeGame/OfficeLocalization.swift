// 이 파일은 시스템 언어에 맞는 OfficeGame UI 문구를 리소스에서 읽는다.

import Foundation

enum OfficeLocalization {
    private static let koreanDefaultIdentityPrompt =
        "업무 지시를 정확히 이해하고 실행 계획과 결과를 간결하게 보고한다."
    private static let englishDefaultIdentityPrompt =
        "Understand work instructions precisely and report the execution plan and results concisely."

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

    static func displayIdentityPrompt(_ prompt: String) -> String {
        guard prompt == koreanDefaultIdentityPrompt else {
            return prompt
        }

        return usesKorean ? koreanDefaultIdentityPrompt : englishDefaultIdentityPrompt
    }

    static func canonicalIdentityPrompt(_ prompt: String) -> String {
        prompt == englishDefaultIdentityPrompt ? koreanDefaultIdentityPrompt : prompt
    }

    private static var preferredLanguages: [String] {
        UserDefaults.standard.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
    }
}
