// 이 파일은 Markdown에 포함된 로컬 파일 경로를 안전한 파일 URL과 이미지 미리보기로 변환한다.

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
        guard
            let fileURL = fileURL(from: url),
            imageExtensions.contains(fileURL.pathExtension.lowercased()),
            FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        return fileURL
    }

    public static func addingLinkedImagePreviews(
        to markdown: String
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
            existingImages.compactMap(imagePath(for:))
        )
        let paths = (linkedImages + bareImages)
            .compactMap(imagePath(for:))
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

    private static func imagePath(for destination: String) -> String? {
        let url: URL?
        if destination.hasPrefix("/") {
            url = URL(fileURLWithPath: destination)
        } else {
            url = URL(string: destination)
        }
        return url.flatMap(imageFileURL(from:))?.path
    }
}
