import Foundation

actor WorkspaceFileOperations {
    private let fileManager = FileManager()

    func copyItems(_ sourceURLs: [URL], into parentURL: URL) throws -> [URL] {
        let parentURL = parentURL.standardizedFileURL
        var isParentDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &isParentDirectory),
              isParentDirectory.boolValue
        else {
            throw WorkspaceOperationError.invalidPasteDestination
        }

        var copiedURLs: [URL] = []
        copiedURLs.reserveCapacity(sourceURLs.count)

        for sourceURL in sourceURLs {
            try Task.checkCancellation()

            let sourceURL = sourceURL.standardizedFileURL
            var isSourceDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isSourceDirectory) else {
                throw CocoaError(.fileNoSuchFile)
            }

            let isSymbolicLink = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            if isSourceDirectory.boolValue,
               !isSymbolicLink,
               WorkspacePath.contains(parentURL, in: sourceURL)
            {
                throw WorkspaceOperationError.cannotCopyFolderIntoItself
            }

            let destinationURL = availableDestination(
                for: sourceURL,
                in: parentURL,
                isDirectory: isSourceDirectory.boolValue
            )
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            copiedURLs.append(destinationURL)
        }

        return copiedURLs
    }

    private func availableDestination(for sourceURL: URL, in parentURL: URL, isDirectory: Bool) -> URL {
        let originalName = sourceURL.lastPathComponent
        let originalDestination = parentURL.appending(
            path: originalName,
            directoryHint: isDirectory ? .isDirectory : .notDirectory
        )
        guard fileManager.fileExists(atPath: originalDestination.path) else {
            return originalDestination
        }

        let pathExtension = isDirectory ? "" : sourceURL.pathExtension
        let baseName = pathExtension.isEmpty
            ? originalName
            : sourceURL.deletingPathExtension().lastPathComponent
        var copyNumber = 1

        while true {
            let suffix = copyNumber == 1 ? " 副本" : " 副本 \(copyNumber)"
            let candidateName = pathExtension.isEmpty
                ? baseName + suffix
                : baseName + suffix + "." + pathExtension
            let candidateURL = parentURL.appending(
                path: candidateName,
                directoryHint: isDirectory ? .isDirectory : .notDirectory
            )
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            copyNumber += 1
        }
    }
}
