import AppKit
import Foundation
import UniformTypeIdentifiers

struct ImportedAttachment {
    let id: UUID
    let fileName: String
    let originalName: String
    let assetURL: URL
}

struct StagedAttachmentDeletion {
    let noteID: UUID
    let stagedURL: URL
}

@MainActor
final class AttachmentService {
    static let maximumImportedImageBytes = 20 * 1024 * 1024

    let rootURL: URL
    private let deletionStagingURL: URL
    private let fileManager: FileManager

    init(storageDirectory: URL, fileManager: FileManager = .default) {
        rootURL = storageDirectory.appendingPathComponent("attachments", isDirectory: true)
        deletionStagingURL = storageDirectory.appendingPathComponent("DeletionStaging", isDirectory: true)
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: deletionStagingURL, withIntermediateDirectories: true)
    }

    func reconcileStagedDeletions(existingNoteIDs: Set<UUID>) {
        guard let children = try? fileManager.contentsOfDirectory(
            at: deletionStagingURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for child in children {
            let idPrefix = String(child.lastPathComponent.prefix(36))
            guard let noteID = UUID(uuidString: idPrefix), existingNoteIDs.contains(noteID) else {
                try? fileManager.removeItem(at: child)
                continue
            }
            let destination = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: child)
            } else {
                try? fileManager.moveItem(at: child, to: destination)
            }
        }
    }

    func importImage(at sourceURL: URL, noteID: UUID) throws -> ImportedAttachment {
        guard let type = UTType(filenameExtension: sourceURL.pathExtension), type.conforms(to: .image) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize <= Self.maximumImportedImageBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return try importImage(data: data, originalName: sourceURL.lastPathComponent, noteID: noteID)
    }

    func importImage(data: Data, originalName: String, noteID: UUID) throws -> ImportedAttachment {
        guard !data.isEmpty, data.count <= Self.maximumImportedImageBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let safeName = (originalName as NSString).lastPathComponent
        guard !safeName.isEmpty, safeName == originalName else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard let type = UTType(filenameExtension: (safeName as NSString).pathExtension),
              type.conforms(to: .image),
              NSImage(data: data) != nil
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let noteDirectory = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: noteDirectory, withIntermediateDirectories: true)

        let attachmentID = UUID()
        let ext = (safeName as NSString).pathExtension.lowercased()
        let fileName = ext.isEmpty ? attachmentID.uuidString : "\(attachmentID.uuidString).\(ext)"
        let destinationURL = noteDirectory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: destinationURL, options: .atomic)

        return ImportedAttachment(
            id: attachmentID,
            fileName: fileName,
            originalName: safeName,
            assetURL: Self.assetURL(noteID: noteID, fileName: fileName)
        )
    }

    func stageDeletion(noteID: UUID) throws -> StagedAttachmentDeletion? {
        let directory = rootURL.appendingPathComponent(noteID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }

        let stagedURL = deletionStagingURL.appendingPathComponent(
            "\(noteID.uuidString)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: directory, to: stagedURL)
        return StagedAttachmentDeletion(noteID: noteID, stagedURL: stagedURL)
    }

    func restoreDeletion(_ deletion: StagedAttachmentDeletion) throws {
        let destination = rootURL.appendingPathComponent(deletion.noteID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: deletion.stagedURL.path) else { return }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: deletion.stagedURL, to: destination)
    }

    func finalizeDeletion(_ deletion: StagedAttachmentDeletion?) {
        guard let deletion else { return }
        try? fileManager.removeItem(at: deletion.stagedURL)
    }

    func removeImportedAttachment(noteID: UUID, fileName: String) {
        let fileURL = rootURL
            .appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        try? fileManager.removeItem(at: fileURL)
    }

    static func assetURL(noteID: UUID, fileName: String) -> URL {
        var components = URLComponents()
        components.scheme = MemoAssetSchemeHandler.scheme
        components.host = noteID.uuidString
        components.path = "/\(fileName)"
        precondition(!fileName.isEmpty && fileName == (fileName as NSString).lastPathComponent)
        guard let url = components.url else { preconditionFailure("Invalid attachment URL") }
        return url
    }
}
