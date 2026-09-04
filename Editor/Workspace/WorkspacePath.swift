import Foundation

/// Canonical filesystem containment used by every workspace feature.
///
/// The directory itself is resolved through symbolic links. For an item we first preserve
/// the final directory entry while resolving its parent, then fall back to resolving the
/// complete target. This keeps a symlink entry that is visibly inside the project addressable
/// by its project-relative name, while also recognizing projects opened through a symlink and
/// preventing copies through a directory symlink back into the source tree.
nonisolated enum WorkspacePath {
    static func contains(_ itemURL: URL, in directoryURL: URL) -> Bool {
        relativePath(from: directoryURL, to: itemURL) != nil
    }

    static func relativePath(from directoryURL: URL, to itemURL: URL) -> String? {
        let directory = fullyResolvedComponents(of: directoryURL)
        guard !directory.isEmpty else { return nil }

        let candidates = [
            componentsPreservingFinalEntry(of: itemURL),
            fullyResolvedComponents(of: itemURL),
        ]
        for item in candidates {
            guard item.count >= directory.count,
                  item.prefix(directory.count).elementsEqual(directory)
            else { continue }
            let relative = item.dropFirst(directory.count)
            return relative.isEmpty ? "." : relative.joined(separator: "/")
        }
        return nil
    }

    private static func fullyResolvedComponents(of url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }

    private static func componentsPreservingFinalEntry(of url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        guard standardized.path != "/" else {
            return fullyResolvedComponents(of: standardized)
        }
        return fullyResolvedComponents(of: standardized.deletingLastPathComponent())
            + [standardized.lastPathComponent]
    }
}
