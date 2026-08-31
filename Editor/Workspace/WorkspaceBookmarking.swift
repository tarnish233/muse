import Foundation

struct WorkspaceBookmarkResolution {
    let url: URL
    let isStale: Bool
}

struct WorkspaceBookmarking {
    let create: (URL) throws -> Data
    let resolve: (Data) throws -> WorkspaceBookmarkResolution

    static func live() -> WorkspaceBookmarking {
        WorkspaceBookmarking(
        create: { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolve: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return WorkspaceBookmarkResolution(url: url, isStale: isStale)
        }
        )
    }
}

struct WorkspaceProjectStore {
    let load: () -> Data?
    let save: (Data) throws -> Void
    let backupCorruptData: (Data) throws -> String

    static func userDefaults(_ defaults: UserDefaults, key: String) -> WorkspaceProjectStore {
        WorkspaceProjectStore(
            load: { defaults.data(forKey: key) },
            save: { defaults.set($0, forKey: key) },
            backupCorruptData: { data in
                let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
                let baseKey = "\(key).corrupt-\(timestamp)"
                var backupKey = baseKey
                var suffix = 2
                while defaults.object(forKey: backupKey) != nil {
                    backupKey = "\(baseKey)-\(suffix)"
                    suffix += 1
                }
                defaults.set(data, forKey: backupKey)
                guard defaults.data(forKey: backupKey) == data else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return backupKey
            }
        )
    }
}
