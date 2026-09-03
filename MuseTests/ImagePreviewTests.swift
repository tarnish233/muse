import AppKit
import Foundation
import os
import Testing
@testable import MuseKit

@Suite @MainActor struct ImagePreviewTests {
    @Test func loadLeavesMainActorUnderSwift62CallerIsolation() async {
        let observedMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        _ = await ImagePreviewController.load(
            destination: " ",
            baseURL: nil,
            executionProbe: { isMainThread in
                observedMainThread.withLock { $0 = isMainThread }
            }
        )

        #expect(observedMainThread.withLock { $0 } == false)
    }

    @Test func unknownContentLengthStillChecksDownloadedFileLimit() {
        #expect(ImageResolver.remotePayloadExceedsLimit(
            expectedContentLength: -1,
            downloadedFileSize: 4,
            maxBytes: 3
        ))
    }

    @Test(.tags(.networking))
    func transientRemoteFailureRetriesThroughProductionDecodePath() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let downloadedFile = FileManager.default.temporaryDirectory
            .appending(path: "muse-remote-image-\(UUID().uuidString).png")
        try png.write(to: downloadedFile)
        defer { try? FileManager.default.removeItem(at: downloadedFile) }

        let remoteURL = try #require(URL(string: "https://images.example/\(UUID().uuidString).png"))
        let response = try #require(HTTPURLResponse(
            url: remoteURL,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(png.count)",
            ]
        ))
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let result = await ImageResolver.prepareImage(
            url: remoteURL,
            remoteDownloader: { _ in
                let attempt = attempts.withLock { value in
                    value += 1
                    return value
                }
                if attempt == 1 { throw URLError(.networkConnectionLost) }
                return (downloadedFile, response)
            },
            retrySleeper: { _ in }
        )

        let image: NSImage
        switch result {
        case let .ready(readyImage, cacheChanged):
            image = readyImage
            #expect(cacheChanged)
        case .exceedsSizeLimit:
            Issue.record("合法的小图片不应触发大小限制")
            return
        case .failure:
            Issue.record("瞬时断连后应重试并成功解码")
            return
        }
        #expect(attempts.withLock { $0 } == 2)
        #expect(image.size == NSSize(width: 1, height: 1))
        #expect(ImageResolver.cachedImage(url: remoteURL) != nil)
    }

}
