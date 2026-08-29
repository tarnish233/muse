import Foundation

struct WorkspaceEntryMetadata {
    let isDirectory: Bool
    let isRegularFile: Bool
    let isPackage: Bool
}

struct WorkspaceFileSystem {
    let contentsOfDirectory: (URL) throws -> [URL]
    let metadata: (URL) throws -> WorkspaceEntryMetadata

    static func live(fileManager: FileManager) -> WorkspaceFileSystem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        return WorkspaceFileSystem(
            contentsOfDirectory: { directoryURL in
                try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            },
            metadata: { url in
                let values = try url.resourceValues(forKeys: keys)
                return WorkspaceEntryMetadata(
                    isDirectory: values.isDirectory == true,
                    isRegularFile: values.isRegularFile == true,
                    isPackage: values.isPackage == true
                )
            }
        )
    }
}
