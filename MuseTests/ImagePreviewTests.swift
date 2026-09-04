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
                return ImageResolver.RemoteDownload(fileURL: downloadedFile, response: response)
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
        case .unavailable:
            Issue.record("瞬时断连后应重试并成功解码")
            return
        }
        #expect(attempts.withLock { $0 } == 2)
        #expect(image.size == NSSize(width: 1, height: 1))
        #expect(ImageResolver.cachedImage(url: remoteURL) != nil)
        #expect(FileManager.default.fileExists(atPath: downloadedFile.path) == false)
    }

    @Test func chunkedAccumulatorRejectsBeforeWritingPastHardLimit() throws {
        let accumulator = try ImageResolver.RemoteDataAccumulator(maxBytes: 3)
        try accumulator.append(Data([0x01, 0x02, 0x03]))

        #expect(throws: ImageResolver.RemoteDownloadError.self) {
            try accumulator.append(Data([0x04]))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: accumulator.fileURL.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 3)

        let fileURL = accumulator.fileURL
        accumulator.discard()
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test(.tags(.networking))
    func mimeRejectionRemovesOwnedDownloadFile() async throws {
        let fileURL = try temporaryDownloadFile(data: Data("not an image".utf8))
        let remoteURL = try #require(URL(string: "https://images.example/\(UUID().uuidString).txt"))
        let response = try response(
            url: remoteURL,
            statusCode: 200,
            mimeType: "text/plain",
            contentLength: 12
        )

        let result = await ImageResolver.prepareImage(
            url: remoteURL,
            remoteDownloader: { _ in
                ImageResolver.RemoteDownload(fileURL: fileURL, response: response)
            },
            retrySleeper: { _ in }
        )

        guard case .unavailable(cacheChanged: false) = result else {
            Issue.record("非图片 MIME 应被拒绝")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test(.tags(.networking))
    func oversizeRejectionRemovesOwnedDownloadFile() async throws {
        let fileURL = try temporaryDownloadFile(data: Data())
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(ImageResolver.maxRemoteBytes + 1))
        try handle.close()
        let remoteURL = try #require(URL(string: "https://images.example/\(UUID().uuidString).png"))
        let response = try response(
            url: remoteURL,
            statusCode: 200,
            mimeType: "image/png",
            contentLength: nil
        )

        let result = await ImageResolver.prepareImage(
            url: remoteURL,
            remoteDownloader: { _ in
                ImageResolver.RemoteDownload(fileURL: fileURL, response: response)
            },
            retrySleeper: { _ in }
        )

        guard case .exceedsSizeLimit = result else {
            Issue.record("未知 Content-Length 的 20MB+1 文件应被下游防线拒绝")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test(.tags(.networking))
    func decodeFailureRemovesOwnedDownloadFile() async throws {
        let fileURL = try temporaryDownloadFile(data: Data("broken image".utf8))
        let remoteURL = try #require(URL(string: "https://images.example/\(UUID().uuidString).png"))
        let response = try response(
            url: remoteURL,
            statusCode: 200,
            mimeType: "image/png",
            contentLength: 12
        )

        let result = await ImageResolver.prepareImage(
            url: remoteURL,
            remoteDownloader: { _ in
                ImageResolver.RemoteDownload(fileURL: fileURL, response: response)
            },
            retrySleeper: { _ in }
        )

        guard case .unavailable(cacheChanged: false) = result else {
            Issue.record("损坏图片应解码失败")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test(.tags(.networking))
    func retryRemovesEveryOwnedDownloadFile() async throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let firstFile = try temporaryDownloadFile(data: png)
        let secondFile = try temporaryDownloadFile(data: png)
        let remoteURL = try #require(URL(string: "https://images.example/\(UUID().uuidString).png"))
        let retryResponse = try response(
            url: remoteURL,
            statusCode: 503,
            mimeType: "image/png",
            contentLength: png.count
        )
        let successResponse = try response(
            url: remoteURL,
            statusCode: 200,
            mimeType: "image/png",
            contentLength: png.count
        )
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let result = await ImageResolver.prepareImage(
            url: remoteURL,
            remoteDownloader: { _ in
                let attempt = attempts.withLock { value in
                    value += 1
                    return value
                }
                return ImageResolver.RemoteDownload(
                    fileURL: attempt == 1 ? firstFile : secondFile,
                    response: attempt == 1 ? retryResponse : successResponse
                )
            },
            retrySleeper: { _ in }
        )

        guard case .ready = result else {
            Issue.record("503 后应重试并成功")
            return
        }
        #expect(attempts.withLock { $0 } == 2)
        #expect(FileManager.default.fileExists(atPath: firstFile.path) == false)
        #expect(FileManager.default.fileExists(atPath: secondFile.path) == false)
    }

    private func temporaryDownloadFile(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "muse-remote-image-\(UUID().uuidString).tmp")
        try data.write(to: url)
        return url
    }

    private func response(
        url: URL,
        statusCode: Int,
        mimeType: String,
        contentLength: Int?
    ) throws -> HTTPURLResponse {
        var headers = ["Content-Type": mimeType]
        if let contentLength {
            headers["Content-Length"] = "\(contentLength)"
        }
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: headers
        ))
    }

}
