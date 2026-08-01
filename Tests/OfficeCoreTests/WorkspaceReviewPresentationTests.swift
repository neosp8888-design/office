// 이 파일은 변경 검토 화면의 작업 기록 분류와 diff 접힘 구간을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class WorkspaceReviewPresentationTests: XCTestCase {
    func testSeparatesOnlyRoutineRootWorkRecords() {
        let source = WorkspaceChangedFile(
            status: "M",
            path: "Sources/App.swift"
        )
        let checklist = WorkspaceChangedFile(
            status: "M",
            path: "checklist.md"
        )
        let contextNotes = WorkspaceChangedFile(
            status: "A",
            path: "context-notes.md"
        )
        let nestedChecklist = WorkspaceChangedFile(
            status: "M",
            path: "docs/checklist.md"
        )
        let renamedIntoChecklist = WorkspaceChangedFile(
            status: "R100",
            path: "checklist.md",
            previousPath: "release-notes.md"
        )
        let renamedBetweenWorkRecords = WorkspaceChangedFile(
            status: "R100",
            path: "context-notes.md",
            previousPath: "checklist.md"
        )

        let groups = WorkspaceReviewFileGroups(
            files: [
                checklist,
                source,
                contextNotes,
                nestedChecklist,
                renamedIntoChecklist,
                renamedBetweenWorkRecords,
            ]
        )

        XCTAssertEqual(
            groups.primary,
            [source, nestedChecklist, renamedIntoChecklist]
        )
        XCTAssertEqual(
            groups.workRecords,
            [checklist, contextNotes, renamedBetweenWorkRecords]
        )
        XCTAssertEqual(
            renamedIntoChecklist.reviewDisplayPath,
            "release-notes.md → checklist.md"
        )
    }

    func testSeparatesRoutineWorkRecordDiffSections() {
        let checklist = diffSection(
            path: "checklist.md",
            addedLine: "- [x] 확인"
        )
        let source = diffSection(
            path: "Sources/App.swift",
            addedLine: "let value = true"
        )
        let contextNotes = diffSection(
            path: "context-notes.md",
            addedLine: "- 결과 기록"
        )
        let nestedChecklist = diffSection(
            path: "docs/checklist.md",
            addedLine: "- 사용자 문서"
        )
        let groups = WorkspaceReviewDiffGroups(
            diff: [checklist, source, contextNotes, nestedChecklist]
                .joined(separator: "\n")
        )

        XCTAssertEqual(
            groups.primary,
            [source, nestedChecklist].joined(separator: "\n")
        )
        XCTAssertEqual(
            groups.workRecords,
            [checklist, contextNotes].joined(separator: "\n")
        )
    }

    func testKeepsUnstructuredDiffVisible() {
        let diff = "Binary files before and after differ\n"
        let groups = WorkspaceReviewDiffGroups(diff: diff)

        XCTAssertEqual(groups.primary, diff)
        XCTAssertTrue(groups.workRecords.isEmpty)
    }

    func testDecodesRenamePreviousPath() throws {
        let data = Data(
            #"{"status":"R100","path":"new.md","previousPath":"old.md"}"#.utf8
        )

        let file = try JSONDecoder().decode(WorkspaceChangedFile.self, from: data)

        XCTAssertEqual(file.previousPath, "old.md")
        XCTAssertEqual(file.reviewDisplayPath, "old.md → new.md")
    }

    private func diffSection(path: String, addedLine: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        index 1111111..2222222 100644
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1 @@
        +\(addedLine)
        """
    }
}
