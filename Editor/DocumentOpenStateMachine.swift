import Foundation

/// Serializes sidebar document-open intents while AppKit performs asynchronous
/// close checks and document loading. Only the newest request may affect UI.
@MainActor
final class DocumentOpenStateMachine {
    struct Request: Equatable {
        let generation: Int
        let url: URL
    }

    enum Step: Equatable {
        case none
        case activateCurrent
        case checkCanClose(Request)
        case open(Request)
    }

    struct OpenResult: Equatable {
        let succeeded: Bool
        let wasAlreadyOpen: Bool
        let isSupportedDocument: Bool
        let hasDocument: Bool

        init(
            succeeded: Bool,
            wasAlreadyOpen: Bool,
            isSupportedDocument: Bool,
            hasDocument: Bool? = nil
        ) {
            self.succeeded = succeeded
            self.wasAlreadyOpen = wasAlreadyOpen
            self.isSupportedDocument = isSupportedDocument
            self.hasDocument = hasDocument ?? succeeded
        }
    }

    enum CompletionDisposition: Equatable {
        case ignore
        case discardNewDocument
        case presentError
        case discardNewDocumentAndPresentError
        case activateExistingDocument
        case adoptNewDocument
    }

    struct CompletionDecision: Equatable {
        let disposition: CompletionDisposition
        let next: Step
    }

    private enum Phase: Equatable {
        case idle
        case checking(Request)
        case opening(Request)
    }

    private var phase: Phase = .idle
    private var latestRequest: Request?
    private var nextGeneration = 0

    static func shouldClosePreviousDocument(
        isSameDocument: Bool,
        remainingWindowControllerCount: Int,
        isDocumentEdited: Bool
    ) -> Bool {
        !isSameDocument && remainingWindowControllerCount == 0 && !isDocumentEdited
    }

    func requestOpen(at url: URL, currentURL: URL?) -> Step {
        nextGeneration += 1
        latestRequest = Request(generation: nextGeneration, url: url.standardizedFileURL)
        guard phase == .idle else { return .none }
        return startLatest(currentURL: currentURL)
    }

    func closeCheckCompleted(
        _ shouldClose: Bool,
        generation: Int,
        currentURL: URL?
    ) -> Step {
        guard case .checking(let checked) = phase, checked.generation == generation else {
            return .none
        }

        guard shouldClose else {
            latestRequest = nil
            phase = .idle
            return .none
        }

        guard let latestRequest else {
            phase = .idle
            return .none
        }
        if normalized(currentURL) == latestRequest.url {
            self.latestRequest = nil
            phase = .idle
            return .activateCurrent
        }

        phase = .opening(latestRequest)
        return .open(latestRequest)
    }

    func openCompleted(
        generation: Int,
        result: OpenResult,
        currentURL: URL?
    ) -> CompletionDecision {
        guard case .opening(let opened) = phase, opened.generation == generation else {
            return CompletionDecision(
                disposition: staleDisposition(for: result),
                next: .none
            )
        }

        if let latestRequest, latestRequest.generation != opened.generation {
            phase = .idle
            let next = startLatest(currentURL: currentURL)
            return CompletionDecision(
                disposition: staleDisposition(for: result),
                next: next
            )
        }

        latestRequest = nil
        phase = .idle
        return CompletionDecision(
            disposition: currentDisposition(for: result),
            next: .none
        )
    }

    private func startLatest(currentURL: URL?) -> Step {
        guard let latestRequest else {
            phase = .idle
            return .none
        }
        if normalized(currentURL) == latestRequest.url {
            self.latestRequest = nil
            phase = .idle
            return .activateCurrent
        }
        phase = .checking(latestRequest)
        return .checkCanClose(latestRequest)
    }

    private func staleDisposition(for result: OpenResult) -> CompletionDisposition {
        result.hasDocument && !result.wasAlreadyOpen ? .discardNewDocument : .ignore
    }

    private func currentDisposition(for result: OpenResult) -> CompletionDisposition {
        guard result.succeeded else {
            return result.hasDocument && !result.wasAlreadyOpen
                ? .discardNewDocumentAndPresentError
                : .presentError
        }
        guard result.isSupportedDocument else {
            return result.wasAlreadyOpen ? .presentError : .discardNewDocumentAndPresentError
        }
        return result.wasAlreadyOpen ? .activateExistingDocument : .adoptNewDocument
    }

    private func normalized(_ url: URL?) -> URL? {
        url?.standardizedFileURL
    }
}
