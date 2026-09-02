// Markdown 본문을 하나의 AppKit 텍스트 저장소로 렌더링해 문단과 표를
// 가로질러 끊김 없이 선택할 수 있게 한다.

import AppKit
import OfficeCore
import SwiftUI

struct SelectableMarkdownTextView: NSViewRepresentable {
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let minimumLayoutWidth: CGFloat?

    @Environment(\.colorScheme) private var colorScheme

    init(
        source: String,
        fontSize: CGFloat,
        fileBaseDirectory: String?,
        minimumLayoutWidth: CGFloat? = nil
    ) {
        self.source = source
        self.fontSize = fontSize
        self.fileBaseDirectory = fileBaseDirectory
        self.minimumLayoutWidth = minimumLayoutWidth
    }

    func makeNSView(context: Context) -> SelectableMarkdownDocumentView {
        let view = SelectableMarkdownDocumentView(
            fontSize: fontSize,
            minimumLayoutWidth: minimumLayoutWidth
        )
        apply(to: view)
        return view
    }

    func updateNSView(
        _ nsView: SelectableMarkdownDocumentView,
        context: Context
    ) {
        apply(to: nsView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelectableMarkdownDocumentView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            return nil
        }
        return CGSize(
            width: width,
            height: nsView.heightThatFits(width: width)
        )
    }

    private func apply(to view: SelectableMarkdownDocumentView) {
        view.setMinimumLayoutWidth(minimumLayoutWidth)
        let fallbackDirectory = fileBaseDirectory.flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        }
        view.apply(
            source: source,
            fallbackDirectory: fallbackDirectory,
            isDark: colorScheme == .dark
        )
    }
}

@MainActor
final class SelectableMarkdownDocumentView: NSView, NSTextViewDelegate {
    let textView = NSTextView()
    var linkOpener: ((URL) -> Bool)?

    private let horizontalClipView = SelectableMarkdownHorizontalClipView()
    private let horizontalScroller = NSScroller()
    private let fontSize: CGFloat
    private var minimumLayoutWidth: CGFloat?
    private var source = ""
    private var fallbackDirectory: URL?
    private var isDark = false
    private var measuredHeight = CGFloat.zero
    private var measuredWidth = CGFloat.zero
    private var measuredUsedRect = NSRect.zero
    private var hasValidTextMeasurement = false
    private(set) var textLayoutMeasurementCount = 0
    private(set) var textLayoutCacheHitCount = 0

    init(
        fontSize: CGFloat,
        minimumLayoutWidth: CGFloat? = nil
    ) {
        self.fontSize = fontSize
        self.minimumLayoutWidth = minimumLayoutWidth
        super.init(frame: .zero)
        configureTextView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(measuredHeight, minimumTextHeight)
        )
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else {
            return
        }
        if usesHorizontalViewport {
            horizontalClipView.frame = bounds
        }
        updateTextContainerWidth(layoutWidth(for: bounds.width))
        updateMeasuredHeight()
        updateDocumentFrame()
        updateHorizontalScroller()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let updatedIsDark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        guard updatedIsDark != isDark else {
            return
        }
        apply(
            source: source,
            fallbackDirectory: fallbackDirectory,
            isDark: updatedIsDark
        )
    }

    func apply(
        source: String,
        fallbackDirectory: URL?,
        isDark: Bool
    ) {
        let standardizedDirectory = fallbackDirectory?.standardizedFileURL
        guard
            self.source != source
                || self.fallbackDirectory != standardizedDirectory
                || self.isDark != isDark
        else {
            return
        }

        self.source = source
        self.fallbackDirectory = standardizedDirectory
        self.isDark = isDark
        invalidateTextMeasurement()

        let previousSelection = textView.selectedRange()
        textView.textStorage?.setAttributedString(
            SelectableMarkdownAttributedStringCache.shared.attributedString(
                source: source,
                fontSize: fontSize,
                fallbackDirectory: standardizedDirectory,
                isDark: isDark
            )
        )
        let length = textView.string.utf16.count
        textView.setSelectedRange(
            NSRange(
                location: min(previousSelection.location, length),
                length: min(
                    previousSelection.length,
                    max(0, length - min(previousSelection.location, length))
                )
            )
        )
        updateMeasuredHeight(force: true)
    }

    func setMinimumLayoutWidth(_ width: CGFloat?) {
        let normalized = width.flatMap { $0 > 0 ? $0 : nil }
        guard minimumLayoutWidth != normalized else {
            return
        }
        minimumLayoutWidth = normalized
        updateTextViewEmbedding()
        measuredWidth = 0
        invalidateTextMeasurement()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func heightThatFits(width: CGFloat) -> CGFloat {
        guard width > 0 else {
            return minimumTextHeight
        }
        updateTextContainerWidth(layoutWidth(for: width))
        if hasValidTextMeasurement {
            return max(measuredHeight, minimumTextHeight)
        }
        let height = measuredTextHeight()
        measuredHeight = height
        return height
    }

    private var minimumTextHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender) + ceil(abs(font.descender)) + 2
    }

    private func configureTextView() {
        wantsLayer = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: 100_000,
            height: 100_000
        )
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.delegate = self
        textView.setAccessibilityIdentifier(
            "conversationSelectableMarkdownText"
        )
        horizontalClipView.drawsBackground = false
        horizontalClipView.onHorizontalScroll = { [weak self] in
            self?.updateHorizontalScroller()
        }
        horizontalScroller.controlSize = .small
        horizontalScroller.scrollerStyle = .overlay
        horizontalScroller.target = self
        horizontalScroller.action = #selector(horizontalScrollerChanged(_:))
        horizontalScroller.isHidden = true
        updateTextViewEmbedding()
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = linkURL(from: link) else {
            return false
        }
        if
            let fileURL = LocalMarkdownResource.existingFileURL(
                from: url,
                fallbackDirectory: fallbackDirectory
            )
        {
            if let linkOpener {
                return linkOpener(fileURL)
            }
            if NSWorkspace.shared.open(fileURL) {
                return true
            }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return true
        }
        if LocalMarkdownResource.fileURL(from: url) != nil {
            return true
        }
        return linkOpener?(url) ?? NSWorkspace.shared.open(url)
    }

    private func linkURL(from value: Any) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let string = value as? String {
            return URL(string: string)
        }
        return nil
    }

    private var usesHorizontalViewport: Bool {
        minimumLayoutWidth != nil
    }

    private func updateTextViewEmbedding() {
        if usesHorizontalViewport {
            if horizontalClipView.superview !== self {
                textView.removeFromSuperview()
                horizontalClipView.documentView = textView
                addSubview(horizontalClipView)
                addSubview(horizontalScroller)
            }
        } else if textView.superview !== self {
            horizontalClipView.documentView = nil
            horizontalClipView.removeFromSuperview()
            horizontalScroller.removeFromSuperview()
            addSubview(textView)
        }
    }

    private func updateTextContainerWidth(_ width: CGFloat) {
        guard abs(measuredWidth - width) > 0.5 else {
            return
        }
        measuredWidth = width
        invalidateTextMeasurement()
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: 100_000
        )
    }

    private func layoutWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(viewportWidth, minimumLayoutWidth ?? 0)
    }

    private func updateDocumentFrame() {
        let usedRect = measuredTextUsedRect()
        let layoutWidth = layoutWidth(for: bounds.width)
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(layoutWidth, ceil(usedRect.maxX)),
            height: max(bounds.height, ceil(usedRect.height))
        )
        if usesHorizontalViewport {
            let maximumX = max(
                0,
                textView.frame.width - horizontalClipView.bounds.width
            )
            let currentOrigin = horizontalClipView.bounds.origin
            if currentOrigin.x > maximumX || currentOrigin.x < 0 {
                horizontalClipView.scroll(
                    to: NSPoint(
                        x: min(max(0, currentOrigin.x), maximumX),
                        y: 0
                    )
                )
            }
        }
    }

    private func updateHorizontalScroller() {
        guard usesHorizontalViewport else {
            horizontalScroller.isHidden = true
            return
        }
        let viewportWidth = horizontalClipView.bounds.width
        let documentWidth = textView.frame.width
        let maximumX = max(0, documentWidth - viewportWidth)
        guard maximumX > 0.5, viewportWidth > 0 else {
            horizontalScroller.isHidden = true
            if horizontalClipView.bounds.origin.x != 0 {
                horizontalClipView.scroll(to: .zero)
            }
            return
        }

        let scrollerHeight = NSScroller.scrollerWidth(
            for: .small,
            scrollerStyle: .overlay
        )
        horizontalScroller.frame = NSRect(
            x: 4,
            y: max(0, bounds.height - scrollerHeight),
            width: max(0, bounds.width - 8),
            height: scrollerHeight
        )
        horizontalScroller.knobProportion = min(
            1,
            viewportWidth / documentWidth
        )
        horizontalScroller.doubleValue = Double(
            horizontalClipView.bounds.origin.x / maximumX
        )
        horizontalScroller.isHidden = false
    }

    @objc
    private func horizontalScrollerChanged(_ sender: NSScroller) {
        let maximumX = max(
            0,
            textView.frame.width - horizontalClipView.bounds.width
        )
        horizontalClipView.scroll(
            to: NSPoint(
                x: CGFloat(sender.doubleValue) * maximumX,
                y: 0
            )
        )
        horizontalClipView.onHorizontalScroll?()
    }

    private func measuredTextHeight() -> CGFloat {
        max(
            minimumTextHeight,
            ceil(measuredTextUsedRect().height)
        )
    }

    private func measuredTextUsedRect() -> NSRect {
        if hasValidTextMeasurement {
            return measuredUsedRect
        }
        if
            let cached = SelectableMarkdownLayoutMeasurementCache.shared
                .usedRect(
                    source: source,
                    fontSize: fontSize,
                    fallbackDirectory: fallbackDirectory,
                    isDark: isDark,
                    layoutWidth: measuredWidth
                )
        {
            measuredUsedRect = cached
            hasValidTextMeasurement = true
            textLayoutCacheHitCount += 1
            return cached
        }
        guard
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else {
            return .zero
        }
        layoutManager.ensureLayout(for: textContainer)
        measuredUsedRect = layoutManager.usedRect(for: textContainer)
        hasValidTextMeasurement = true
        textLayoutMeasurementCount += 1
        SelectableMarkdownLayoutMeasurementCache.shared.store(
            measuredUsedRect,
            source: source,
            fontSize: fontSize,
            fallbackDirectory: fallbackDirectory,
            isDark: isDark,
            layoutWidth: measuredWidth
        )
        return measuredUsedRect
    }

    private func invalidateTextMeasurement() {
        hasValidTextMeasurement = false
        measuredUsedRect = .zero
    }

    private func updateMeasuredHeight(force: Bool = false) {
        guard measuredWidth > 0 else {
            return
        }
        if force {
            invalidateTextMeasurement()
        } else if hasValidTextMeasurement {
            return
        }
        let updatedHeight = measuredTextHeight()
        guard force || abs(measuredHeight - updatedHeight) > 0.5 else {
            return
        }
        measuredHeight = updatedHeight
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

@MainActor
final class SelectableMarkdownLayoutMeasurementCache {
    private final class Entry {
        let usedRect: NSRect

        init(usedRect: NSRect) {
            self.usedRect = usedRect
        }
    }

    static let shared = SelectableMarkdownLayoutMeasurementCache()

    private let storage = NSCache<NSString, Entry>()

    private init() {
        storage.countLimit = 160
        storage.totalCostLimit = 512 * 1_024
    }

    func usedRect(
        source: String,
        fontSize: CGFloat,
        fallbackDirectory: URL?,
        isDark: Bool,
        layoutWidth: CGFloat
    ) -> NSRect? {
        guard layoutWidth > 0 else {
            return nil
        }
        return storage.object(
            forKey: key(
                source: source,
                fontSize: fontSize,
                fallbackDirectory: fallbackDirectory,
                isDark: isDark,
                layoutWidth: layoutWidth
            )
        )?.usedRect
    }

    func store(
        _ usedRect: NSRect,
        source: String,
        fontSize: CGFloat,
        fallbackDirectory: URL?,
        isDark: Bool,
        layoutWidth: CGFloat
    ) {
        guard layoutWidth > 0 else {
            return
        }
        storage.setObject(
            Entry(usedRect: usedRect),
            forKey: key(
                source: source,
                fontSize: fontSize,
                fallbackDirectory: fallbackDirectory,
                isDark: isDark,
                layoutWidth: layoutWidth
            ),
            cost: max(1, source.utf8.count / 8)
        )
    }

    func removeAll() {
        storage.removeAllObjects()
    }

    private func key(
        source: String,
        fontSize: CGFloat,
        fallbackDirectory: URL?,
        isDark: Bool,
        layoutWidth: CGFloat
    ) -> NSString {
        [
            source,
            String(format: "%.2f", fontSize),
            fallbackDirectory?.standardizedFileURL.path ?? "",
            isDark ? "dark" : "light",
            String(format: "%.2f", layoutWidth),
        ].joined(separator: "\u{1F}") as NSString
    }
}

@MainActor
private final class SelectableMarkdownHorizontalClipView: NSClipView {
    var onHorizontalScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaX) > 0.1 else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        guard let documentView else {
            return
        }
        let maximumX = max(0, documentView.frame.width - bounds.width)
        let nextX = min(
            max(0, bounds.origin.x - event.scrollingDeltaX),
            maximumX
        )
        scroll(to: NSPoint(x: nextX, y: 0))
        onHorizontalScroll?()
    }
}

struct SelectableMarkdownSegment: Equatable {
    enum Kind: Equatable {
        case prose
        case table(columnCount: Int)
        case codeBlock
    }

    let source: String
    let kind: Kind

    var minimumLayoutWidth: CGFloat? {
        guard case let .table(columnCount) = kind else {
            return nil
        }
        return max(280, CGFloat(columnCount) * 110)
    }
}

enum SelectableMarkdownSegmenter {
    static func split(_ source: String) -> [SelectableMarkdownSegment] {
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var segments: [SelectableMarkdownSegment] = []
        var proseStart = 0
        var index = 0

        while index < lines.count {
            guard let openingFence = fence(in: lines[index]) else {
                index += 1
                continue
            }

            appendProse(
                lines[proseStart..<index],
                to: &segments
            )

            var codeEnd = index + 1
            while codeEnd < lines.count {
                if isClosingFence(
                    lines[codeEnd],
                    matching: openingFence
                ) {
                    codeEnd += 1
                    break
                }
                codeEnd += 1
            }

            segments.append(
                SelectableMarkdownSegment(
                    source: lines[index..<codeEnd].joined(separator: "\n"),
                    kind: .codeBlock
                )
            )
            proseStart = codeEnd
            index = codeEnd
        }

        appendProse(lines[proseStart...], to: &segments)
        if segments.isEmpty {
            return [SelectableMarkdownSegment(source: source, kind: .prose)]
        }
        return segments
    }

    private struct Fence: Equatable {
        let character: Character
        let length: Int
    }

    private static func appendProse(
        _ lines: ArraySlice<String>,
        to segments: inout [SelectableMarkdownSegment]
    ) {
        let source = lines.joined(separator: "\n")
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        segments.append(
            SelectableMarkdownSegment(
                source: source,
                kind: proseKind(in: source)
            )
        )
    }

    private static func proseKind(
        in source: String
    ) -> SelectableMarkdownSegment.Kind {
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var maximumTableColumnCount: Int?
        var index = 0

        while index < lines.count {
            guard
                lines.indices.contains(index + 1),
                let columnCount = tableColumnCount(
                    header: lines[index],
                    delimiter: lines[index + 1]
                )
            else {
                index += 1
                continue
            }

            maximumTableColumnCount = max(
                maximumTableColumnCount ?? 0,
                columnCount
            )
            var tableEnd = index + 2
            while tableEnd < lines.count {
                let line = lines[tableEnd]
                guard
                    !line.trimmingCharacters(in: .whitespaces).isEmpty,
                    tableCells(in: line) != nil
                else {
                    break
                }
                tableEnd += 1
            }
            index = tableEnd
        }

        let kind = maximumTableColumnCount.map {
            SelectableMarkdownSegment.Kind.table(columnCount: $0)
        } ?? .prose
        return kind
    }

    private static func tableColumnCount(
        header: String,
        delimiter: String
    ) -> Int? {
        guard
            let headerCells = tableCells(in: header),
            let delimiterCells = tableCells(in: delimiter),
            !headerCells.isEmpty,
            headerCells.count == delimiterCells.count,
            delimiterCells.allSatisfy({ cell in
                cell.range(
                    of: #"^:?-{3,}:?$"#,
                    options: .regularExpression
                ) != nil
            })
        else {
            return nil
        }
        return headerCells.count
    }

    private static func tableCells(in line: String) -> [String]? {
        var cells = [""]
        var foundPipe = false
        var isEscaped = false

        for character in line {
            if isEscaped {
                cells[cells.count - 1].append(character)
                isEscaped = false
            } else if character == "\\" {
                cells[cells.count - 1].append(character)
                isEscaped = true
            } else if character == "|" {
                foundPipe = true
                cells.append("")
            } else {
                cells[cells.count - 1].append(character)
            }
        }

        guard foundPipe else {
            return nil
        }
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeFirst()
        }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            cells.removeLast()
        }
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func fence(in line: String) -> Fence? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let prefixLength = trimmed.prefix { $0 == first }.count
        guard prefixLength >= 3 else {
            return nil
        }
        return Fence(character: first, length: prefixLength)
    }

    private static func isClosingFence(
        _ line: String,
        matching openingFence: Fence
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefixLength = trimmed.prefix {
            $0 == openingFence.character
        }.count
        guard prefixLength >= openingFence.length else {
            return false
        }
        return trimmed.dropFirst(prefixLength)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }
}

@MainActor
final class SelectableMarkdownAttributedStringCache {
    private final class Entry {
        let attributedString: NSAttributedString

        init(attributedString: NSAttributedString) {
            self.attributedString = attributedString
        }
    }

    static let shared = SelectableMarkdownAttributedStringCache()

    private let storage = NSCache<NSString, Entry>()

    private init() {
        storage.countLimit = 80
        storage.totalCostLimit = 12 * 1_024 * 1_024
    }

    func attributedString(
        source: String,
        fontSize: CGFloat,
        fallbackDirectory: URL?,
        isDark: Bool
    ) -> NSAttributedString {
        let key = [
            source,
            String(format: "%.2f", fontSize),
            fallbackDirectory?.path ?? "",
            isDark ? "dark" : "light",
        ].joined(separator: "\u{1F}") as NSString
        if let cached = storage.object(forKey: key) {
            return cached.attributedString
        }

        let attributedString = SelectableMarkdownAttributedRenderer.render(
            source: source,
            fontSize: fontSize,
            fallbackDirectory: fallbackDirectory,
            isDark: isDark
        )
        storage.setObject(
            Entry(attributedString: attributedString),
            forKey: key,
            cost: max(1, attributedString.length * 4)
        )
        return attributedString
    }
}

enum SelectableMarkdownAttributedRenderer {
    private struct TableCellDescriptor {
        let tableIdentity: Int
        let columnCount: Int
        let rowIndex: Int
        let columnIndex: Int
        let isHeader: Bool
        let alignment: PresentationIntent.TableColumn.Alignment
    }

    private struct BlockDescriptor {
        let identity: Int
        let headerLevel: Int?
        let codeLanguage: String?
        let isCodeBlock: Bool
        let isBlockQuote: Bool
        let listItemIdentity: Int?
        let listItemOrdinal: Int?
        let isOrderedList: Bool
        let indentationLevel: Int
        let tableCell: TableCellDescriptor?

        init(_ intent: PresentationIntent?) {
            let components = intent?.components ?? []
            identity = components.first?.identity ?? 0
            indentationLevel = intent?.indentationLevel ?? 0

            var headerLevel: Int?
            var codeLanguage: String?
            var isCodeBlock = false
            var isBlockQuote = false
            var listItemIdentity: Int?
            var listItemOrdinal: Int?
            var isOrderedList = false
            var tableIdentity: Int?
            var tableColumns: [PresentationIntent.TableColumn] = []
            var tableRowIndex: Int?
            var tableColumnIndex: Int?
            var isTableHeader = false

            for component in components {
                switch component.kind {
                case let .header(level):
                    headerLevel = level
                case let .codeBlock(languageHint):
                    isCodeBlock = true
                    codeLanguage = languageHint
                case .blockQuote:
                    isBlockQuote = true
                case .orderedList:
                    isOrderedList = true
                case .unorderedList:
                    break
                case let .listItem(ordinal):
                    listItemIdentity = component.identity
                    listItemOrdinal = ordinal
                case let .table(columns):
                    tableIdentity = component.identity
                    tableColumns = columns
                case .tableHeaderRow:
                    tableRowIndex = 0
                    isTableHeader = true
                case let .tableRow(rowIndex):
                    tableRowIndex = rowIndex
                case let .tableCell(columnIndex):
                    tableColumnIndex = columnIndex
                case .paragraph, .thematicBreak:
                    break
                @unknown default:
                    break
                }
            }

            self.headerLevel = headerLevel
            self.codeLanguage = codeLanguage
            self.isCodeBlock = isCodeBlock
            self.isBlockQuote = isBlockQuote
            self.listItemIdentity = listItemIdentity
            self.listItemOrdinal = listItemOrdinal
            self.isOrderedList = isOrderedList

            if
                let tableIdentity,
                let tableRowIndex,
                let tableColumnIndex
            {
                let alignment = tableColumns.indices.contains(tableColumnIndex)
                    ? tableColumns[tableColumnIndex].alignment
                    : .left
                tableCell = TableCellDescriptor(
                    tableIdentity: tableIdentity,
                    columnCount: max(1, tableColumns.count),
                    rowIndex: tableRowIndex,
                    columnIndex: tableColumnIndex,
                    isHeader: isTableHeader,
                    alignment: alignment
                )
            } else {
                tableCell = nil
            }
        }
    }

    static func render(
        source: String,
        fontSize: CGFloat,
        fallbackDirectory: URL?,
        isDark: Bool
    ) -> NSAttributedString {
        let trimmed = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let markdown = trimmed.isEmpty ? "내용 없음" : trimmed
        let markdownWithVisibleLineBreaks = preservingVisibleLineBreaks(
            in: markdown
        )
        guard
            let parsed = try? AttributedString(
                markdown: markdownWithVisibleLineBreaks,
                options: .init(interpretedSyntax: .full),
                baseURL: fallbackDirectory
            )
        else {
            return fallback(
                markdown,
                fontSize: fontSize,
                isDark: isDark
            )
        }

        let output = NSMutableAttributedString()
        var previousBlockIdentity: Int?
        var previousAttributes: [NSAttributedString.Key: Any]?
        var prefixedListItems = Set<Int>()
        var textTables: [Int: NSTextTable] = [:]

        for run in parsed.runs {
            let descriptor = BlockDescriptor(run.presentationIntent)
            let attributes = attributes(
                descriptor: descriptor,
                inlineIntent: run.inlinePresentationIntent,
                link: run.link,
                imageURL: run.imageURL,
                fontSize: fontSize,
                isDark: isDark,
                textTables: &textTables
            )

            if previousBlockIdentity != descriptor.identity {
                appendParagraphBoundary(
                    to: output,
                    attributes: previousAttributes ?? attributes
                )
                if
                    let listItemIdentity = descriptor.listItemIdentity,
                    prefixedListItems.insert(listItemIdentity).inserted
                {
                    let marker = descriptor.isOrderedList
                        ? "\(descriptor.listItemOrdinal ?? 1).\t"
                        : "•\t"
                    output.append(
                        NSAttributedString(
                            string: marker,
                            attributes: attributes
                        )
                    )
                }
            }

            output.append(
                NSAttributedString(
                    string: String(parsed.characters[run.range]),
                    attributes: attributes
                )
            )
            previousBlockIdentity = descriptor.identity
            previousAttributes = attributes
        }

        appendParagraphBoundary(
            to: output,
            attributes: previousAttributes ?? baseAttributes(
                fontSize: fontSize,
                isDark: isDark
            )
        )
        return output
    }

    // Foundation Markdown은 같은 문단 안의 단일 줄바꿈을 공백으로
    // 접는다. 대화 원문은 사용자가 입력한 줄 구분 자체가 의미가 있으므로
    // fenced code를 제외한 줄 끝을 Markdown hard break로 보존한다.
    private static func preservingVisibleLineBreaks(in source: String) -> String {
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard lines.count > 1 else {
            return source
        }

        var output: [String] = []
        output.reserveCapacity(lines.count)
        var openFence: Character?

        for (index, line) in lines.enumerated() {
            let fence = markdownFenceCharacter(in: line)
            let wasInsideFence = openFence != nil

            if let fence {
                if openFence == fence {
                    openFence = nil
                } else if openFence == nil {
                    openFence = fence
                }
            }

            guard index < lines.count - 1 else {
                output.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let alreadyHardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            if
                !wasInsideFence,
                fence == nil,
                !trimmed.isEmpty,
                !alreadyHardBreak
            {
                output.append(line + "  ")
            } else {
                output.append(line)
            }
        }

        return output.joined(separator: "\n")
    }

    private static func markdownFenceCharacter(in line: String) -> Character? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        return trimmed.prefix { $0 == first }.count >= 3 ? first : nil
    }

    private static func appendParagraphBoundary(
        to output: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard output.length > 0, !output.string.hasSuffix("\n") else {
            return
        }
        output.append(
            NSAttributedString(string: "\n", attributes: attributes)
        )
    }

    private static func attributes(
        descriptor: BlockDescriptor,
        inlineIntent: InlinePresentationIntent?,
        link: URL?,
        imageURL: URL?,
        fontSize: CGFloat,
        isDark: Bool,
        textTables: inout [Int: NSTextTable]
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes(
            fontSize: fontSize,
            isDark: isDark
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = descriptor.tableCell == nil ? 9 : 0
        paragraphStyle.lineBreakMode = .byWordWrapping

        var font = NSFont.systemFont(ofSize: fontSize)
        if let headerLevel = descriptor.headerLevel {
            let scale: CGFloat
            switch headerLevel {
            case 1:
                scale = 1.65
            case 2:
                scale = 1.42
            case 3:
                scale = 1.22
            default:
                scale = 1.08
            }
            font = NSFont.systemFont(
                ofSize: fontSize * scale,
                weight: .bold
            )
            paragraphStyle.paragraphSpacingBefore = 5
            paragraphStyle.paragraphSpacing = 7
        }

        if descriptor.isCodeBlock || inlineIntent?.contains(.code) == true {
            font = NSFont.monospacedSystemFont(
                ofSize: fontSize,
                weight: .regular
            )
            attributes[.backgroundColor] = isDark
                ? NSColor.white.withAlphaComponent(0.07)
                : NSColor.black.withAlphaComponent(0.055)
            if descriptor.isCodeBlock {
                paragraphStyle.paragraphSpacing = 12
            }
        }

        if
            inlineIntent?.contains(.stronglyEmphasized) == true
                || descriptor.tableCell?.isHeader == true
        {
            font = NSFontManager.shared.convert(
                font,
                toHaveTrait: .boldFontMask
            )
        }
        if inlineIntent?.contains(.emphasized) == true {
            font = NSFontManager.shared.convert(
                font,
                toHaveTrait: .italicFontMask
            )
        }
        if inlineIntent?.contains(.strikethrough) == true {
            attributes[.strikethroughStyle] =
                NSUnderlineStyle.single.rawValue
        }

        if let listItemIdentity = descriptor.listItemIdentity {
            _ = listItemIdentity
            let indent = CGFloat(max(1, descriptor.indentationLevel)) * 18
            paragraphStyle.firstLineHeadIndent = max(0, indent - 18)
            paragraphStyle.headIndent = indent
            paragraphStyle.tabStops = [
                NSTextTab(
                    textAlignment: .left,
                    location: indent,
                    options: [:]
                )
            ]
        }

        if descriptor.isBlockQuote {
            let indent = CGFloat(max(1, descriptor.indentationLevel)) * 12
            paragraphStyle.firstLineHeadIndent = indent
            paragraphStyle.headIndent = indent
            attributes[.foregroundColor] = isDark
                ? NSColor.white.withAlphaComponent(0.68)
                : NSColor.secondaryLabelColor
        }

        if let tableCell = descriptor.tableCell {
            let table: NSTextTable
            if let existing = textTables[tableCell.tableIdentity] {
                table = existing
            } else {
                let created = NSTextTable()
                created.numberOfColumns = tableCell.columnCount
                created.collapsesBorders = true
                created.hidesEmptyCells = false
                created.setContentWidth(
                    100,
                    type: .percentageValueType
                )
                textTables[tableCell.tableIdentity] = created
                table = created
            }
            let block = NSTextTableBlock(
                table: table,
                startingRow: tableCell.rowIndex,
                rowSpan: 1,
                startingColumn: tableCell.columnIndex,
                columnSpan: 1
            )
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(
                isDark
                    ? NSColor.white.withAlphaComponent(0.20)
                    : NSColor.black.withAlphaComponent(0.18)
            )
            block.setWidth(6, type: .absoluteValueType, for: .padding)
            if tableCell.isHeader || tableCell.rowIndex.isMultiple(of: 2) {
                block.backgroundColor = isDark
                    ? NSColor.white.withAlphaComponent(0.055)
                    : NSColor.black.withAlphaComponent(0.035)
            }
            paragraphStyle.textBlocks = [block]
            switch tableCell.alignment {
            case .left:
                paragraphStyle.alignment = .left
            case .center:
                paragraphStyle.alignment = .center
            case .right:
                paragraphStyle.alignment = .right
            @unknown default:
                paragraphStyle.alignment = .left
            }
        }

        attributes[.font] = font
        attributes[.paragraphStyle] = paragraphStyle
        if let link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.systemBlue
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if imageURL != nil {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return attributes
    }

    private static func baseAttributes(
        fontSize: CGFloat,
        isDark: Bool
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: isDark
                ? NSColor.white.withAlphaComponent(0.92)
                : NSColor.labelColor,
        ]
    }

    private static func fallback(
        _ markdown: String,
        fontSize: CGFloat,
        isDark: Bool
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 9
        var attributes = baseAttributes(
            fontSize: fontSize,
            isDark: isDark
        )
        attributes[.paragraphStyle] = paragraphStyle
        return NSAttributedString(string: markdown, attributes: attributes)
    }
}
