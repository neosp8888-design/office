import Foundation

struct PendingAttachment: Identifiable, Equatable, Sendable {
    let sourceURL: URL
    let stagedURL: URL

    var id: String {
        sourceURL.standardizedFileURL.path
    }

    var displayName: String {
        sourceURL.lastPathComponent
    }
}

struct AttachmentStagingBatch: Sendable {
    let attachments: [PendingAttachment]
    let errorDescriptions: [String]
}

enum AttachmentInboxError: LocalizedError {
    case unsupportedItem(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedItem(name):
            OfficeLocalization.format("일반 파일만 첨부할 수 있습니다: %@", name)
        }
    }
}

struct AttachmentInbox {
    let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    static func live(
        fileManager: FileManager = .default
    ) throws -> AttachmentInbox {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AttachmentInbox(
            rootDirectory: applicationSupport
                .appending(path: "OFFICESTRA", directoryHint: .isDirectory)
                .appending(
                    path: "AttachmentInbox",
                    directoryHint: .isDirectory
                ),
            fileManager: fileManager
        )
    }

    func stage(_ sourceURL: URL) throws -> PendingAttachment {
        let sourceURL = sourceURL.standardizedFileURL
        let didStartSecurityScope =
            sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            throw AttachmentInboxError.unsupportedItem(
                sourceURL.lastPathComponent
            )
        }

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectory.path
        )
        let itemDirectory = rootDirectory.appending(
            path: UUID().uuidString.lowercased(),
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: itemDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let destinationURL = itemDirectory.appending(
            path: sourceURL.lastPathComponent,
            directoryHint: .notDirectory
        )

        do {
            try fileManager.copyItem(
                at: sourceURL,
                to: destinationURL
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            try? fileManager.removeItem(at: itemDirectory)
            throw error
        }

        return PendingAttachment(
            sourceURL: sourceURL,
            stagedURL: destinationURL
        )
    }

    func stage(_ sourceURLs: [URL]) -> AttachmentStagingBatch {
        var attachments: [PendingAttachment] = []
        var errorDescriptions: [String] = []
        for sourceURL in sourceURLs {
            do {
                attachments.append(try stage(sourceURL))
            } catch {
                errorDescriptions.append(error.localizedDescription)
            }
        }
        return AttachmentStagingBatch(
            attachments: attachments,
            errorDescriptions: errorDescriptions
        )
    }

    func remove(_ attachment: PendingAttachment) {
        let itemDirectory = attachment.stagedURL
            .deletingLastPathComponent()
            .standardizedFileURL
        guard contains(itemDirectory) else {
            return
        }
        try? fileManager.removeItem(at: itemDirectory)
    }

    func removeStaleItems(
        excluding activeAttachments: [PendingAttachment] = [],
        now: Date = Date(),
        maximumAge: TimeInterval = 24 * 60 * 60
    ) {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        let activeItemDirectories = Set(
            activeAttachments.map {
                $0.stagedURL
                    .deletingLastPathComponent()
                    .standardizedFileURL.path
            }
        )
        let cutoff = now.addingTimeInterval(-maximumAge)
        for entry in entries {
            guard
                !activeItemDirectories.contains(
                    entry.standardizedFileURL.path
                )
            else {
                continue
            }
            let modifiedAt = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modifiedAt, modifiedAt < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    private func contains(_ url: URL) -> Bool {
        let rootPath = rootDirectory.path.hasSuffix("/")
            ? rootDirectory.path
            : rootDirectory.path + "/"
        return url.path.hasPrefix(rootPath)
    }
}
