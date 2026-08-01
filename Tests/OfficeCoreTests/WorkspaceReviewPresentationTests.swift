// 이 파일은 변경 검토 화면의 작업 기록 분류와 핵심 diff 요약을 검증한다.

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

    func testSummarizesStatusesAndOnlyCountsHunkLines() {
        let source = WorkspaceChangedFile(
            status: "M",
            path: "Sources/App.swift"
        )
        let test = WorkspaceChangedFile(
            status: "A",
            path: "Tests/AppTests.swift"
        )
        let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,2 @@
        -let title = "old"
        +let title = "new"
         let unchanged = true
        \\ No newline at end of file
        diff --git a/Tests/AppTests.swift b/Tests/AppTests.swift
        new file mode 100644
        --- /dev/null
        +++ b/Tests/AppTests.swift
        @@ -0,0 +1,3 @@
        +func testTitle() {}
        +diff --git is content here
        +Binary files are mentioned in test data
        """

        let summary = WorkspaceReviewDiffSummary(
            diff: diff,
            files: [source, test],
            isPartial: false
        )

        XCTAssertEqual(summary.totalAdditions, 4)
        XCTAssertEqual(summary.totalDeletions, 1)
        XCTAssertEqual(summary.statusSummary, "추가 1 · 수정 1")
        XCTAssertEqual(summary.files[0].addedLines, ["let title = \"new\""])
        XCTAssertEqual(summary.files[0].removedLines, ["let title = \"old\""])
        XCTAssertEqual(summary.files[1].additions, 3)
        XCTAssertTrue(
            summary.files[1].addedLines.contains("diff --git is content here")
        )
        XCTAssertNil(summary.files[1].note)
    }

    func testCapsCoreLinesAcrossMultipleHunks() {
        let file = WorkspaceChangedFile(status: "M", path: "App.swift")
        let diff = """
        diff --git a/App.swift b/App.swift
        --- a/App.swift
        +++ b/App.swift
        @@ -1 +1 @@
        -old1
        +new1
        @@ -3,4 +3,4 @@
        -old2
        -old3
        -old4
        -old5
        +new2
        +new3
        +new4
        +new5
        """

        let summary = WorkspaceReviewDiffSummary(
            diff: diff,
            files: [file],
            isPartial: true
        )

        XCTAssertTrue(summary.isPartial)
        XCTAssertEqual(summary.totalAdditions, 5)
        XCTAssertEqual(summary.totalDeletions, 5)
        XCTAssertEqual(summary.files[0].addedLines, ["new1", "new2", "new3", "new4"])
        XCTAssertEqual(summary.files[0].removedLines, ["old1", "old2", "old3", "old4"])
    }

    func testDescribesRenameBinaryAndModeOnlyChanges() {
        let renamed = WorkspaceChangedFile(
            status: "R100",
            path: "New.swift",
            previousPath: "Old.swift"
        )
        let binary = WorkspaceChangedFile(status: "M", path: "icon.png")
        let mode = WorkspaceChangedFile(status: "M", path: "script.sh")
        let diff = """
        diff --git a/Old.swift b/New.swift
        similarity index 100%
        rename from Old.swift
        rename to New.swift
        diff --git a/icon.png b/icon.png
        index 1111111..2222222 100644
        Binary files a/icon.png and b/icon.png differ
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755
        """

        let summary = WorkspaceReviewDiffSummary(
            diff: diff,
            files: [renamed, binary, mode],
            isPartial: false
        )

        XCTAssertEqual(summary.statusSummary, "수정 2 · 이름 변경 1")
        XCTAssertEqual(summary.files[0].note, "파일 이름만 변경되었습니다.")
        XCTAssertEqual(
            summary.files[1].note,
            "바이너리 내용은 화면에서 비교할 수 없습니다."
        )
        XCTAssertEqual(summary.files[2].note, "파일 속성만 변경되었습니다.")
    }

    func testExcludesWorkRecordsAndFallsBackForUnstructuredDiff() {
        let source = WorkspaceChangedFile(status: "M", path: "App.swift")
        let checklist = WorkspaceChangedFile(status: "M", path: "checklist.md")
        let summary = WorkspaceReviewDiffSummary(
            diff: "Binary files before and after differ\n",
            files: [source, checklist],
            isPartial: false
        )

        XCTAssertEqual(summary.files.map(\.file), [source])
        XCTAssertEqual(
            summary.files[0].note,
            "바이너리 내용은 화면에서 비교할 수 없습니다."
        )
    }

    func testTruncatedQuotedPathKeepsPrefixOrderAndMarksMissingSection() {
        let korean = WorkspaceChangedFile(status: "M", path: "한글.swift")
        let later = WorkspaceChangedFile(status: "M", path: "z.swift")
        let diff = """
        diff --git "a/한글.swift" "b/한글.swift"
        --- "a/한글.swift"
        +++ "b/한글.swift"
        @@ -1 +1 @@
        -이전
        +이후
        """

        let summary = WorkspaceReviewDiffSummary(
            diff: diff,
            files: [korean, later],
            isPartial: true
        )

        XCTAssertEqual(summary.files[0].addedLines, ["이후"])
        XCTAssertEqual(summary.files[0].removedLines, ["이전"])
        XCTAssertNil(summary.files[0].note)
        XCTAssertEqual(summary.files[1].additions, 0)
        XCTAssertEqual(
            summary.files[1].note,
            "표시 범위 밖이라 요약할 수 없습니다."
        )
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
