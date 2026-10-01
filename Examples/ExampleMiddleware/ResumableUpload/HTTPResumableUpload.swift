//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP API Proposal open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP API Proposal project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import BasicContainers
import HTTPAPIs
import Synchronization

/// `HTTPResumableUploadContext` manages ongoing uploads.
@available(anyAppleOS 26.0, *)
public final class HTTPResumableUploadContext: Sendable {
    let origin: String
    let path: String
    let timeout: Duration
    private let uploads: Mutex<[String: HTTPResumableUpload]> = .init([:])

    /// Create an `HTTPResumableUploadContext` for use with ``HTTPServerResumableUploadMiddleware``.
    /// - Parameters:
    ///   - origin: Scheme and authority of the upload server. For example, "https://www.example.com".
    ///   - path: Request path for resumption URLs. The middleware intercepts all requests to this path.
    ///   - timeout: Time to wait before failure if the client didn't attempt an upload resumption.
    public init(origin: String, path: String = "/resumable_upload/", timeout: Duration = .seconds(3600)) {
        self.origin = origin
        self.path = path
        self.timeout = timeout
    }

    func isResumption(path: String) -> Bool {
        path.hasPrefix(self.path)
    }

    func startUpload() -> HTTPResumableUpload {
        var random = SystemRandomNumberGenerator()
        let token = "\(random.next())-\(random.next())"
        let upload = HTTPResumableUpload(context: self, token: token)
        self.uploads.withLock {
            assert($0[token] == nil)
            $0[token] = upload
        }
        return upload
    }

    func stopUpload(_ upload: HTTPResumableUpload) {
        _ = self.uploads.withLock {
            $0.removeValue(forKey: upload.token)
        }
    }

    func findUpload(path: String) -> HTTPResumableUpload? {
        let token = String(path.dropFirst(self.path.count))
        return self.uploads.withLock {
            $0[token]
        }
    }
}

/// Errors produced by resumable upload.
public enum HTTPResumableUploadError: Error {
    /// An upload cancellation request was received.
    case uploadCancelled
    /// Timed out waiting for the client to resume the upload.
    case timeoutWaitingForResumption
    /// The client sent more data than the declared upload length.
    case uploadLengthExceeded
    /// The handler finished processing the upload.
    case uploadFinished
    /// The client stopped sending the upload after the handler started responding.
    case uploadIncomplete
}

/// `HTTPResumableUpload` tracks a logical upload that spans one or more HTTP requests.
///
/// The next middleware processes the upload as a single request in the task of the upload
/// creation request. Each HTTP request carrying upload data "attaches" to the upload, pumps its
/// body into the upload, and, once the upload is complete, relays the response produced by the
/// next middleware back to the client. At most one request is attached at any time. Every
/// attachment is identified by a generation so that requests superseded by a resumption (for
/// example, on a connection the server didn't notice was dropped) can no longer affect the upload.
@available(anyAppleOS 26.0, *)
final class HTTPResumableUpload: Sendable {
    enum BodyEvent: ~Copyable, Sendable {
        case data(UniqueArray<UInt8>)
        /// The entire upload has been received.
        case end(HTTPFields?)

        var byteCount: Int {
            switch self {
            case .data(let bytes): bytes.count
            case .end: 0
            }
        }
    }

    enum ResponsePart: ~Copyable, Sendable {
        case informational(HTTPResponse)
        case head(HTTPResponse)
        case body(UniqueArray<UInt8>)
        case end(UniqueArray<UInt8>, HTTPFields?)

        var isInformational: Bool {
            switch self {
            case .informational: true
            default: false
            }
        }

        var isHead: Bool {
            switch self {
            case .head: true
            default: false
            }
        }
    }

    /// Signals delivered to an attached request.
    enum AttachmentSignal: Error {
        /// The request has been superseded by another request.
        case detached
        /// The body of the request ended or was interrupted before the upload completed.
        case incomplete
    }

    /// Thrown when a request tries to attach in a state inconsistent with the upload.
    struct ConflictError: Error {
        var status: HTTPResumableUploadProtocol.Status
    }

    private struct PendingBody: ~Copyable {
        var event: BodyEvent
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct PendingResponse: ~Copyable {
        var part: ResponsePart
        var continuation: CheckedContinuation<Void, any Error>
    }

    // Continuations can't carry non-copyable values, so body data and response parts are moved
    // through the state: the receiving side is resumed once the value is in
    // `receivedBody` or `receivedResponse`, and then takes it out.
    private struct State: ~Copyable {
        /// Bytes received by the next middleware.
        var offset: Int64 = 0
        /// The total length of the upload (if known).
        var uploadLength: Int64?
        /// The next middleware received the entire upload.
        var uploadComplete = false
        /// The generation of the latest attachment.
        var generation: UInt64 = 0
        /// Whether the request of the latest generation is attached.
        var attached = false
        /// Why the request of the latest generation is no longer attached.
        var detachSignal = AttachmentSignal.detached
        /// The request of the latest generation received the response head. It keeps receiving
        /// the response even after its body ends, and no other request can attach.
        var responding = false
        /// The upload is over and all further operations fail with this error.
        var failure: (any Error)?
        /// The next middleware receives no more body, and further body reads fail with this error.
        var bodyFailure: (any Error)?
        /// Body data waiting for the next middleware to read it.
        var pendingBody: PendingBody?
        /// The next middleware waiting for body data.
        var bodyReader: CheckedContinuation<Void, any Error>?
        /// Body data handed to the next middleware, which it hasn't taken yet.
        var receivedBody: BodyEvent?
        /// Response parts waiting for the attached request to send them.
        var pendingResponse: PendingResponse?
        /// The attached request waiting for response parts.
        var responseReceiver: CheckedContinuation<Void, any Error>?
        /// A response part handed to the attached request, which it hasn't taken yet.
        var receivedResponse: ResponsePart?
        /// The upload fails if no request attaches by this time.
        var timeoutDeadline: ContinuousClock.Instant?
        /// The timeout task waiting for a deadline to be scheduled.
        var timeoutWaiter: CheckedContinuation<Void, Never>?

        var status: HTTPResumableUploadProtocol.Status {
            .init(offset: self.offset, complete: self.uploadComplete, uploadLength: self.uploadLength)
        }

        /// Reconciles the upload length with the lengths known from a request.
        mutating func saveUploadLength(complete: Bool, contentLength: Int64?, uploadLength: Int64?) -> Bool {
            var computedUploadLength: Int64?
            if complete, let contentLength {
                let (length, overflow) = self.offset.addingReportingOverflow(contentLength)
                guard !overflow else {
                    return false
                }
                computedUploadLength = length
            }
            // Check all lengths before saving any, so that a conflicting request doesn't affect
            // the upload.
            var newUploadLength = self.uploadLength
            for length in [computedUploadLength, uploadLength] {
                guard let length else { continue }
                if let knownUploadLength = newUploadLength, knownUploadLength != length {
                    return false
                }
                newUploadLength = length
            }
            self.uploadLength = newUploadLength
            return true
        }

        /// Records that the next middleware received the event.
        mutating func consume(_ event: borrowing BodyEvent) {
            switch event {
            case .data(let bytes):
                self.offset += Int64(bytes.count)
            case .end:
                self.uploadComplete = true
            }
        }

        mutating func fail(_ error: any Error) {
            guard self.failure == nil else { return }
            self.failure = error
            self.pendingBody.take()?.continuation.resume(throwing: error)
            self.bodyReader.take()?.resume(throwing: error)
            self.pendingResponse.take()?.continuation.resume(throwing: error)
            self.responseReceiver.take()?.resume(throwing: error)
            self.timeoutDeadline = nil
            self.timeoutWaiter.take()?.resume()
        }

        /// Records that the attached request received a response part.
        mutating func deliver(_ part: borrowing ResponsePart) {
            guard part.isHead else {
                return
            }
            self.responding = true
            if !self.attached {
                // The body of the request ended before the request received the response head,
                // so the client won't resume the upload.
                self.timeoutDeadline = nil
                self.bodyFailure = HTTPResumableUploadError.uploadIncomplete
                self.bodyReader.take()?.resume(throwing: HTTPResumableUploadError.uploadIncomplete)
            }
        }

        /// Detaches the attached request.
        /// - Returns: Whether the client may resume the upload.
        mutating func detach(signal: AttachmentSignal) -> Bool {
            self.attached = false
            self.detachSignal = signal
            self.pendingBody.take()?.continuation.resume(throwing: signal)
            if self.pendingResponse?.part.isInformational == true {
                // Informational responses are only for the attached request.
                self.pendingResponse.take()!.continuation.resume()
            }
            if self.responding {
                // The client stops the upload once it receives the response, so the request keeps
                // receiving the response, and the next middleware receives no more body.
                self.bodyFailure = HTTPResumableUploadError.uploadIncomplete
                self.bodyReader.take()?.resume(throwing: HTTPResumableUploadError.uploadIncomplete)
                return false
            }
            self.responseReceiver.take()?.resume(throwing: signal)
            return self.failure == nil
        }
    }

    let token: String
    private let context: HTTPResumableUploadContext
    private let state: Mutex<State> = .init(State())

    init(context: HTTPResumableUploadContext, token: String) {
        self.context = context
        self.token = token
    }

    /// The absolute URL of the upload resource.
    var location: String {
        self.context.origin + self.context.path + self.token
    }

    var status: HTTPResumableUploadProtocol.Status {
        self.state.withLock { $0.status }
    }

    private func fail(_ error: any Error) {
        self.state.withLock { $0.fail(error) }
        self.context.stopUpload(self)
    }

    private func scheduleTimeout(_ state: inout State) {
        state.timeoutDeadline = .now + self.context.timeout
        state.timeoutWaiter.take()?.resume()
    }

    /// Fails the upload if no request attaches before a scheduled timeout.
    ///
    /// This runs for the lifetime of the upload in a child task of the upload creation request,
    /// and returns once the upload is over or the task is cancelled.
    func enforceTimeout() async {
        while let deadline = await self.nextTimeoutDeadline() {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            // A request may have attached, and detached again, while sleeping.
            let expired = self.state.withLock { state in
                state.timeoutDeadline.map { $0 <= .now } ?? false
            }
            if expired {
                self.fail(HTTPResumableUploadError.timeoutWaitingForResumption)
            }
        }
    }

    /// Waits until a timeout is scheduled.
    /// - Returns: The deadline, or `nil` if the upload is over or the task is cancelled.
    private func nextTimeoutDeadline() async -> ContinuousClock.Instant? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.state.withLock { state in
                    if state.failure != nil || state.timeoutDeadline != nil || Task.isCancelled {
                        continuation.resume()
                    } else {
                        state.timeoutWaiter = continuation
                    }
                }
            }
            return self.state.withLock { state in
                state.failure == nil && !Task.isCancelled ? state.timeoutDeadline : nil
            }
        } onCancel: {
            self.state.withLock { $0.timeoutWaiter.take()?.resume() }
        }
    }
}

// For requests attaching to the upload.
@available(anyAppleOS 26.0, *)
extension HTTPResumableUpload {
    /// Attaches the upload creation request or an upload appending request.
    /// - Returns: The generation of the attachment.
    func attach(
        offset: Int64,
        complete: Bool,
        contentLength: Int64?,
        uploadLength: Int64?
    ) throws(ConflictError) -> UInt64 {
        try self.state.withLock { state throws(ConflictError) in
            guard state.failure == nil, !state.attached, !state.responding, !state.uploadComplete,
                state.offset == offset,
                state.saveUploadLength(complete: complete, contentLength: contentLength, uploadLength: uploadLength)
            else {
                throw ConflictError(status: state.status)
            }
            state.generation += 1
            state.attached = true
            state.timeoutDeadline = nil
            return state.generation
        }
    }

    /// Detaches the request after its body ended without completing the upload, or after the
    /// connection failed.
    /// - Parameter acknowledge: Whether the request should acknowledge the partial upload.
    func detach(generation: UInt64, acknowledge: Bool) {
        self.state.withLock { state in
            guard state.generation == generation, state.attached else {
                return
            }
            if state.detach(signal: acknowledge ? .incomplete : .detached) {
                self.scheduleTimeout(&state)
            }
        }
    }

    /// Forcibly detaches any attached request, and reports the current upload status.
    func retrieveOffset() -> HTTPResumableUploadProtocol.Status {
        self.state.withLock { state in
            if state.attached, state.detach(signal: .detached) {
                self.scheduleTimeout(&state)
            }
            return state.status
        }
    }

    func cancel() {
        self.fail(HTTPResumableUploadError.uploadCancelled)
    }

    /// Hands body data from the attached request to the next middleware, waiting until it
    /// has been read.
    func send(body event: consuming BodyEvent, generation: UInt64) async throws {
        let byteCount = event.byteCount
        var pendingEvent = Optional(event)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let failure = self.state.withLock { state -> (any Error)? in
                if let failure = state.failure {
                    continuation.resume(throwing: failure)
                    return nil
                }
                guard state.generation == generation, state.attached else {
                    continuation.resume(throwing: AttachmentSignal.detached)
                    return nil
                }
                if let uploadLength = state.uploadLength,
                    state.offset + Int64(byteCount) > uploadLength
                {
                    continuation.resume(throwing: HTTPResumableUploadError.uploadLengthExceeded)
                    return HTTPResumableUploadError.uploadLengthExceeded
                }
                if let bodyReader = state.bodyReader.take() {
                    state.consume(pendingEvent!)
                    state.receivedBody = pendingEvent.take()
                    bodyReader.resume()
                    continuation.resume()
                } else {
                    state.pendingBody = PendingBody(event: pendingEvent.take()!, continuation: continuation)
                }
                return nil
            }
            if let failure {
                self.fail(failure)
            }
        }
    }

    /// Waits for the next part of the response produced by the next middleware.
    func receiveResponsePart(generation: UInt64) async throws -> ResponsePart {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.state.withLock { state in
                if let failure = state.failure {
                    continuation.resume(throwing: failure)
                } else if state.generation != generation {
                    continuation.resume(throwing: AttachmentSignal.detached)
                } else if !state.attached && !state.responding
                    // A response head produced before the body ended is sent instead of
                    // acknowledging the partial upload.
                    && !(state.detachSignal == .incomplete && state.pendingResponse?.part.isHead == true)
                {
                    continuation.resume(throwing: state.detachSignal)
                } else if let pendingResponse = state.pendingResponse.take() {
                    state.deliver(pendingResponse.part)
                    pendingResponse.continuation.resume()
                    state.receivedResponse = .some(pendingResponse.part)
                    continuation.resume()
                } else {
                    state.responseReceiver = continuation
                }
            }
        }
        return self.state.withLock { $0.receivedResponse.take()! }
    }

    /// The attached request failed to send the response.
    func responseFailed(_ error: any Error) {
        self.fail(error)
    }
}

// For the next middleware.
@available(anyAppleOS 26.0, *)
extension HTTPResumableUpload {
    /// Waits for body data from the attached request.
    func receiveBody() async throws -> BodyEvent {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.state.withLock { state in
                if let pendingBody = state.pendingBody.take() {
                    state.consume(pendingBody.event)
                    pendingBody.continuation.resume()
                    state.receivedBody = .some(pendingBody.event)
                    continuation.resume()
                } else if let failure = state.failure ?? state.bodyFailure {
                    continuation.resume(throwing: failure)
                } else {
                    state.bodyReader = continuation
                }
            }
        }
        return self.state.withLock { $0.receivedBody.take()! }
    }

    /// Hands a response part to the attached request, waiting until it has been received.
    ///
    /// If no request is attached, this waits for the client to resume the upload, except for
    /// informational responses, which are dropped.
    func send(response part: consuming ResponsePart) async throws {
        let isInformational = part.isInformational
        var pendingPart = Optional(part)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.state.withLock { state in
                if let failure = state.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if isInformational, !state.attached || state.responding {
                    // Informational responses are advisory, so they don't wait for the client to
                    // resume, and they can't follow the final response.
                    continuation.resume()
                    return
                }
                if let responseReceiver = state.responseReceiver.take() {
                    state.deliver(pendingPart!)
                    state.receivedResponse = pendingPart.take()
                    responseReceiver.resume()
                    continuation.resume()
                } else {
                    state.pendingResponse = PendingResponse(part: pendingPart.take()!, continuation: continuation)
                }
            }
        }
    }

    /// The next middleware finished processing the upload.
    func finish(error: (any Error)?) {
        self.fail(error ?? HTTPResumableUploadError.uploadFinished)
    }
}
