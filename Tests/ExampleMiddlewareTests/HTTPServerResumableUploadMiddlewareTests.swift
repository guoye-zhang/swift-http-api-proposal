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
import ExampleMiddleware
import HTTPAPIs
import ServerMiddleware
import Synchronization
import Testing

@Suite("Resumable upload middleware")
struct HTTPServerResumableUploadMiddlewareTests {

    @Test
    @available(anyAppleOS 26.0, *)
    func passthrough() async throws {
        let server = TestServer()
        let recorder = Recorder()
        try await server.perform(HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/upload"), body: ["hello"], recorder: recorder)
        let response = try #require(recorder.response)
        #expect(response.status == .ok)
        #expect(response.headerFields[.uploadDraftInteropVersion] == nil)
        #expect(recorder.body == "hello")
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func completeUploadInOneRequest() async throws {
        let server = TestServer()
        let recorder = Recorder()
        try await server.perform(TestServer.creationRequest(complete: true, contentLength: 11), body: ["hello ", "world"], recorder: recorder)

        let informational = try #require(recorder.informational.first)
        #expect(informational.status.code == 104)
        let location = try #require(informational.headerFields[.location])
        #expect(location.hasPrefix("https://example.com/resumable_upload/"))

        let response = try #require(recorder.response)
        #expect(response.status == .ok)
        #expect(response.headerFields[.uploadDraftInteropVersion] == "6")
        // The response comes from the targeted resource, which didn't set a `Location`.
        #expect(response.headerFields[.location] == nil)
        #expect(response.headerFields[.uploadComplete] == "?1")
        #expect(response.headerFields[.uploadOffset] == "11")
        #expect(recorder.body == "hello world")
        // The handler sees a regular request.
        #expect(recorder.handlerRequest?.headerFields[.uploadComplete] == nil)
        #expect(recorder.handlerRequest?.headerFields[.uploadDraftInteropVersion] == nil)
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func resumeInterruptedUpload() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(
                    TestServer.creationRequest(complete: true, contentLength: nil),
                    body: ["hello "],
                    failAfterBody: true,
                    recorder: creation
                )
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))

            // Retrieve the offset once the server received the first part.
            var offset = ""
            for _ in 0..<1000 {
                let head = Recorder()
                try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
                let response = try #require(head.response)
                #expect(response.status == .noContent)
                #expect(response.headerFields[.uploadComplete] == "?0")
                #expect(response.headerFields[.uploadLimit] == "min-size=0")
                #expect(response.headerFields[.cacheControl] == "no-store")
                offset = try #require(response.headerFields[.uploadOffset])
                if offset == "6" { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(offset == "6")

            // Append the rest of the upload.
            let append = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 6, complete: true),
                body: ["world"],
                recorder: append
            )
            let response = try #require(append.response)
            #expect(response.status == .ok)
            #expect(response.headerFields[.uploadComplete] == "?1")
            #expect(response.headerFields[.uploadOffset] == "11")
            #expect(append.body == "hello world")

            try await group.waitForAll()
        }
        // The interrupted creation request never got a response.
        #expect(creation.response == nil)
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func uploadInMultipleParts() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(TestServer.creationRequest(complete: false, contentLength: 3), body: ["abc"], recorder: creation)
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()
            let creationResponse = try #require(creation.response)
            #expect(creationResponse.status == .created)
            #expect(creationResponse.headerFields[.location] == location)
            #expect(creationResponse.headerFields[.uploadComplete] == "?0")
            #expect(creationResponse.headerFields[.uploadOffset] == "3")

            let middle = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 3, complete: false),
                body: ["def"],
                recorder: middle
            )
            #expect(middle.response?.status == .created)
            #expect(middle.response?.headerFields[.uploadOffset] == "6")
            #expect(middle.response?.headerFields[.location] == nil)

            // An append at the wrong offset conflicts without affecting the upload.
            let conflict = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 2, complete: true),
                body: ["xyz"],
                recorder: conflict
            )
            #expect(conflict.response?.status == .conflict)
            #expect(conflict.response?.headerFields[.uploadComplete] == "?0")
            #expect(conflict.response?.headerFields[.uploadOffset] == "6")

            // Appends with inconsistent or overflowing lengths conflict without affecting the
            // upload either.
            var inconsistentLength = TestServer.resumptionRequest(method: .patch, path: path, offset: 6, complete: true)
            inconsistentLength.headerFields[.contentLength] = "3"
            inconsistentLength.headerFields[.uploadLength] = "50"
            var overflowingLength = TestServer.resumptionRequest(method: .patch, path: path, offset: 6, complete: true)
            overflowingLength.headerFields[.contentLength] = "\(Int64.max)"
            for request in [inconsistentLength, overflowingLength] {
                let lengthConflict = Recorder()
                try await server.perform(request, body: ["xyz"], recorder: lengthConflict)
                #expect(lengthConflict.response?.status == .conflict)
                #expect(lengthConflict.response?.headerFields[.uploadOffset] == "6")
            }
            let head = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
            #expect(head.response?.headerFields[.uploadOffset] == "6")
            #expect(head.response?.headerFields[.uploadLength] == nil)

            let last = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 6, complete: true),
                body: ["ghi"],
                recorder: last
            )
            #expect(last.response?.status == .ok)
            #expect(last.body == "abcdefghi")

            try await group.waitForAll()
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func cancelUpload() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                await #expect(throws: HTTPResumableUploadError.uploadCancelled) {
                    try await server.perform(TestServer.creationRequest(complete: false, contentLength: nil), body: ["abc"], recorder: creation)
                }
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()

            let delete = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .delete, path: path), recorder: delete)
            #expect(delete.response?.status == .noContent)

            try await group.waitForAll()

            let head = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
            #expect(head.response?.status == .notFound)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func offsetRetrievalDetachesStalledRequest() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(
                    TestServer.creationRequest(complete: true, contentLength: nil),
                    blockAfterBody: true,
                    recorder: creation
                )
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))

            // The creation request is still attached when the offset is retrieved.
            let head = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
            #expect(head.response?.status == .noContent)
            #expect(head.response?.headerFields[.uploadOffset] == "0")

            // The client resumes the upload in a new request, which receives the response.
            let append = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 0, complete: true),
                body: ["abc"],
                recorder: append
            )
            #expect(append.response?.status == .ok)
            #expect(append.body == "abc")
            #expect(creation.response == nil)

            group.cancelAll()
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func offsetRetrievalKeepsResponse() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(
                    TestServer.creationRequest(complete: false, contentLength: nil),
                    blockAfterBody: true,
                    respondEarly: true,
                    recorder: creation
                )
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()
            #expect(creation.response?.status == .ok)

            // The creation request is responding when the offset is retrieved, so it keeps the
            // response, and the handler's further body reads fail.
            let head = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
            #expect(head.response?.status == .noContent)
            #expect(head.response?.headerFields[.uploadOffset] == "0")

            // The upload ends once the handler finishes the response.
            var status: HTTPResponse.Status?
            for _ in 0..<1000 {
                let retry = Recorder()
                try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: retry)
                status = retry.response?.status
                if status == .notFound { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(status == .notFound)
            #expect(creation.response?.headerFields[.uploadComplete] == "?1")

            group.cancelAll()
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func timeoutWaitingForResumption() async throws {
        let server = TestServer(timeout: .milliseconds(10))
        let creation = Recorder()
        await #expect(throws: HTTPResumableUploadError.timeoutWaitingForResumption) {
            try await server.perform(TestServer.creationRequest(complete: false, contentLength: 3), body: ["abc"], recorder: creation)
        }
        #expect(creation.response?.status == .created)

        let location = try #require(creation.response?.headerFields[.location])
        let path = String(location.dropFirst("https://example.com".count))
        let head = Recorder()
        try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
        #expect(head.response?.status == .notFound)
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func uploadLengthExceeded() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                var request = TestServer.creationRequest(complete: false, contentLength: 3)
                request.headerFields[.uploadLength] = "5"
                await #expect(throws: HTTPResumableUploadError.uploadLengthExceeded) {
                    try await server.perform(request, body: ["abc"], recorder: creation)
                }
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()
            #expect(creation.response?.status == .created)

            // The append sends more than the declared upload length.
            let append = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 3, complete: false),
                body: ["defg"],
                recorder: append
            )
            #expect(append.response?.status == .badRequest)

            try await group.waitForAll()

            let head = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .head, path: path), recorder: head)
            #expect(head.response?.status == .notFound)
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func invalidRequests() async throws {
        let server = TestServer()
        var request = TestServer.creationRequest(complete: true, contentLength: nil)
        request.headerFields[.uploadDraftInteropVersion] = "5"
        let unsupportedVersion = Recorder()
        try await server.perform(request, recorder: unsupportedVersion)
        #expect(unsupportedVersion.response?.status == .badRequest)

        let unknownUpload = Recorder()
        try await server.perform(TestServer.resumptionRequest(method: .head, path: "/resumable_upload/unknown"), recorder: unknownUpload)
        #expect(unknownUpload.response?.status == .notFound)

        var missingContentType = TestServer.resumptionRequest(method: .patch, path: "/resumable_upload/unknown", offset: 0, complete: true)
        missingContentType.headerFields[.contentType] = nil
        let badAppend = Recorder()
        try await server.perform(missingContentType, recorder: badAppend)
        #expect(badAppend.response?.status == .badRequest)
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func options() async throws {
        let server = TestServer()
        var request = HTTPRequest(method: .options, scheme: "https", authority: "example.com", path: "/upload")
        request.headerFields[.uploadDraftInteropVersion] = "6"
        let recorder = Recorder()
        try await server.perform(request, recorder: recorder)
        #expect(recorder.response?.headerFields[.uploadLimit] == "min-size=0")
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func latestVersionCompleteUploadInOneRequest() async throws {
        let server = TestServer()
        let recorder = Recorder()
        try await server.perform(
            TestServer.creationRequest(complete: true, contentLength: 11, version: "10"),
            body: ["hello ", "world"],
            recorder: recorder
        )

        let informational = try #require(recorder.informational.first)
        #expect(informational.status.code == 104)
        #expect(informational.headerFields[.uploadDraftInteropVersion] == "10")
        #expect(informational.headerFields[.location] != nil)

        let response = try #require(recorder.response)
        #expect(response.status == .ok)
        #expect(response.headerFields[.uploadDraftInteropVersion] == "10")
        // The response comes from the targeted resource, which didn't set a `Location`.
        #expect(response.headerFields[.location] == nil)
        #expect(response.headerFields[.uploadComplete] == "?1")
        #expect(recorder.body == "hello world")
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func latestVersionUploadInMultipleParts() async throws {
        let server = TestServer()
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(
                    TestServer.creationRequest(complete: false, contentLength: 3, version: "10"),
                    body: ["abc"],
                    recorder: creation
                )
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()
            let creationResponse = try #require(creation.response)
            #expect(creationResponse.status == .created)
            #expect(creationResponse.headerFields[.uploadDraftInteropVersion] == "10")
            #expect(creationResponse.headerFields[.location] == location)
            #expect(creationResponse.headerFields[.uploadComplete] == "?0")

            // The offset can be retrieved with `GET`, and the response announces the limits.
            let get = Recorder()
            try await server.perform(TestServer.resumptionRequest(method: .get, path: path, version: "10"), recorder: get)
            #expect(get.response?.status == .noContent)
            #expect(get.response?.headerFields[.uploadOffset] == "3")
            #expect(get.response?.headerFields[.uploadLimit] == "min-size=0")

            // Appending requires `Upload-Complete`.
            let missingComplete = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 3, version: "10"),
                body: ["def"],
                recorder: missingComplete
            )
            #expect(missingComplete.response?.status == .badRequest)

            let last = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 3, complete: true, version: "10"),
                body: ["def"],
                recorder: last
            )
            #expect(last.response?.status == .ok)
            #expect(last.response?.headerFields[.uploadComplete] == "?1")
            #expect(last.body == "abcdef")

            try await group.waitForAll()
        }
    }

    @Test(arguments: ["6", "10"])
    @available(anyAppleOS 26.0, *)
    func earlyResponse(version: String) async throws {
        let server = TestServer()
        let recorder = Recorder()
        // The handler responds before the request body ends without completing the upload.
        try await server.perform(
            TestServer.creationRequest(complete: false, contentLength: 3, version: version),
            body: ["abc"],
            respondEarly: true,
            recorder: recorder
        )

        let response = try #require(recorder.response)
        #expect(response.status == .ok)
        #expect(response.headerFields[.uploadDraftInteropVersion] == version)
        #expect(response.headerFields[.uploadComplete] == "?1")
        #expect(recorder.body == "abc")

        // The upload is over.
        let location = try #require(recorder.informational.first?.headerFields[.location])
        let path = String(location.dropFirst("https://example.com".count))
        let head = Recorder()
        try await server.perform(TestServer.resumptionRequest(method: .head, path: path, version: version), recorder: head)
        #expect(head.response?.status == .notFound)
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func informationalResponses() async throws {
        let server = TestServer()
        // In a single request, the response follows the feature detection response.
        let single = Recorder()
        try await server.perform(
            TestServer.creationRequest(complete: true, contentLength: 3),
            body: ["abc"],
            earlyHintsAfter: 0,
            recorder: single
        )
        #expect(single.informational.map(\.status.code) == [104, 103])
        #expect(single.response?.status == .ok)

        // Across parts, the response goes to the request attached when the handler sends it.
        let creation = Recorder()
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await server.perform(
                    TestServer.creationRequest(complete: false, contentLength: 3),
                    body: ["abc"],
                    earlyHintsAfter: 4,
                    recorder: creation
                )
            }
            let location = try await creation.waitForLocation()
            let path = String(location.dropFirst("https://example.com".count))
            try await creation.waitForResponse()
            #expect(creation.informational.map(\.status.code) == [104])

            let last = Recorder()
            try await server.perform(
                TestServer.resumptionRequest(method: .patch, path: path, offset: 3, complete: true),
                body: ["def"],
                recorder: last
            )
            #expect(last.informational.map(\.status.code) == [103])
            #expect(last.response?.status == .ok)
            #expect(last.body == "abcdef")

            try await group.waitForAll()
        }
    }

    @Test
    @available(anyAppleOS 26.0, *)
    func invalidFieldValuesAreIgnored() async throws {
        let server = TestServer()
        var request = TestServer.creationRequest(complete: true, contentLength: nil, version: "10")
        request.headerFields[.uploadComplete] = "true"
        let recorder = Recorder()
        try await server.perform(request, body: ["hello"], recorder: recorder)
        // Without a valid `Upload-Complete`, this is a regular request.
        #expect(recorder.informational.isEmpty)
        #expect(recorder.response?.status == .ok)
        #expect(recorder.response?.headerFields[.uploadDraftInteropVersion] == nil)
        #expect(recorder.body == "hello")
    }

}

/// Runs requests through the middleware sharing one upload context.
@available(anyAppleOS 26.0, *)
struct TestServer: Sendable {
    let context: HTTPResumableUploadContext

    init(timeout: Duration = .seconds(3600)) {
        self.context = HTTPResumableUploadContext(origin: "https://example.com", timeout: timeout)
    }

    static func creationRequest(complete: Bool, contentLength: Int?, version: String = "6") -> HTTPRequest {
        var request = HTTPRequest(method: .post, scheme: "https", authority: "example.com", path: "/upload")
        request.headerFields[.uploadDraftInteropVersion] = version
        request.headerFields[.uploadComplete] = complete ? "?1" : "?0"
        request.headerFields[.contentLength] = contentLength.map { "\($0)" }
        return request
    }

    static func resumptionRequest(
        method: HTTPRequest.Method,
        path: String,
        offset: Int? = nil,
        complete: Bool? = nil,
        version: String = "6"
    ) -> HTTPRequest {
        var request = HTTPRequest(method: method, scheme: "https", authority: "example.com", path: path)
        request.headerFields[.uploadDraftInteropVersion] = version
        request.headerFields[.uploadOffset] = offset.map { "\($0)" }
        request.headerFields[.uploadComplete] = complete.map { $0 ? "?1" : "?0" }
        if method == .patch {
            request.headerFields[.contentType] = "application/partial-upload"
        }
        return request
    }

    /// Runs a request through the middleware, with a handler that echoes the request body.
    ///
    /// - Parameter blockAfterBody: Whether the request body stalls after `body` until the request
    ///   is cancelled.
    /// - Parameter respondEarly: Whether the handler sends the response head before reading the
    ///   body, and stops reading if the body fails.
    /// - Parameter earlyHintsAfter: The number of body bytes after which the handler sends a
    ///   `103 (Early Hints)` response, if any.
    func perform(
        _ request: HTTPRequest,
        body: [String] = [],
        failAfterBody: Bool = false,
        blockAfterBody: Bool = false,
        respondEarly: Bool = false,
        earlyHintsAfter: Int? = nil,
        recorder: Recorder
    ) async throws {
        let handler = MiddlewareBuilder<TestRequestContext, TestReader, TestResponseSender>()
            .withResumableUpload(context: self.context)
            .finally { request, _, reader, responseSender in
                recorder.recordHandlerRequest(request)
                var responseSender: HTTPResumableUploadResponseSender<TestResponseSender>? = .some(responseSender)
                var writer: HTTPResumableUploadResponseWriter<TestResponseSender.Writer>? = nil
                if respondEarly {
                    writer = try await responseSender.take()!.send(HTTPResponse(status: .ok))
                }
                // Receive the entire upload before responding with it.
                var reader = reader
                var collected: [UInt8] = []
                var ended = false
                var earlyHintsAfter = earlyHintsAfter
                while !ended {
                    if let threshold = earlyHintsAfter, collected.count >= threshold {
                        earlyHintsAfter = nil
                        try await responseSender!.sendInformational(HTTPResponse(status: .earlyHints))
                    }
                    do throws(EitherError<any Error, Never>) {
                        try await reader.read { (chunk: inout UniqueArray<UInt8>, finalElement: consuming HTTPFields??) in
                            collected += TestResponseSender.Writer.drain(&chunk)
                            ended = finalElement != nil
                        }
                    } catch {
                        switch error {
                        case .first(let error):
                            guard respondEarly else { throw error }
                            ended = true
                        }
                    }
                }
                if writer == nil {
                    writer = try await responseSender.take()!.send(HTTPResponse(status: .ok))
                }
                var buffer = UniqueArray<UInt8>()
                buffer.append(copying: collected)
                try await writer.take()!.finish(buffer: &buffer, finalElement: nil)
            }
        try await handler.handle(
            request: request,
            requestContext: TestRequestContext(),
            reader: TestReader(
                chunks: body.map { Array($0.utf8) },
                failAfterBody: failAfterBody,
                blockAfterBody: blockAfterBody
            ),
            responseSender: TestResponseSender(recorder: recorder)
        )
    }
}

@available(anyAppleOS 26.0, *)
struct TestRequestContext: HTTPServerCapability.RequestContext {}

struct ConnectionError: Error {}

@available(anyAppleOS 26.0, *)
struct TestReader: AsyncReader, ~Copyable, SendableMetatype {
    typealias ReadElement = UInt8
    typealias ReadFailure = any Error
    typealias Buffer = UniqueArray<UInt8>
    typealias FinalElement = HTTPFields?

    var chunks: [[UInt8]]
    let failAfterBody: Bool
    let blockAfterBody: Bool

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout UniqueArray<UInt8>, consuming HTTPFields??) async throws(Failure) -> Return
    ) async throws(EitherError<any Error, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        let finalElement: HTTPFields??
        if self.chunks.isEmpty {
            if self.blockAfterBody {
                // Simulate an idle connection until the request is cancelled.
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    throw .first(error)
                }
            }
            if self.failAfterBody {
                throw .first(ConnectionError())
            }
            finalElement = .some(nil)
        } else {
            buffer.append(copying: self.chunks.removeFirst())
            finalElement = nil
        }
        do throws(Failure) {
            return try await body(&buffer, finalElement)
        } catch {
            throw .second(error)
        }
    }
}

/// Records what the middleware sent for a request.
@available(anyAppleOS 26.0, *)
final class Recorder: Sendable {
    private struct State {
        var informational: [HTTPResponse] = []
        var response: HTTPResponse?
        var body: [UInt8] = []
        var handlerRequest: HTTPRequest?
    }

    private let state = Mutex(State())

    var informational: [HTTPResponse] { self.state.withLock { $0.informational } }
    var response: HTTPResponse? { self.state.withLock { $0.response } }
    var body: String { String(decoding: self.state.withLock { $0.body }, as: UTF8.self) }
    var handlerRequest: HTTPRequest? { self.state.withLock { $0.handlerRequest } }

    func recordInformational(_ response: HTTPResponse) { self.state.withLock { $0.informational.append(response) } }
    func recordResponse(_ response: HTTPResponse) { self.state.withLock { $0.response = response } }
    func recordBody(_ bytes: [UInt8]) { self.state.withLock { $0.body += bytes } }
    func recordHandlerRequest(_ request: HTTPRequest) { self.state.withLock { $0.handlerRequest = request } }

    func waitForLocation() async throws -> String {
        while true {
            if let location = self.informational.first?.headerFields[.location] {
                return location
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func waitForResponse() async throws {
        while self.response == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@available(anyAppleOS 26.0, *)
struct TestResponseSender: HTTPResponseSender, ~Copyable, SendableMetatype {
    struct Writer: CallerAsyncWriter, ~Copyable {
        typealias WriteElement = UInt8
        typealias WriteFailure = any Error
        typealias FinalElement = HTTPFields?

        let recorder: Recorder

        mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
            buffer: inout Buffer
        ) async throws(any Error) where Buffer.Element: ~Copyable {
            self.recorder.recordBody(Self.drain(&buffer))
        }

        consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
            buffer: inout Buffer,
            finalElement: consuming HTTPFields?
        ) async throws(any Error) where Buffer.Element: ~Copyable {
            self.recorder.recordBody(Self.drain(&buffer))
        }

        static func drain<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(_ buffer: inout Buffer) -> [UInt8] {
            var bytes: [UInt8] = []
            var consumer = buffer.consumeAll()
            while let byte = consumer.next() {
                bytes.append(byte)
            }
            return bytes
        }
    }

    let recorder: Recorder

    mutating func sendInformational(_ response: HTTPResponse) async throws {
        self.recorder.recordInformational(response)
    }

    consuming func send(_ response: HTTPResponse) async throws -> Writer {
        self.recorder.recordResponse(response)
        return Writer(recorder: self.recorder)
    }
}

extension HTTPField.Name {
    static let uploadDraftInteropVersion = Self("Upload-Draft-Interop-Version")!
    static let uploadComplete = Self("Upload-Complete")!
    static let uploadOffset = Self("Upload-Offset")!
    static let uploadLength = Self("Upload-Length")!
    static let uploadLimit = Self("Upload-Limit")!
}
