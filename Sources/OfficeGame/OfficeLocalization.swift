// 이 파일은 시스템 언어에 맞는 OfficeGame UI 문구를 리소스에서 읽는다.

import Foundation

enum OfficeLocalization {
    static func string(_ key: String) -> String {
        let localization = Locale.preferredLanguages.contains {
            $0.lowercased().hasPrefix("ko")
        }
            ? "ko"
            : "en"

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
}
