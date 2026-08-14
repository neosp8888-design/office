// 이 파일은 변경 검토 카드에 남겨 둔 파일 목록 분류를 검증한다.

import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
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

    func testDecodesRenamePreviousPath() throws {
        let data = Data(
            #"{"status":"R100","path":"new.md","previousPath":"old.md"}"#.utf8
        )

        let file = try JSONDecoder().decode(WorkspaceChangedFile.self, from: data)

        XCTAssertEqual(file.previousPath, "old.md")
        XCTAssertEqual(file.reviewDisplayPath, "old.md → new.md")
    }

    func testMergedCardHeightDoesNotDependOnDiffPayload() {
        let withoutDiff = makeMergedWorkspace(diff: nil)
        let largeDiff = String(
            repeating: "@@ -1 +1 @@\n-old value\n+new value\n",
            count: 2_000
        )
        let withLargeDiff = makeMergedWorkspace(diff: largeDiff)

        XCTAssertEqual(
            measuredHeight(of: withoutDiff),
            measuredHeight(of: withLargeDiff),
            accuracy: 0.5,
            "병합 완료 카드가 diff 내용 때문에 커지거나 접히면 안 됩니다."
        )
    }

    private func measuredHeight(of workspace: TurnWorkspaceReview) -> CGFloat {
        let panel = WorkspaceReviewPanel(
            turnID: "merged-turn",
            workspace: workspace,
            resolveReview: { _, _ in workspace }
        )
        let controller = NSHostingController(
            rootView: panel.frame(width: 620)
        )
        return controller.sizeThatFits(
            in: NSSize(width: 620, height: 4_000)
        ).height
    }

    private func makeMergedWorkspace(diff: String?) -> TurnWorkspaceReview {
        TurnWorkspaceReview(
            status: .merged,
            repositoryRoot: "/repo",
            worktreePath: "/tmp/worktree",
            executionWorkdir: "/repo/project",
            branchName: "officestra/right-man/task",
            baseBranch: "main",
            baseCommit: "base",
            reviewTree: "review-tree",
            headCommit: "head",
            changedFiles: [
                WorkspaceChangedFile(
                    status: "M",
                    path: "Sources/App.swift"
                )
            ],
            mergedCommit: "merged",
            errorMessage: nil,
            diff: diff,
            diffTruncated: diff == nil ? nil : false,
            automaticApprovalPending: false
        )
    }
}
