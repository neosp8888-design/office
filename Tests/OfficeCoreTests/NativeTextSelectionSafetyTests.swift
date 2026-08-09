import Foundation
import XCTest

final class NativeTextSelectionSafetyTests: XCTestCase {
    func testOfficeGameDoesNotCreateSwiftUISelectionOverlays() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectRoot
            .appending(path: "Sources/OfficeGame", directoryHint: .isDirectory)
        let forbiddenModifier = ".textSelection("

        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("OfficeGame 소스 폴더를 열지 못했습니다: \(sourceRoot.path)")
            return
        }

        let swiftFiles = enumerator.compactMap { item -> URL? in
            guard
                let url = item as? URL,
                url.pathExtension == "swift"
            else {
                return nil
            }
            return url
        }
        XCTAssertGreaterThan(swiftFiles.count, 20)

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let compactSource = source.filter { !$0.isWhitespace }
            XCTAssertFalse(
                compactSource.contains(forbiddenModifier),
                "macOS SelectionOverlay가 직원 전환 직후 스크롤과 겹치면 "
                    + "AttributeGraph CPU 루프를 만들 수 있습니다: "
                    + file.path
            )
        }
    }
}
