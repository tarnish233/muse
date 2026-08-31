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

    @Test func unknownContentLengthStillStopsAtStreamingLimit() {
        var accumulator = ImagePreviewController.RemoteDataAccumulator(
            expectedContentLength: -1,
            maxBytes: 3
        )

        let first = accumulator.append(0x01)
        let second = accumulator.append(0x02)
        let third = accumulator.append(0x03)
        let overflow = accumulator.append(0x04)
        #expect(first)
        #expect(second)
        #expect(third)
        #expect(overflow == false)
        #expect(accumulator.data == Data([0x01, 0x02, 0x03]))
    }
}
