import Foundation
import Testing

@Suite @MainActor struct DocumentOpenStateMachineTests {
    private let current = URL(fileURLWithPath: "/tmp/current.md")
    private let first = URL(fileURLWithPath: "/tmp/first.md")
    private let second = URL(fileURLWithPath: "/tmp/second.md")
    private let third = URL(fileURLWithPath: "/tmp/third.md")

    @Test func latestRequestDuringCloseCheckIsTheOnlyURLOpened() throws {
        let machine = DocumentOpenStateMachine()
        let firstCheck = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))

        #expect(machine.requestOpen(at: second, currentURL: current) == .none)
        let opened = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: firstCheck.generation,
            currentURL: current
        )))

        #expect(opened.url == second.standardizedFileURL)
        #expect(opened.generation == 2)
    }

    @Test func requestDuringOpenMakesOldSuccessStale() throws {
        let machine = DocumentOpenStateMachine()
        let checked = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        let opened = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: checked.generation,
            currentURL: current
        )))
        #expect(machine.requestOpen(at: second, currentURL: current) == .none)

        let decision = machine.openCompleted(
            generation: opened.generation,
            result: .init(succeeded: true, wasAlreadyOpen: false, isSupportedDocument: true),
            currentURL: current
        )

        #expect(decision.disposition == .discardNewDocument)
        let next = try #require(checkRequest(decision.next))
        #expect(next.url == second.standardizedFileURL)
    }

    @Test func staleFailureDoesNotPresentError() throws {
        let machine = DocumentOpenStateMachine()
        let checked = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        let opened = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: checked.generation,
            currentURL: current
        )))
        #expect(machine.requestOpen(at: second, currentURL: current) == .none)

        let decision = machine.openCompleted(
            generation: opened.generation,
            result: .init(succeeded: false, wasAlreadyOpen: false, isSupportedDocument: false),
            currentURL: current
        )

        #expect(decision.disposition == .ignore)
        #expect(checkRequest(decision.next)?.url == second.standardizedFileURL)
    }

    @Test func staleCompletionStartsFreshCloseCheckForLatestRequest() throws {
        let machine = DocumentOpenStateMachine()
        let firstCheck = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        let firstOpen = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: firstCheck.generation,
            currentURL: current
        )))
        #expect(machine.requestOpen(at: second, currentURL: current) == .none)

        let stale = machine.openCompleted(
            generation: firstOpen.generation,
            result: .init(succeeded: true, wasAlreadyOpen: true, isSupportedDocument: true),
            currentURL: current
        )
        let secondCheck = try #require(checkRequest(stale.next))
        let secondOpen = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: secondCheck.generation,
            currentURL: current
        )))

        #expect(secondOpen.url == second.standardizedFileURL)
    }

    @Test func closeCancellationClearsAllPendingRequests() throws {
        let machine = DocumentOpenStateMachine()
        let checked = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        #expect(machine.requestOpen(at: second, currentURL: current) == .none)

        #expect(machine.closeCheckCompleted(
            false,
            generation: checked.generation,
            currentURL: current
        ) == .none)

        let next = try #require(checkRequest(machine.requestOpen(at: third, currentURL: current)))
        #expect(next.url == third.standardizedFileURL)
        #expect(next.generation == 3)
    }

    @Test func requestingCurrentDocumentSupersedesInFlightOpen() throws {
        let machine = DocumentOpenStateMachine()
        let checked = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        let opened = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: checked.generation,
            currentURL: current
        )))
        #expect(machine.requestOpen(at: current, currentURL: current) == .none)

        let decision = machine.openCompleted(
            generation: opened.generation,
            result: .init(succeeded: true, wasAlreadyOpen: false, isSupportedDocument: true),
            currentURL: current
        )

        #expect(decision.disposition == .discardNewDocument)
        #expect(decision.next == .activateCurrent)
    }

    @Test func alreadyOpenCompletionRequestsActivationInsteadOfAdoption() throws {
        let decision = try completeCurrentRequest(
            result: .init(succeeded: true, wasAlreadyOpen: true, isSupportedDocument: true)
        )
        #expect(decision.disposition == .activateExistingDocument)
    }

    @Test func newDocumentCompletionRequestsAdoption() throws {
        let decision = try completeCurrentRequest(
            result: .init(succeeded: true, wasAlreadyOpen: false, isSupportedDocument: true)
        )
        #expect(decision.disposition == .adoptNewDocument)
    }

    @Test func unsupportedNewDocumentIsDiscardedBeforeError() throws {
        let decision = try completeCurrentRequest(
            result: .init(succeeded: true, wasAlreadyOpen: false, isSupportedDocument: false)
        )
        #expect(decision.disposition == .discardNewDocumentAndPresentError)
    }

    @Test func previousDocumentClosesOnlyWhenCleanAndNoControllersRemain() {
        #expect(DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: false,
            remainingWindowControllerCount: 0,
            isDocumentEdited: false
        ))
        #expect(!DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: false,
            remainingWindowControllerCount: 1,
            isDocumentEdited: false
        ))
        #expect(!DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: true,
            remainingWindowControllerCount: 0,
            isDocumentEdited: false
        ))
        #expect(!DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: false,
            remainingWindowControllerCount: 0,
            isDocumentEdited: true
        ))
    }

    @Test func editAfterCloseApprovalInvalidatesTheLaterCloseDecision() {
        var isDocumentEdited = false
        #expect(DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: false,
            remainingWindowControllerCount: 0,
            isDocumentEdited: isDocumentEdited
        ))

        // 模拟 openDocument 的异步窗口内，用户又向旧文档输入了字符。adopt 必须
        // 使用此刻的实时状态，不能沿用开始加载前 canClose 的结果。
        isDocumentEdited = true
        #expect(!DocumentOpenStateMachine.shouldClosePreviousDocument(
            isSameDocument: false,
            remainingWindowControllerCount: 0,
            isDocumentEdited: isDocumentEdited
        ))
    }

    private func completeCurrentRequest(
        result: DocumentOpenStateMachine.OpenResult
    ) throws -> DocumentOpenStateMachine.CompletionDecision {
        let machine = DocumentOpenStateMachine()
        let checked = try #require(checkRequest(machine.requestOpen(at: first, currentURL: current)))
        let opened = try #require(openRequest(machine.closeCheckCompleted(
            true,
            generation: checked.generation,
            currentURL: current
        )))
        return machine.openCompleted(
            generation: opened.generation,
            result: result,
            currentURL: current
        )
    }

    private func checkRequest(
        _ step: DocumentOpenStateMachine.Step
    ) -> DocumentOpenStateMachine.Request? {
        guard case .checkCanClose(let request) = step else { return nil }
        return request
    }

    private func openRequest(
        _ step: DocumentOpenStateMachine.Step
    ) -> DocumentOpenStateMachine.Request? {
        guard case .open(let request) = step else { return nil }
        return request
    }
}
