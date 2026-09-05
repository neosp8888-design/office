// 이 파일은 시스템 언어에 맞는 OfficeGame UI 문구를 리소스에서 읽는다.

import Foundation

enum OfficeLocalization {
    private static let koreanDefaultIdentityPrompt =
        "업무 지시를 정확히 이해하고 실행 계획과 결과를 간결하게 보고한다."
    private static let englishDefaultIdentityPrompt =
        "Understand work instructions precisely and report the execution plan and results concisely."
    private static let translationsByLanguage = Dictionary(
        uniqueKeysWithValues: ["ko", "en"].map { language in
            (language, loadTranslations(for: language))
        }
    )

    static var usesKorean: Bool {
        languageIdentifier(for: preferredLanguages) == "ko"
    }

    static var locale: Locale {
        Locale(identifier: languageIdentifier(for: preferredLanguages))
    }

    static func languageIdentifier(for languages: [String]) -> String {
        languages.lazy.compactMap { language -> String? in
            let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            return code == "ko" || code == "en" ? code : nil
        }.first ?? "en"
    }

    static func string(_ key: String) -> String {
        string(key, languages: preferredLanguages)
    }

    static func string(
        _ key: String,
        languages: [String]
    ) -> String {
        let localization = languageIdentifier(for: languages)
        return translationsByLanguage[localization]?[key] ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, languages: preferredLanguages)
    }

    static func format(_ key: String, arguments: [CVarArg], languages: [String]) -> String {
        let language = languageIdentifier(for: languages)
        let singular = arguments.compactMap { $0 as? Int }.first == 1
            ? translationsByLanguage[language]?[key + ".one"] : nil
        return String(format: singular ?? string(key, languages: languages),
                      locale: Locale(identifier: language), arguments: arguments)
    }

    static func date(_ date: Date, dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time).locale(locale))
    }

    static func historyNoun(_ key: String) -> String {
        usesKorean ? key : translationsByLanguage["en"]?[key + ".history"] ?? string(key)
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

    private static func loadTranslations(
        for localization: String
    ) -> [String: String] {
        guard
            let path = OfficeGameResourceBundle.bundle.path(
                forResource: "Localizable",
                ofType: "strings",
                inDirectory: nil,
                forLocalization: localization
            ),
            let translations = NSDictionary(contentsOfFile: path)
                as? [String: String]
        else {
            return [:]
        }
        return translations
    }
}
