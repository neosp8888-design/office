// 이 파일은 Markdown에 포함된 로컬 파일 경로를 안전한 파일 URL과 이미지 미리보기로 변환한다.

import CryptoKit
import Foundation

public enum LocalMarkdownResource {
    private static let existingImageExpression = try? NSRegularExpression(
        pattern: #"!\[[^\]\n]*\]\((?:<([^>\n]+)>|([^\s)\n]+))\)"#
    )
    private static let linkedImageExpression = try? NSRegularExpression(
        pattern: #"(?<!!)\[(?!\!)[^\]\n]*\]\((?:<([^>\n]+)>|([^\s)\n]+))\)"#
    )
    private static let bareImageExpression = try? NSRegularExpression(
        pattern: #"((?:file://)?/[^\n`<>]*?\.(?:bmp|gif|heic|jpe?g|png|tiff?|webp))(?=$|[\s`>)\]},;:])"#,
        options: [.caseInsensitive]
    )
    private static let bareVideoExpression = try? NSRegularExpression(
        pattern: #"((?:file://)?/[^\n`<>]*?\.(?:m4v|mov|mp4))(?=$|[\s`>)\]},;:])"#,
        options: [.caseInsensitive]
    )
    private static let generatedImagePreviewExpression =
        try? NSRegularExpression(
            pattern:
                #"(?m)^[\t ]*\[!\[생성 이미지 [0-9]+\]\((?:<[^>\n]+>|[^\s)\n]+)\)\]\((?:<[^>\n]+>|[^\s)\n]+)\)[\t ]*(?:\n|$)"#
        )
    private static let imageIdentityCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 128
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()
    private static let imageExtensions: Set<String> = [
        "bmp",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "png",
        "tif",
        "tiff",
        "webp",
    ]
    private static let videoExtensions: Set<String> = [
        "m4v",
        "mov",
        "mp4",
    ]

    public static func fileURL(from url: URL) -> URL? {
        if url.isFileURL {
            return url.standardizedFileURL
        }

        guard url.scheme == nil, url.path.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: url.path).standardizedFileURL
    }

    public static func imageFileURL(from url: URL) -> URL? {
        imageFileURL(from: url, fallbackDirectory: nil)
    }

    public static func existingFileURL(
        from url: URL,
        fallbackDirectory: URL?
    ) -> URL? {
        guard let requestedURL = fileURL(from: url) else {
            return nil
        }
        if FileManager.default.fileExists(atPath: requestedURL.path) {
            return requestedURL
        }

        guard
            let fallbackDirectory,
            let relativeComponents = worktreeRelativePathComponents(
                in: requestedURL
            )
        else {
            return nil
        }

        let fallbackURL = relativeComponents.reduce(
            fallbackDirectory.standardizedFileURL
        ) { currentURL, component in
            currentURL.appendingPathComponent(component)
        }
        guard FileManager.default.fileExists(atPath: fallbackURL.path) else {
            return nil
        }
        return fallbackURL.standardizedFileURL
    }

    public static func imageFileURL(
        from url: URL,
        fallbackDirectory: URL?
    ) -> URL? {
        guard
            let fileURL = existingFileURL(
                from: url,
                fallbackDirectory: fallbackDirectory
            ),
            imageExtensions.contains(fileURL.pathExtension.lowercased()),
            FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        return fileURL
    }

    public static func videoFileURLs(
        in markdown: String,
        fallbackDirectory: URL?
    ) -> [URL] {
        let linkedVideos = destinations(
            in: markdown,
            expression: linkedImageExpression
        )
        let bareVideos = destinations(
            in: markdown,
            expression: bareVideoExpression
        )

        var includedPaths = Set<String>()
        return (linkedVideos + bareVideos).compactMap { destination in
            guard
                let url = destinationURL(for: destination),
                let fileURL = existingFileURL(
                    from: url,
                    fallbackDirectory: fallbackDirectory
                ),
                videoExtensions.contains(
                    fileURL.pathExtension.lowercased()
                ),
                includedPaths.insert(fileURL.path).inserted
            else {
                return nil
            }
            return fileURL
        }
    }

    public static func imageFileURLs(
        in markdown: String,
        fallbackDirectory: URL?
    ) -> [URL] {
        let embeddedImages = destinations(
            in: markdown,
            expression: existingImageExpression
        )
        let linkedImages = destinations(
            in: markdown,
            expression: linkedImageExpression
        )
        let bareImages = destinations(
            in: markdown,
            expression: bareImageExpression
        )

        var includedIdentities = Set<String>()
        return (linkedImages + embeddedImages + bareImages).compactMap {
            destination in
            guard
                let url = destinationURL(for: destination),
                let fileURL = imageFileURL(
                    from: url,
                    fallbackDirectory: fallbackDirectory
                ),
                includedIdentities.insert(
                    imageContentIdentity(for: fileURL)
                ).inserted
            else {
                return nil
            }
            return fileURL
        }
    }

    public static func removingGeneratedImagePreviews(
        from markdown: String
    ) -> String {
        guard let generatedImagePreviewExpression else {
            return markdown
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        let withoutPreviews = generatedImagePreviewExpression
            .stringByReplacingMatches(
                in: markdown,
                range: range,
                withTemplate: ""
            )
        return withoutPreviews.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func addingLinkedImagePreviews(
        to markdown: String,
        fallbackDirectory: URL? = nil
    ) -> String {
        let existingImages = destinations(
            in: markdown,
            expression: existingImageExpression
        )
        let linkedImages = destinations(
            in: markdown,
            expression: linkedImageExpression
        )
        let bareImages = destinations(
            in: markdown,
            expression: bareImageExpression
        )

        var previewedPaths = Set(
            existingImages.compactMap {
                imagePath(
                    for: $0,
                    fallbackDirectory: fallbackDirectory
                )
            }
        )
        let paths = (linkedImages + bareImages)
            .compactMap {
                imagePath(
                    for: $0,
                    fallbackDirectory: fallbackDirectory
                )
            }
            .filter {
                previewedPaths.insert($0).inserted
            }
        guard !paths.isEmpty else {
            return markdown
        }

        let previews = paths.prefix(8).enumerated().map { index, path in
            let url = URL(fileURLWithPath: path).absoluteString
            return "[![생성 이미지 \(index + 1)](<\(url)>)](<\(url)>)"
        }
        return "\(markdown)\n\n\(previews.joined(separator: "\n\n"))"
    }

    private static func destinations(
        in markdown: String,
        expression: NSRegularExpression?
    ) -> [String] {
        guard let expression else {
            return []
        }

        let range = NSRange(markdown.startIndex..., in: markdown)
        return expression.matches(in: markdown, range: range).compactMap {
            match in
            for index in 1 ..< match.numberOfRanges
            where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: markdown) {
                    return String(markdown[range])
                }
            }
            return nil
        }
    }

    private static func destinationURL(for destination: String) -> URL? {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return URL(string: destination)
    }

    private static func imagePath(
        for destination: String,
        fallbackDirectory: URL?
    ) -> String? {
        destinationURL(for: destination).flatMap {
            imageFileURL(
                from: $0,
                fallbackDirectory: fallbackDirectory
            )
        }?.path
    }

    private static func imageContentIdentity(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let values = try? standardizedURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let size = values?.fileSize ?? 0
        let modifiedAt = values?.contentModificationDate?
            .timeIntervalSince1970 ?? 0
        let cacheKey = "\(standardizedURL.path)|\(size)|\(modifiedAt)"
            as NSString
        if let cached = imageIdentityCache.object(forKey: cacheKey) {
            return cached as String
        }
        guard
            let data = try? Data(
                contentsOf: standardizedURL,
                options: .mappedIfSafe
            )
        else {
            return "path:\(standardizedURL.path)"
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = "\(size):\(digest)"
        imageIdentityCache.setObject(
            identity as NSString,
            forKey: cacheKey,
            cost: cacheKey.length + identity.utf8.count
        )
        return identity
    }

    private static func worktreeRelativePathComponents(
        in url: URL
    ) -> [String]? {
        let components = url.pathComponents
        guard
            let officestraIndex = components.firstIndex(of: ".officestra"),
            components.indices.contains(officestraIndex + 3),
            components[officestraIndex + 1] == "worktrees"
        else {
            return nil
        }

        let relativeStart = officestraIndex + 4
        guard components.indices.contains(relativeStart) else {
            return nil
        }
        return Array(components[relativeStart...])
    }
}
