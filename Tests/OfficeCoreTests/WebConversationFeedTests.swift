import Foundation
import OfficeCore
import WebKit
import XCTest
@testable import OfficeGame

@MainActor
final class WebConversationFeedTests: XCTestCase {
    func testPageURLUsesBackendOriginAndCharacterQuery() throws {
        let url = try XCTUnwrap(
            WebConversationPageURL.make(
                backendBaseURL: URL(string: "http://127.0.0.1:4317")!,
                characterID: .rightWoman
            )
        )

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.port, 4317)
        XCTAssertEqual(url.path, "/conversation/index.html")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems,
            [URLQueryItem(name: "characterId", value: "right-woman")]
        )
    }

    func testEmployeeWebViewsAreCreatedOnceAndReselectionOnlyUnhides()
        throws
    {
        var loadedRequests: [URLRequest] = []
        let container = WebConversationFeedsNSView { _, request in
            loadedRequests.append(request)
        }
        let baseURL = URL(string: "http://127.0.0.1:4317")!

        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman
        )
        let firstWebView = try XCTUnwrap(
            container.webViewForTesting(characterID: .rightWoman)
        )
        XCTAssertFalse(
            try XCTUnwrap(
                container.isPageHiddenForTesting(characterID: .rightWoman)
            )
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .rightWoman), 1)
        XCTAssertEqual(loadedRequests.count, 1)

        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftWoman
        )
        XCTAssertTrue(
            try XCTUnwrap(
                container.isPageHiddenForTesting(characterID: .rightWoman)
            )
        )
        XCTAssertFalse(
            try XCTUnwrap(
                container.isPageHiddenForTesting(characterID: .leftWoman)
            )
        )
        XCTAssertEqual(loadedRequests.count, 2)

        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman
        )
        XCTAssertTrue(
            firstWebView === container.webViewForTesting(
                characterID: .rightWoman
            )
        )
        XCTAssertFalse(
            try XCTUnwrap(
                container.isPageHiddenForTesting(characterID: .rightWoman)
            )
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .rightWoman), 1)
        XCTAssertEqual(loadedRequests.count, 2)
    }

    func testFirstLoadUsesSmallPlaceholderUntilWebPageSignalsReady()
        throws
    {
        let container = WebConversationFeedsNSView { _, _ in }
        container.configure(
            backendBaseURL: URL(string: "http://127.0.0.1:4317")!,
            selectedCharacterID: .rightMan
        )

        XCTAssertTrue(
            try XCTUnwrap(
                container.isShowingPlaceholderForTesting(
                    characterID: .rightMan
                )
            )
        )
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .rightMan
        )
        XCTAssertFalse(
            try XCTUnwrap(
                container.isShowingPlaceholderForTesting(
                    characterID: .rightMan
                )
            )
        )
    }

    func testReadyCachedEmployeeSignalsReadyImmediatelyOnReturn()
        throws
    {
        var actions: [WebConversationNativeAction] = []
        let container = WebConversationFeedsNSView { _, _ in }
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman,
            actionHandler: { actions.append($0) }
        )
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .rightWoman
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftMan,
            actionHandler: { actions.append($0) }
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman,
            actionHandler: { actions.append($0) }
        )

        XCTAssertEqual(
            actions,
            [
                .ready(characterID: .rightWoman),
                .ready(characterID: .rightWoman),
            ]
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .rightWoman), 1)
        XCTAssertFalse(
            try XCTUnwrap(
                container.isPageHiddenForTesting(characterID: .rightWoman)
            )
        )
    }

    func testNavigationFailureOffersManualRetryForOnlyTheFailedEmployee()
        throws
    {
        var loadedRequests: [(WKWebView, URLRequest)] = []
        let container = WebConversationFeedsNSView { webView, request in
            loadedRequests.append((webView, request))
        }
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightMan
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftMan
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightMan
        )
        XCTAssertEqual(loadedRequests.count, 2)

        container.failNavigationForTesting(
            characterID: .rightMan,
            error: NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotConnectToHost
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(
                container.isShowingRetryForTesting(
                    characterID: .rightMan
                )
            )
        )

        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftMan
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightMan
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .rightMan), 1)
        XCTAssertEqual(container.loadCountForTesting(characterID: .leftMan), 1)
        XCTAssertEqual(loadedRequests.count, 2)

        let failedWebView = try XCTUnwrap(
            container.webViewForTesting(characterID: .rightMan)
        )
        container.retryPageForTesting(characterID: .rightMan)

        XCTAssertFalse(
            try XCTUnwrap(
                container.isShowingRetryForTesting(
                    characterID: .rightMan
                )
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(
                container.isShowingPlaceholderForTesting(
                    characterID: .rightMan
                )
            )
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .rightMan), 2)
        XCTAssertEqual(container.loadCountForTesting(characterID: .leftMan), 1)
        XCTAssertEqual(loadedRequests.count, 3)
        XCTAssertTrue(loadedRequests.last?.0 === failedWebView)
        XCTAssertTrue(
            loadedRequests.last?.1.url?.absoluteString.contains(
                "characterId=right-man"
            ) == true
        )
    }

    func testWebContentTerminationRequiresRetryAndReplaysNativeState()
        throws
    {
        var scripts: [String] = []
        let container = WebConversationFeedsNSView(
            requestLoader: { _, _ in },
            scriptEvaluator: { _, script in scripts.append(script) }
        )
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        let submittedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let optimistic = WebConversationOptimisticTurn(
            id: "local-replay-after-retry",
            characterID: .boss,
            characterName: "백부장",
            prompt: "재시도 뒤에도 보존할 업무",
            startedAt: submittedAt,
            updatedAt: submittedAt
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .boss
        )
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .boss
        )
        container.synchronizeNativeState(
            characterID: .boss,
            optimisticTurns: [optimistic],
            pendingQuestionTurnIDs: ["pending-question"]
        )
        scripts.removeAll()

        container.terminateWebContentProcessForTesting(characterID: .boss)
        XCTAssertTrue(
            try XCTUnwrap(
                container.isShowingRetryForTesting(characterID: .boss)
            )
        )
        XCTAssertEqual(container.loadCountForTesting(characterID: .boss), 1)

        container.retryPageForTesting(characterID: .boss)
        XCTAssertEqual(container.loadCountForTesting(characterID: .boss), 2)
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .boss
        )

        XCTAssertTrue(
            scripts.contains {
                $0.contains("upsertTurn")
                    && $0.contains("local-replay-after-retry")
            }
        )
        XCTAssertTrue(
            scripts.contains {
                $0.contains("setPendingQuestionTurnIds")
                    && $0.contains("pending-question")
            }
        )
    }

    func testBridgeDecodesOnlySafeNativeActions() {
        XCTAssertEqual(
            WebConversationBridgeMessage.decode(["type": "ready"]),
            .ready
        )
        XCTAssertEqual(
            WebConversationBridgeMessage.decode([
                "type": "answerQuestion",
                "text": "선택지 2번으로 진행",
            ]),
            .answerQuestion(text: "선택지 2번으로 진행")
        )
        XCTAssertNil(
            WebConversationBridgeMessage.decode([
                "type": "answerQuestion",
                "text": "  \n",
            ])
        )
        XCTAssertEqual(
            WebConversationBridgeMessage.decode([
                "type": "copy",
                "text": "복사할 내용",
            ]),
            .copy(text: "복사할 내용")
        )
        XCTAssertEqual(
            WebConversationBridgeMessage.decode([
                "type": "openExternal",
                "url": "https://example.com/guide",
            ]),
            .openExternal(url: URL(string: "https://example.com/guide")!)
        )
        XCTAssertEqual(
            WebConversationBridgeMessage.decode([
                "type": "openSource",
                "sourceKind": "file",
                "locator": "Sources/OfficeGame/App.swift:42",
            ]),
            .openSource(
                sourceKind: "file",
                locator: "Sources/OfficeGame/App.swift:42"
            )
        )
        XCTAssertNil(
            WebConversationBridgeMessage.decode([
                "type": "openExternal",
                "url": "file:///tmp/private",
            ])
        )
        XCTAssertNil(WebConversationBridgeMessage.decode(["type": "feedback"]))
    }

    func testSourceTargetAllowsWebAndWorkspaceFileOnly() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceFile = workspace
            .appendingPathComponent("Sources/App.swift", isDirectory: false)
        let outsideFile = fileManager.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).swift")
        try fileManager.createDirectory(
            at: sourceFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            fileManager.createFile(atPath: sourceFile.path, contents: Data())
        )
        XCTAssertTrue(
            fileManager.createFile(atPath: outsideFile.path, contents: Data())
        )
        defer {
            try? fileManager.removeItem(at: workspace)
            try? fileManager.removeItem(at: outsideFile)
        }

        XCTAssertEqual(
            WebConversationSourceTarget.resolve(
                sourceKind: "web",
                locator: "https://example.com/guide",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            ),
            .externalURL(URL(string: "https://example.com/guide")!)
        )
        XCTAssertEqual(
            WebConversationSourceTarget.resolve(
                sourceKind: "file",
                locator: "Sources/App.swift:42-44",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            ),
            .workspaceFile(
                WorkspaceFileRevealTarget(
                    url: sourceFile.standardizedFileURL,
                    selectsItem: true
                )
            )
        )
        XCTAssertNil(
            WebConversationSourceTarget.resolve(
                sourceKind: "file",
                locator: outsideFile.path,
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertNil(
            WebConversationSourceTarget.resolve(
                sourceKind: "file",
                locator: "../outside.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertNil(
            WebConversationSourceTarget.resolve(
                sourceKind: "database",
                locator: "work_records/1",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
    }

    func testAnswerQuestionUsesTheOwningWebViewCharacter() {
        var actions: [WebConversationNativeAction] = []
        let container = WebConversationFeedsNSView { _, _ in }
        container.configure(
            backendBaseURL: URL(string: "http://127.0.0.1:4317")!,
            selectedCharacterID: .leftMan,
            actionHandler: { actions.append($0) }
        )

        container.receiveBridgeMessageForTesting(
            [
                "type": "answerQuestion",
                "characterId": "boss",
                "text": "직접 입력 답변",
            ],
            characterID: .leftMan
        )

        XCTAssertEqual(
            actions,
            [
                .answerQuestion(
                    characterID: .leftMan,
                    text: "직접 입력 답변"
                )
            ]
        )
    }

    func testHiddenEmployeeCannotSendAnAnswer() {
        var actions: [WebConversationNativeAction] = []
        let container = WebConversationFeedsNSView { _, _ in }
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftMan,
            actionHandler: { actions.append($0) }
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .boss,
            actionHandler: { actions.append($0) }
        )

        container.receiveBridgeMessageForTesting(
            [
                "type": "answerQuestion",
                "text": "오래된 숨은 화면의 답변",
            ],
            characterID: .leftMan
        )

        XCTAssertTrue(actions.isEmpty)
    }

    func testPendingQuestionSnapshotWaitsForReadyThenEnablesCurrentComposer() {
        var scripts: [String] = []
        let container = WebConversationFeedsNSView(
            requestLoader: { _, _ in },
            scriptEvaluator: { _, script in scripts.append(script) }
        )
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman
        )
        container.synchronizeNativeState(
            characterID: .rightWoman,
            optimisticTurns: [],
            pendingQuestionTurnIDs: ["completed-needs-input-turn"]
        )
        XCTAssertTrue(scripts.isEmpty)

        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .rightWoman
        )

        XCTAssertTrue(
            scripts.contains {
                $0.contains("setPendingQuestionTurnIds")
                    && $0.contains("completed-needs-input-turn")
            }
        )
    }

    func testFailedOptimisticTurnIsRemoved() {
        var scripts: [String] = []
        let container = WebConversationFeedsNSView(
            requestLoader: { _, _ in },
            scriptEvaluator: { _, script in scripts.append(script) }
        )
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        let submittedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let optimistic = WebConversationOptimisticTurn(
            id: "local-stable-command-id",
            characterID: .rightWoman,
            characterName: "코대리",
            prompt: "새 업무",
            startedAt: submittedAt,
            updatedAt: submittedAt
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman
        )
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .rightWoman
        )
        scripts.removeAll()

        container.synchronizeNativeState(
            characterID: .rightWoman,
            optimisticTurns: [optimistic],
            pendingQuestionTurnIDs: []
        )
        XCTAssertTrue(
            scripts.contains {
                $0.contains("upsertTurn")
                    && $0.contains("local-stable-command-id")
                    && $0.contains("새 업무")
            }
        )
        scripts.removeAll()

        container.synchronizeNativeState(
            characterID: .rightWoman,
            optimisticTurns: [],
            pendingQuestionTurnIDs: []
        )
        XCTAssertTrue(
            scripts.contains {
                $0.contains("removeTurn")
                    && $0.contains("local-stable-command-id")
            }
        )
    }

    func testOptimisticTurnReconcilesToServerIDWithoutRemovingTheCard() {
        var scripts: [String] = []
        let container = WebConversationFeedsNSView(
            requestLoader: { _, _ in },
            scriptEvaluator: { _, script in scripts.append(script) }
        )
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        let submittedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let optimistic = WebConversationOptimisticTurn(
            id: "local-stable-command-id",
            characterID: .rightWoman,
            characterName: "코대리",
            prompt: "새 업무",
            startedAt: submittedAt,
            updatedAt: submittedAt
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightWoman
        )
        container.receiveBridgeMessageForTesting(
            ["type": "ready"],
            characterID: .rightWoman
        )
        container.synchronizeNativeState(
            characterID: .rightWoman,
            optimisticTurns: [optimistic],
            pendingQuestionTurnIDs: []
        )
        scripts.removeAll()

        container.synchronizeNativeState(
            characterID: .rightWoman,
            optimisticTurns: [],
            turnIDReconciliations: [
                WebConversationTurnIDReconciliation(
                    localID: "local-stable-command-id",
                    serverID: "server-turn-id",
                    characterID: .rightWoman
                )
            ],
            pendingQuestionTurnIDs: []
        )

        XCTAssertEqual(
            scripts.filter { $0.contains("reconcileTurnId") }.count,
            1
        )
        XCTAssertTrue(
            scripts.contains {
                $0.contains("reconcileTurnId")
                    && $0.contains("local-stable-command-id")
                    && $0.contains("server-turn-id")
                    && $0.contains("right-woman")
            }
        )
        XCTAssertFalse(scripts.contains { $0.contains("removeTurn") })
    }

    func testNavigationAllowsOnlyCurrentBackendOrigin() {
        let backend = URL(string: "http://127.0.0.1:4317")!

        XCTAssertEqual(
            WebConversationNavigationPolicy.decision(
                for: URL(
                    string: "http://127.0.0.1:4317/conversation/index.html"
                ),
                backendBaseURL: backend,
                opensNewWindow: false
            ),
            .allow
        )
        XCTAssertEqual(
            WebConversationNavigationPolicy.decision(
                for: URL(string: "https://example.com"),
                backendBaseURL: backend,
                opensNewWindow: false
            ),
            .cancel
        )
        XCTAssertEqual(
            WebConversationNavigationPolicy.decision(
                for: URL(
                    string: "http://127.0.0.1:4317/conversation/index.html"
                ),
                backendBaseURL: backend,
                opensNewWindow: true
            ),
            .cancel
        )
    }

    func testVisibilityContractLetsHiddenPagesSuppressHeavyDOMWork() {
        XCTAssertEqual(
            WebConversationVisibilityScript.make(isVisible: true),
            "window.dispatchEvent(new CustomEvent('officestra:visibility', "
                + "{ detail: { visible: true } }));"
        )
        XCTAssertEqual(
            WebConversationVisibilityScript.make(isVisible: false),
            "window.dispatchEvent(new CustomEvent('officestra:visibility', "
                + "{ detail: { visible: false } }));"
        )
    }

    func testTearDownStopsReuseAndRemovesEveryCachedPage() {
        let container = WebConversationFeedsNSView { _, _ in }
        let baseURL = URL(string: "http://127.0.0.1:4317")!
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .boss
        )
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .leftMan
        )
        XCTAssertEqual(container.cachedCharacterIDsForTesting.count, 2)

        container.tearDown()

        XCTAssertTrue(container.cachedCharacterIDsForTesting.isEmpty)
        XCTAssertTrue(container.subviews.isEmpty)
        container.configure(
            backendBaseURL: baseURL,
            selectedCharacterID: .rightMan
        )
        XCTAssertTrue(container.cachedCharacterIDsForTesting.isEmpty)
    }
}
