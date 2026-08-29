import Foundation

nonisolated enum WorkspaceTreeLoadOutcome: Sendable {
    case success(nodes: [WorkspaceNode], warnings: [String])
    case failure(String)
    case cancelled
}

/// 文件系统遍历与 SwiftUI 状态隔离：所有递归 I/O 都在这个 actor 上完成，主线程
/// 只接收不可变树快照。新刷新会取消旧任务；遍历每个条目前检查取消状态。
actor WorkspaceTreeLoader {
    private struct LoadResult {
        let nodes: [WorkspaceNode]
        let warnings: [String]
    }

    private let fileSystem: WorkspaceFileSystem

    init(fileSystem: WorkspaceFileSystem) {
        self.fileSystem = fileSystem
    }

    func loadTree(at rootURL: URL) -> WorkspaceTreeLoadOutcome {
        do {
            let result = try loadChildren(of: rootURL.standardizedFileURL)
            return .success(nodes: result.nodes, warnings: result.warnings)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func loadChildren(of directoryURL: URL) throws -> LoadResult {
        try Task.checkCancellation()
        let urls = try fileSystem.contentsOfDirectory(directoryURL)
        var nodes: [WorkspaceNode] = []
        var warnings: [String] = []
        nodes.reserveCapacity(urls.count)

        for url in urls {
            try Task.checkCancellation()
            let metadata: WorkspaceEntryMetadata
            do {
                metadata = try fileSystem.metadata(url)
            } catch {
                warnings.append(error.localizedDescription)
                continue
            }

            if metadata.isDirectory, metadata.isPackage == false {
                do {
                    let childResult = try loadChildren(of: url)
                    nodes.append(WorkspaceNode(url: url, kind: .folder, children: childResult.nodes))
                    warnings.append(contentsOf: childResult.warnings)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 目录本身继续可见，用户仍可在 Finder 中处理权限问题。
                    nodes.append(WorkspaceNode(url: url, kind: .folder, children: nil))
                    warnings.append(error.localizedDescription)
                }
            } else if metadata.isRegularFile {
                nodes.append(WorkspaceNode(url: url, kind: .file, children: nil))
            }
        }

        return LoadResult(nodes: nodes.sorted(by: Self.nodeSort), warnings: warnings)
    }

    private static func nodeSort(_ lhs: WorkspaceNode, _ rhs: WorkspaceNode) -> Bool {
        if lhs.kind != rhs.kind { return lhs.isFolder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
