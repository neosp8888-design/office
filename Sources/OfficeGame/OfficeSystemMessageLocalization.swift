// Translate only app/backend-generated diagnostics at the presentation boundary.
// Stored conversations, provider output, prompts, paths and model replies stay intact.
import Foundation

enum OfficeSystemMessageLocalization {
    private static let slotPattern = try! NSRegularExpression(pattern: #"\{\d+\}"#)
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        cache.totalCostLimit = 1_048_576
        return cache
    }()

    struct Entry: Decodable {
        let source: String
        let translation: String
        let translatedArguments: [Int]?
    }

    private struct Rule {
        let expression: NSRegularExpression
        let template: String
        let slots: [String]
        let translatedArguments: Set<Int>

        init?(_ entry: Entry) {
            let source = entry.source as NSString
            let matches = slotPattern.matches(in: entry.source, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { return nil }
            var pattern = "\\A"
            var position = 0
            var names: [String] = []
            for match in matches {
                pattern += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: position, length: match.range.location - position)))
                pattern += "([\\s\\S]*?)"
                names.append(source.substring(with: match.range))
                position = NSMaxRange(match.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: source.substring(from: position)) + "\\z"
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.expression = expression
            self.template = entry.translation
            self.slots = names
            self.translatedArguments = Set(entry.translatedArguments ?? [])
        }

        func translated(_ message: String, localize: (String) -> String) -> String? {
            let source = message as NSString
            guard let match = expression.firstMatch(in: message, range: NSRange(location: 0, length: source.length)) else { return nil }
            // Substitute in the template, never rescan inserted argument text.
            let target = template as NSString
            var output = ""
            var position = 0
            for token in slotPattern.matches(in: template, range: NSRange(location: 0, length: target.length)) {
                output += target.substring(with: NSRange(location: position, length: token.range.location - position))
                let name = target.substring(with: token.range)
                if let index = slots.firstIndex(of: name) {
                    let argument = source.substring(with: match.range(at: index + 1))
                    output += translatedArguments.contains(index) ? localize(argument) : argument
                }
                position = NSMaxRange(token.range)
            }
            return output + target.substring(from: position)
        }
    }

    static let entries: [Entry] = {
        guard let url = OfficeGameResourceBundle.bundle.url(forResource: "SystemMessages.en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }()
    private static let exact = Dictionary(entries.filter { !$0.source.contains("{0}") }.map { ($0.source, $0.translation) }, uniquingKeysWith: { first, _ in first })
    private static let rules = entries.compactMap(Rule.init)

    static func string(_ message: String, languages: [String]) -> String {
        guard OfficeLocalization.languageIdentifier(for: languages) == "en" else { return message }
        if let value = cache.object(forKey: message as NSString) { return value as String }
        let value = string(message, languages: languages, depth: 0)
        let cost = (message.utf16.count + value.utf16.count) * 2
        // Bound retained log data and avoid repeating regex work during view updates.
        if cost <= 65_536 {
            cache.setObject(value as NSString, forKey: message as NSString, cost: cost)
        }
        return value
    }

    private static func string(_ message: String, languages: [String], depth: Int) -> String {
        guard OfficeLocalization.languageIdentifier(for: languages) == "en" else { return message }
        guard depth < 8, message.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) else { return message }
        let localized = OfficeLocalization.string(message, languages: languages)
        if localized != message { return localized }
        if let translated = exact[message] { return translated }
        if let translated = rules.lazy.compactMap({ $0.translated(message, localize: { string($0, languages: languages, depth: depth + 1) }) }).first { return translated }
        // Multi-line stderr remains verbatim except for recognized diagnostic lines.
        if message.contains("\n") {
            return message.components(separatedBy: "\n").map { string($0, languages: languages, depth: depth + 1) }.joined(separator: "\n")
        }
        return message
    }
}

extension OfficeLocalization {
    static func systemMessage(_ message: String) -> String {
        OfficeSystemMessageLocalization.string(message, languages: [usesKorean ? "ko" : "en"])
    }
}
