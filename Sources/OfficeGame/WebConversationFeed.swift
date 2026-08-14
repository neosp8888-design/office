// 이 파일은 대화 화면을 SwiftUI 스크롤 트리와 분리해 직원별 WKWebView로 유지한다.

import AppKit
import Foundation
import OfficeCore
import SwiftUI
import WebKit

enum WebConversationNativeAction: Equatable {
    case ready(characterID: OfficeCharacter)
    case answerQuestion(characterID: OfficeCharacter, text: String)
    case copy(text: String)
    case openExternal(url: URL)
    case openSource(sourceKind: String, locator: String)
}

typealias WebConversationNativeActionHandler =
    @MainActor (WebConversationNativeAction) -> Void

enum WebConversationPageURL {
    static func make(
        backendBaseURL: URL,
        characterID: OfficeCharacter
    ) -> URL? {
        let indexURL = backendBaseURL
            .appendingPathComponent("conversation", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
        guard var components = URLComponents(
            url: indexURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(
                name: "characterId",
                value: characterID.rawValue
            )
        ]
        return components.url
    }
}

enum WebConversationNavigationPolicy: Equatable {
    case allow
    case cancel

    static func decision(
        for destinationURL: URL?,
        backendBaseURL: URL,
        opensNewWindow: Bool
    ) -> Self {
        guard !opensNewWindow, let destinationURL else {
            return .cancel
        }
        if destinationURL.absoluteString == "about:blank" {
            return .allow
        }
        guard
            let destination = URLComponents(
                url: destinationURL,
                resolvingAgainstBaseURL: false
            ),
            let backend = URLComponents(
                url: backendBaseURL,
                resolvingAgainstBaseURL: false
            ),
            destination.scheme?.lowercased() == backend.scheme?.lowercased(),
            destination.host?.lowercased() == backend.host?.lowercased(),
            effectivePort(for: destination)
                == effectivePort(for: backend)
        else {
            return .cancel
        }
        return .allow
    }

    private static func effectivePort(
        for components: URLComponents
    ) -> Int? {
        if let port = components.port {
            return port
        }
        switch components.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

enum WebConversationBridgeMessage: Equatable {
    case ready
    case answerQuestion(text: String)
    case copy(text: String)
    case openExternal(url: URL)
    case openSource(sourceKind: String, locator: String)

    static func decode(_ body: Any) -> Self? {
        guard
            let payload = body as? [String: Any],
            let type = payload["type"] as? String
        else {
            return nil
        }
        switch type {
        case "ready":
            return .ready
        case "answerQuestion":
            guard
                let text = payload["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return .answerQuestion(text: text)
        case "copy":
            guard let text = payload["text"] as? String else {
                return nil
            }
            return .copy(text: text)
        case "openExternal":
            guard
                let rawURL = payload["url"] as? String,
                let url = URL(string: rawURL),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                url.host != nil
            else {
                return nil
            }
            return .openExternal(url: url)
        case "openSource":
            guard
                let sourceKind = payload["sourceKind"] as? String,
                !sourceKind.isEmpty,
                let locator = payload["locator"] as? String,
                !locator.isEmpty
            else {
                return nil
            }
            return .openSource(
                sourceKind: sourceKind,
                locator: locator
            )
        default:
            return nil
        }
    }
}

enum WebConversationSourceTarget: Equatable {
    case externalURL(URL)
    case workspaceFile(WorkspaceFileRevealTarget)

    static func resolve(
        sourceKind: String,
        locator: String,
        workspaceDirectory: String,
        fileManager: FileManager = .default
    ) -> Self? {
        switch sourceKind.lowercased() {
        case "web":
            guard
                let components = URLComponents(string: locator),
                let scheme = components.scheme?.lowercased(),
                ["http", "https"].contains(scheme),
                components.user == nil,
                components.password == nil,
                let host = components.host,
                !host.isEmpty,
                let url = components.url
            else {
                return nil
            }
            return .externalURL(url)
        case "file":
            guard !workspaceDirectory.isEmpty else {
                return nil
            }
            let path = filePath(from: locator)
            let workspaceURL = URL(
                fileURLWithPath: workspaceDirectory,
                isDirectory: true
            )
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard
                let requestedURL = WorkspaceFileRevealTarget.fileURL(
                    path: path,
                    workspaceDirectory: workspaceDirectory
                )?.resolvingSymlinksInPath(),
                contains(requestedURL, in: workspaceURL),
                let target = WorkspaceFileRevealTarget.resolve(
                    path: path,
                    workspaceDirectory: workspaceDirectory,
                    fileManager: fileManager
                ),
                contains(
                    target.url.resolvingSymlinksInPath(),
                    in: workspaceURL
                )
            else {
                return nil
            }
            return .workspaceFile(target)
        default:
            return nil
        }
    }

    static func filePath(from locator: String) -> String {
        let components = locator.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count > 1, let suffix = components.last else {
            return locator
        }
        let lineRange = suffix.split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard
            !lineRange.isEmpty,
            lineRange.allSatisfy({
                !$0.isEmpty && $0.allSatisfy(\.isNumber)
            })
        else {
            return locator
        }
        return components.dropLast().joined(separator: ":")
    }

    private static func contains(_ candidate: URL, in directory: URL) -> Bool {
        let directoryPath = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        return candidate.path == directory.path
            || candidate.path.hasPrefix(directoryPath)
    }
}

struct WebConversationOptimisticTurn: Equatable {
    let id: String
    let characterID: OfficeCharacter
    let characterName: String
    let prompt: String
    let response: String
    let status: String
    let needsInput: Bool
    let startedAt: Date
    let updatedAt: Date

    init(
        id: String,
        characterID: OfficeCharacter,
        characterName: String,
        prompt: String,
        response: String = "",
        status: String = "running",
        needsInput: Bool = false,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.characterID = characterID
        self.characterName = characterName
        self.prompt = prompt
        self.response = response
        self.status = status
        self.needsInput = needsInput
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    init?(turn: LiveFeedTurn) {
        guard
            turn.id.hasPrefix("local-"),
            let characterID = OfficeCharacter(rawValue: turn.characterId)
        else {
            return nil
        }
        id = turn.id
        self.characterID = characterID
        characterName = turn.characterName
        prompt = turn.prompt
        response = turn.response
        status = turn.status.rawValue
        needsInput = turn.needsInput
        startedAt = turn.startedAt
        updatedAt = turn.updatedAt
    }

    var jsonObject: [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": id,
            "characterId": characterID.rawValue,
            "characterName": characterName,
            "prompt": prompt,
            "response": response,
            "status": status,
            "needsInput": needsInput,
            "startedAt": formatter.string(from: startedAt),
            "updatedAt": formatter.string(from: updatedAt),
            "activities": [],
            "sources": [],
        ]
    }
}

struct WebConversationTurnIDReconciliation: Equatable {
    let localID: String
    let serverID: String
    let characterID: OfficeCharacter

    init?(
        turn: LiveFeedTurn,
        presentationID: String
    ) {
        guard
            presentationID.hasPrefix("local-"),
            turn.id != presentationID,
            let characterID = OfficeCharacter(rawValue: turn.characterId)
        else {
            return nil
        }
        localID = presentationID
        serverID = turn.id
        self.characterID = characterID
    }

    init(
        localID: String,
        serverID: String,
        characterID: OfficeCharacter
    ) {
        self.localID = localID
        self.serverID = serverID
        self.characterID = characterID
    }
}

enum WebConversationVisibilityScript {
    static func make(isVisible: Bool) -> String {
        "window.dispatchEvent(new CustomEvent("
            + "'officestra:visibility', { detail: { visible: "
            + (isVisible ? "true" : "false")
            + " } }));"
    }
}

@MainActor
struct WebConversationFeeds: NSViewRepresentable {
    @ObservedObject private var characterSelectionStore:
        CharacterSelectionStore
    @ObservedObject private var director: AgentDirector
    @ObservedObject private var liveFeedStore: LiveFeedStore
    private let backendBaseURL: URL
    private let workspaceDirectory: String
    private let actionHandler: WebConversationNativeActionHandler?

    init(
        director: AgentDirector,
        actionHandler: WebConversationNativeActionHandler? = nil
    ) {
        _characterSelectionStore = ObservedObject(
            wrappedValue: director.characterSelectionStore
        )
        _director = ObservedObject(wrappedValue: director)
        _liveFeedStore = ObservedObject(wrappedValue: director.liveFeedStore)
        backendBaseURL = director.databaseBaseURL
        workspaceDirectory = director.workspaceDirectory
        self.actionHandler = { [weak director] action in
            if case let .answerQuestion(characterID, text) = action {
                director?.submit(text, to: characterID)
            }
            actionHandler?(action)
        }
    }

    func makeNSView(context: Context) -> WebConversationFeedsNSView {
        let view = WebConversationFeedsNSView()
        view.configure(
            backendBaseURL: backendBaseURL,
            workspaceDirectory: workspaceDirectory,
            selectedCharacterID:
                characterSelectionStore.selectedCharacterID,
            actionHandler: actionHandler
        )
        synchronizeNativeState(in: view)
        return view
    }

    func updateNSView(
        _ nsView: WebConversationFeedsNSView,
        context: Context
    ) {
        nsView.configure(
            backendBaseURL: backendBaseURL,
            workspaceDirectory: workspaceDirectory,
            selectedCharacterID:
                characterSelectionStore.selectedCharacterID,
            actionHandler: actionHandler
        )
        synchronizeNativeState(in: nsView)
    }

    static func dismantleNSView(
        _ nsView: WebConversationFeedsNSView,
        coordinator: ()
    ) {
        nsView.tearDown()
    }

    private func synchronizeNativeState(
        in view: WebConversationFeedsNSView
    ) {
        guard let characterID = characterSelectionStore.selectedCharacterID else {
            return
        }
        view.synchronizeNativeState(
            characterID: characterID,
            optimisticTurns: liveFeedStore.turns.compactMap {
                WebConversationOptimisticTurn(turn: $0)
            },
            turnIDReconciliations: liveFeedStore.turns.compactMap { turn in
                WebConversationTurnIDReconciliation(
                    turn: turn,
                    presentationID: liveFeedStore.presentationID(
                        forTurnID: turn.id
                    )
                )
            },
            pendingQuestionTurnIDs: director.pendingQuestionTurnIDs[
                characterID
            ].map { [$0] } ?? []
        )
    }
}

@MainActor
final class WebConversationFeedsNSView: NSView {
    typealias RequestLoader = (WKWebView, URLRequest) -> Void
    typealias ScriptEvaluator = (WKWebView, String) -> Void

    private final class Entry {
        let characterID: OfficeCharacter
        let pageView: WebConversationPageView
        let bridge: WebConversationScriptBridge
        let navigationDelegate: WebConversationNavigationDelegate
        var loadCount = 0
        var isReady = false
        var optimisticTurns: [String: WebConversationOptimisticTurn] = [:]
        var sentOptimisticTurns: [String: WebConversationOptimisticTurn] = [:]
        var turnIDReconciliations: [String: String] = [:]
        var pendingQuestionTurnIDs: [String] = []
        var sentPendingQuestionTurnIDs: [String]?

        init(
            characterID: OfficeCharacter,
            pageView: WebConversationPageView,
            bridge: WebConversationScriptBridge,
            navigationDelegate: WebConversationNavigationDelegate
        ) {
            self.characterID = characterID
            self.pageView = pageView
            self.bridge = bridge
            self.navigationDelegate = navigationDelegate
        }
    }

    private static let messageHandlerName = "officestraConversation"

    private let requestLoader: RequestLoader
    private let scriptEvaluator: ScriptEvaluator
    private var entries: [OfficeCharacter: Entry] = [:]
    private var backendBaseURL: URL?
    private var workspaceDirectory = ""
    private var selectedCharacterID: OfficeCharacter?
    private var actionHandler: WebConversationNativeActionHandler?
    private var isTornDown = false

    override init(frame frameRect: NSRect) {
        requestLoader = { webView, request in
            webView.load(request)
        }
        scriptEvaluator = { webView, script in
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        super.init(frame: frameRect)
        configureLayer()
    }

    convenience init(requestLoader: @escaping RequestLoader) {
        self.init(
            frame: .zero,
            requestLoader: requestLoader,
            scriptEvaluator: { webView, script in
                webView.evaluateJavaScript(script, completionHandler: nil)
            }
        )
    }

    convenience init(
        requestLoader: @escaping RequestLoader,
        scriptEvaluator: @escaping ScriptEvaluator
    ) {
        self.init(
            frame: .zero,
            requestLoader: requestLoader,
            scriptEvaluator: scriptEvaluator
        )
    }

    private init(
        frame frameRect: NSRect,
        requestLoader: @escaping RequestLoader,
        scriptEvaluator: @escaping ScriptEvaluator
    ) {
        self.requestLoader = requestLoader
        self.scriptEvaluator = scriptEvaluator
        super.init(frame: frameRect)
        configureLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        backendBaseURL: URL,
        workspaceDirectory: String = "",
        selectedCharacterID: OfficeCharacter?,
        actionHandler: WebConversationNativeActionHandler? = nil
    ) {
        guard !isTornDown else {
            return
        }
        self.actionHandler = actionHandler
        self.workspaceDirectory = workspaceDirectory

        if self.backendBaseURL != backendBaseURL {
            removeAllEntries()
            self.backendBaseURL = backendBaseURL
            self.selectedCharacterID = nil
        }

        guard self.selectedCharacterID != selectedCharacterID else {
            return
        }
        self.selectedCharacterID = selectedCharacterID

        for (characterID, entry) in entries {
            setVisibility(
                characterID == selectedCharacterID,
                for: entry
            )
        }

        guard let selectedCharacterID else {
            return
        }
        let selectedEntry = entry(
            for: selectedCharacterID,
            backendBaseURL: backendBaseURL
        )
        setVisibility(true, for: selectedEntry)
        if selectedEntry.isReady {
            actionHandler?(.ready(characterID: selectedCharacterID))
        }
    }

    func synchronizeNativeState(
        characterID: OfficeCharacter,
        optimisticTurns: [WebConversationOptimisticTurn],
        turnIDReconciliations: [WebConversationTurnIDReconciliation] = [],
        pendingQuestionTurnIDs: [String]
    ) {
        guard
            !isTornDown,
            let backendBaseURL,
            characterID == selectedCharacterID
        else {
            return
        }
        let entry = entry(
            for: characterID,
            backendBaseURL: backendBaseURL
        )
        entry.optimisticTurns = Dictionary(
            uniqueKeysWithValues: optimisticTurns
                .filter { $0.characterID == characterID }
                .map { ($0.id, $0) }
        )
        entry.turnIDReconciliations = Dictionary(
            uniqueKeysWithValues: turnIDReconciliations
                .filter { $0.characterID == characterID }
                .map { ($0.localID, $0.serverID) }
        )
        entry.pendingQuestionTurnIDs = pendingQuestionTurnIDs
        flushNativeStateIfReady(for: entry)
    }

    func tearDown() {
        guard !isTornDown else {
            return
        }
        isTornDown = true
        actionHandler = nil
        selectedCharacterID = nil
        removeAllEntries()
    }

    var cachedCharacterIDsForTesting: Set<OfficeCharacter> {
        Set(entries.keys)
    }

    var selectedCharacterIDForTesting: OfficeCharacter? {
        selectedCharacterID
    }

    func webViewForTesting(
        characterID: OfficeCharacter
    ) -> WKWebView? {
        entries[characterID]?.pageView.webView
    }

    func isPageHiddenForTesting(
        characterID: OfficeCharacter
    ) -> Bool? {
        entries[characterID]?.pageView.isHidden
    }

    func loadCountForTesting(
        characterID: OfficeCharacter
    ) -> Int {
        entries[characterID]?.loadCount ?? 0
    }

    func isShowingPlaceholderForTesting(
        characterID: OfficeCharacter
    ) -> Bool? {
        entries[characterID]?.pageView.isShowingPlaceholder
    }

    func isWebContentHiddenForTesting(
        characterID: OfficeCharacter
    ) -> Bool? {
        entries[characterID]?.pageView.webView.isHidden
    }

    func isShowingRetryForTesting(
        characterID: OfficeCharacter
    ) -> Bool? {
        entries[characterID]?.pageView.isShowingRetry
    }

    func failNavigationForTesting(
        characterID: OfficeCharacter,
        error: Error
    ) {
        guard let entry = entries[characterID] else {
            return
        }
        entry.navigationDelegate.webView(
            entry.pageView.webView,
            didFailProvisionalNavigation: nil,
            withError: error
        )
    }

    func terminateWebContentProcessForTesting(
        characterID: OfficeCharacter
    ) {
        guard let entry = entries[characterID] else {
            return
        }
        entry.navigationDelegate.webViewWebContentProcessDidTerminate(
            entry.pageView.webView
        )
    }

    func retryPageForTesting(characterID: OfficeCharacter) {
        entries[characterID]?.pageView.triggerRetryForTesting()
    }

    func receiveBridgeMessageForTesting(
        _ body: Any,
        characterID: OfficeCharacter
    ) {
        handleBridgeMessage(body, characterID: characterID)
    }

    private func configureLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    private func entry(
        for characterID: OfficeCharacter,
        backendBaseURL: URL
    ) -> Entry {
        if let entry = entries[characterID] {
            return entry
        }

        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .default()

        let bridge = WebConversationScriptBridge(
            characterID: characterID
        ) { [weak self] body, characterID in
            self?.handleBridgeMessage(body, characterID: characterID)
        }
        contentController.add(
            bridge,
            name: Self.messageHandlerName
        )
        contentController.addUserScript(
            WKUserScript(
                source: configurationScript(
                    backendBaseURL: backendBaseURL,
                    characterID: characterID
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        let pageView = WebConversationPageView(webView: webView)
        pageView.setRetryHandler { [weak self] in
            self?.retryFailedPage(characterID: characterID)
        }
        pageView.translatesAutoresizingMaskIntoConstraints = false
        pageView.isHidden = true
        addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pageView.topAnchor.constraint(equalTo: topAnchor),
            pageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let navigationDelegate = WebConversationNavigationDelegate(
            backendBaseURL: backendBaseURL,
            didFail: { [weak self] in
                self?.markPageFailed(characterID: characterID)
            }
        )
        webView.navigationDelegate = navigationDelegate

        let entry = Entry(
            characterID: characterID,
            pageView: pageView,
            bridge: bridge,
            navigationDelegate: navigationDelegate
        )
        entries[characterID] = entry

        loadPage(entry, backendBaseURL: backendBaseURL)
        return entry
    }

    private func loadPage(
        _ entry: Entry,
        backendBaseURL: URL
    ) {
        guard
            let pageURL = WebConversationPageURL.make(
                backendBaseURL: backendBaseURL,
                characterID: entry.characterID
            )
        else {
            markPageFailed(characterID: entry.characterID)
            return
        }

        entry.isReady = false
        entry.pageView.showLoading()
        entry.loadCount += 1
        requestLoader(
            entry.pageView.webView,
            URLRequest(url: pageURL)
        )
    }

    private func markPageFailed(characterID: OfficeCharacter) {
        guard !isTornDown, let entry = entries[characterID] else {
            return
        }
        entry.isReady = false
        entry.pageView.showFailure()
    }

    private func retryFailedPage(characterID: OfficeCharacter) {
        guard
            !isTornDown,
            let backendBaseURL,
            let entry = entries[characterID],
            entry.pageView.isShowingRetry
        else {
            return
        }

        entry.sentOptimisticTurns.removeAll(keepingCapacity: true)
        entry.sentPendingQuestionTurnIDs = nil
        loadPage(entry, backendBaseURL: backendBaseURL)
    }

    private func configurationScript(
        backendBaseURL: URL,
        characterID: OfficeCharacter
    ) -> String {
        let payload: [String: String] = [
            "backendBaseURL": backendBaseURL.absoluteString,
            "characterId": characterID.rawValue,
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
        let json = data.flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        return "window.__OFFICESTRA_CONVERSATION__ = \(json);"
    }

    private func handleBridgeMessage(
        _ body: Any,
        characterID: OfficeCharacter
    ) {
        guard
            !isTornDown,
            entries[characterID] != nil,
            let message = WebConversationBridgeMessage.decode(body)
        else {
            return
        }
        switch message {
        case .ready:
            entries[characterID]?.isReady = true
            entries[characterID]?.pageView.showWebContent()
            if let entry = entries[characterID] {
                notifyWebPageVisibility(for: entry)
                flushNativeStateIfReady(for: entry)
            }
            actionHandler?(.ready(characterID: characterID))
        case let .answerQuestion(text):
            guard selectedCharacterID == characterID else {
                return
            }
            actionHandler?(
                .answerQuestion(
                    characterID: characterID,
                    text: text
                )
            )
        case let .copy(text):
            guard selectedCharacterID == characterID else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            actionHandler?(.copy(text: text))
        case let .openExternal(url):
            guard selectedCharacterID == characterID else {
                return
            }
            NSWorkspace.shared.open(url)
            actionHandler?(.openExternal(url: url))
        case let .openSource(sourceKind, locator):
            guard
                selectedCharacterID == characterID,
                let target = WebConversationSourceTarget.resolve(
                    sourceKind: sourceKind,
                    locator: locator,
                    workspaceDirectory: workspaceDirectory
                )
            else {
                return
            }
            switch target {
            case let .externalURL(url):
                NSWorkspace.shared.open(url)
            case let .workspaceFile(target):
                if target.selectsItem {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        target.url
                    ])
                } else {
                    NSWorkspace.shared.open(target.url)
                }
            }
            actionHandler?(
                .openSource(
                    sourceKind: sourceKind,
                    locator: locator
                )
            )
        }
    }

    private func removeAllEntries() {
        for entry in entries.values {
            let webView = entry.pageView.webView
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController
                .removeScriptMessageHandler(
                    forName: Self.messageHandlerName
            )
            entry.bridge.invalidate()
            entry.pageView.setRetryHandler(nil)
            entry.pageView.removeFromSuperview()
        }
        entries.removeAll(keepingCapacity: false)
    }

    private func setVisibility(_ isVisible: Bool, for entry: Entry) {
        entry.pageView.isHidden = !isVisible
        guard entry.isReady else {
            return
        }
        notifyWebPageVisibility(for: entry)
    }

    private func notifyWebPageVisibility(for entry: Entry) {
        scriptEvaluator(
            entry.pageView.webView,
            WebConversationVisibilityScript.make(
                isVisible: !entry.pageView.isHidden
            )
        )
    }

    private func flushNativeStateIfReady(for entry: Entry) {
        guard entry.isReady else {
            return
        }

        var reconciledLocalIDs = Set<String>()
        for (localID, serverID) in entry.turnIDReconciliations.sorted(
            by: { $0.key < $1.key }
        ) where entry.sentOptimisticTurns[localID] != nil {
            guard
                let localIDJSON = jsonString(localID),
                let serverIDJSON = jsonString(serverID),
                let characterIDJSON = jsonString(
                    entry.characterID.rawValue
                )
            else {
                continue
            }
            scriptEvaluator(
                entry.pageView.webView,
                "window.OFFICESTRAConversation?.reconcileTurnId("
                    + "\(localIDJSON), \(serverIDJSON), "
                    + "\(characterIDJSON));"
            )
            reconciledLocalIDs.insert(localID)
        }

        let removedIDs = Set(entry.sentOptimisticTurns.keys)
            .subtracting(Set(entry.optimisticTurns.keys))
            .subtracting(reconciledLocalIDs)
            .sorted()
        for turnID in removedIDs {
            guard
                let turnIDJSON = jsonString(turnID),
                let characterIDJSON = jsonString(
                    entry.characterID.rawValue
                )
            else {
                continue
            }
            scriptEvaluator(
                entry.pageView.webView,
                "window.OFFICESTRAConversation?.removeTurn("
                    + "\(turnIDJSON), \(characterIDJSON));"
            )
        }

        for turn in entry.optimisticTurns.values.sorted(by: {
            $0.id < $1.id
        }) where entry.sentOptimisticTurns[turn.id] != turn {
            guard let turnJSON = jsonString(turn.jsonObject) else {
                continue
            }
            scriptEvaluator(
                entry.pageView.webView,
                "window.OFFICESTRAConversation?.upsertTurn(\(turnJSON));"
            )
        }
        entry.sentOptimisticTurns = entry.optimisticTurns

        if entry.sentPendingQuestionTurnIDs
            != entry.pendingQuestionTurnIDs
        {
            guard
                let pendingIDsJSON = jsonString(
                    entry.pendingQuestionTurnIDs
                )
            else {
                return
            }
            scriptEvaluator(
                entry.pageView.webView,
                "window.OFFICESTRAConversation?.setPendingQuestionTurnIds("
                    + "\(pendingIDsJSON));"
            )
            entry.sentPendingQuestionTurnIDs =
                entry.pendingQuestionTurnIDs
        }
    }

    private func jsonString(_ object: Any) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            if let string = object as? String,
                let data = try? JSONSerialization.data(
                    withJSONObject: [string]
                ),
                let arrayJSON = String(data: data, encoding: .utf8)
            {
                return String(arrayJSON.dropFirst().dropLast())
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
private final class WebConversationPageView: NSView {
    let webView: WKWebView
    private let placeholder = WebConversationPlaceholderView()

    var isShowingPlaceholder: Bool {
        !placeholder.isHidden
    }

    var isShowingRetry: Bool {
        isShowingPlaceholder && placeholder.isShowingRetry
    }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        // WKWebView가 숨겨지면 requestAnimationFrame이 중단될 수 있다.
        // 준비 신호를 기다리는 동안에도 웹 문서는 계속 렌더링하게 두고,
        // 작은 placeholder만 그 위에 표시한다.
        webView.isHidden = false
        addSubview(webView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalToConstant: 270),
            placeholder.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWebContent() {
        placeholder.isHidden = true
        webView.isHidden = false
    }

    func showLoading() {
        webView.isHidden = false
        placeholder.showLoading()
        placeholder.isHidden = false
    }

    func showFailure() {
        webView.isHidden = true
        placeholder.showFailure()
        placeholder.isHidden = false
    }

    func setRetryHandler(_ handler: (() -> Void)?) {
        placeholder.setRetryHandler(handler)
    }

    func triggerRetryForTesting() {
        placeholder.triggerRetryForTesting()
    }
}

@MainActor
private final class WebConversationPlaceholderView: NSVisualEffectView {
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "대화를 여는 중")
    private let retryButton = NSButton(
        title: "다시 시도",
        target: nil,
        action: nil
    )
    private var retryHandler: (() -> Void)?

    var isShowingRetry: Bool {
        !retryButton.isHidden
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12

        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.startAnimation(nil)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indicator)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.font = .systemFont(ofSize: 11, weight: .medium)
        retryButton.target = self
        retryButton.action = #selector(retryButtonPressed)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: label.trailingAnchor,
                constant: 10
            ),
            retryButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -10
            ),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setRetryHandler(_ handler: (() -> Void)?) {
        retryHandler = handler
    }

    func showLoading() {
        retryButton.isHidden = true
        label.stringValue = "대화를 여는 중"
        indicator.isHidden = false
        indicator.startAnimation(nil)
    }

    func showFailure() {
        indicator.stopAnimation(nil)
        indicator.isHidden = true
        label.stringValue = "대화를 열지 못했습니다"
        retryButton.isHidden = false
    }

    func triggerRetryForTesting() {
        retryButton.performClick(nil)
    }

    @objc
    private func retryButtonPressed() {
        retryHandler?()
    }
}

private final class WebConversationScriptBridge:
    NSObject,
    WKScriptMessageHandler
{
    typealias Receiver = @MainActor (Any, OfficeCharacter) -> Void

    private let characterID: OfficeCharacter
    private var receiver: Receiver?

    init(
        characterID: OfficeCharacter,
        receiver: @escaping Receiver
    ) {
        self.characterID = characterID
        self.receiver = receiver
    }

    func invalidate() {
        receiver = nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        receiver?(message.body, characterID)
    }
}

private final class WebConversationNavigationDelegate:
    NSObject,
    WKNavigationDelegate
{
    private let backendBaseURL: URL
    private let didFail: @MainActor () -> Void

    init(
        backendBaseURL: URL,
        didFail: @escaping @MainActor () -> Void
    ) {
        self.backendBaseURL = backendBaseURL
        self.didFail = didFail
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let policy = WebConversationNavigationPolicy.decision(
            for: navigationAction.request.url,
            backendBaseURL: backendBaseURL,
            opensNewWindow: navigationAction.targetFrame == nil
        )
        decisionHandler(policy == .allow ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        reportFailureUnlessCancelled(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        reportFailureUnlessCancelled(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didFail()
    }

    private func reportFailureUnlessCancelled(_ error: Error) {
        let nsError = error as NSError
        guard
            !(nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled)
        else {
            return
        }
        didFail()
    }
}
