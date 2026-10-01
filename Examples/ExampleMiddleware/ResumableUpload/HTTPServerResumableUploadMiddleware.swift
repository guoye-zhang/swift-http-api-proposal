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

public import AsyncStreaming
import BasicContainers
public import HTTPAPIs
public import ServerMiddleware

/// A middleware stage that implements resumable uploads for HTTP servers.
///
/// It implements interop version 6 of the resumable upload internet-draft
/// (`draft-ietf-httpbis-resumable-upload-05`), the version supported by `URLSession`, and
/// interop version 10, the latest version. Each request is handled according to the interop
/// version it indicates.
///
/// The next stage sees each resumable upload as a single request whose body is the
/// entire upload, even when the client sends it over multiple HTTP requests after
/// interruptions. Requests that are not resumable uploads pass through unchanged.
/// Requests that only manage an upload (offset retrieval, appending, and cancellation)
/// are handled by this stage and never reach the next stage.
///
/// The next stage runs in the task of the upload creation request, so that request's
/// handler doesn't return until the entire upload has been processed, even if the creation
/// request itself was interrupted.
@available(anyAppleOS 26.0, *)
public struct HTTPServerResumableUploadMiddleware<
    RequestContext: HTTPServerCapability.RequestContext & ~Copyable,
    Value: ~Copyable,
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>: HTTPServerMiddleware
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    public typealias RequestContextIn = RequestContext
    public typealias ValueIn = Value
    public typealias ReaderIn = Reader
    public typealias ReaderOut = HTTPResumableUploadReader<Reader>
    public typealias SenderIn = ResponseSender
    public typealias SenderOut = HTTPResumableUploadResponseSender<ResponseSender>

    let context: HTTPResumableUploadContext

    public init(
        requestContextType: RequestContext.Type = RequestContext.self,
        valueType: Value.Type = Value.self,
        readerType: Reader.Type = Reader.self,
        responseSenderType: ResponseSender.Type = ResponseSender.self,
        context: HTTPResumableUploadContext
    ) {
        self.context = context
    }

    public func intercept(
        request: HTTPRequest,
        requestContext: consuming RequestContext,
        value: consuming sending Value,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender,
        next: (
            HTTPRequest,
            consuming RequestContext,
            consuming sending Value,
            consuming sending HTTPResumableUploadReader<Reader>,
            consuming sending HTTPResumableUploadResponseSender<ResponseSender>
        ) async throws -> Void
    ) async throws {
        let identified: (version: HTTPResumableUploadProtocol.Version, type: HTTPResumableUploadProtocol.RequestType)?
        do {
            identified = try HTTPResumableUploadProtocol.identifyRequest(request, in: self.context)
        } catch {
            try await responseSender.sendAndFinish(
                HTTPResumableUploadProtocol.badRequestResponse(version: error.version)
            )
            return
        }
        guard case let (version, type)? = identified else {
            try await next(
                request,
                requestContext,
                value,
                HTTPResumableUploadReader(base: reader),
                HTTPResumableUploadResponseSender(base: responseSender)
            )
            return
        }

        switch type {
        case .options:
            try await next(
                request,
                requestContext,
                value,
                HTTPResumableUploadReader(base: reader),
                HTTPResumableUploadResponseSender(
                    base: responseSender,
                    processResponse: { HTTPResumableUploadProtocol.processOptionsResponse($0, version: version) }
                )
            )

        case .uploadCreation(let complete, let contentLength, let uploadLength):
            let upload = self.context.startUpload()
            let generation: UInt64
            do throws(HTTPResumableUpload.ConflictError) {
                generation = try upload.attach(
                    offset: 0,
                    complete: complete,
                    contentLength: contentLength,
                    uploadLength: uploadLength
                )
            } catch {
                upload.cancel()
                try await responseSender.sendAndFinish(
                    HTTPResumableUploadProtocol.conflictResponse(status: error.status, version: version)
                )
                return
            }
            var responseSender = responseSender
            do {
                try await responseSender.sendInformational(
                    HTTPResumableUploadProtocol.featureDetectionResponse(location: upload.location, version: version)
                )
            } catch {
                upload.cancel()
                throw error
            }

            // The next stage consumes the upload through `upload`, while the creation request
            // pumps its body into `upload` from a child task, and enforces the resumption timeout
            // from another.
            let transferredReader = SendingBox(reader)
            let transferredResponseSender = SendingBox(responseSender)
            async let attachment: Void = HTTPResumableUploadAttachment.serve(
                upload: upload,
                generation: generation,
                reader: transferredReader.take(),
                responseSender: transferredResponseSender.take(),
                requestComplete: complete,
                location: upload.location,
                version: version
            )
            // Fails the upload if the client doesn't resume it in time. It is cancelled when it
            // goes out of scope, after the upload is over.
            async let _: Void = upload.enforceTimeout()
            do {
                try await next(
                    HTTPResumableUploadProtocol.stripRequest(request, uploadLength: upload.status.uploadLength),
                    requestContext,
                    value,
                    HTTPResumableUploadReader(upload: upload),
                    HTTPResumableUploadResponseSender(upload: upload)
                )
                upload.finish(error: nil)
            } catch {
                upload.finish(error: error)
                throw error
            }
            await attachment

        case .offsetRetrieving(let path):
            guard let upload = self.context.findUpload(path: path) else {
                try await responseSender.sendAndFinish(HTTPResumableUploadProtocol.notFoundResponse(version: version))
                return
            }
            let status = upload.retrieveOffset()
            try await responseSender.sendAndFinish(
                HTTPResumableUploadProtocol.offsetRetrievingResponse(status: status, version: version)
            )

        case .uploadAppending(let path, let offset, let complete, let contentLength, let uploadLength):
            guard let upload = self.context.findUpload(path: path) else {
                try await responseSender.sendAndFinish(HTTPResumableUploadProtocol.notFoundResponse(version: version))
                return
            }
            let generation: UInt64
            do throws(HTTPResumableUpload.ConflictError) {
                generation = try upload.attach(
                    offset: offset,
                    complete: complete,
                    contentLength: contentLength,
                    uploadLength: uploadLength
                )
            } catch {
                try await responseSender.sendAndFinish(
                    HTTPResumableUploadProtocol.conflictResponse(status: error.status, version: version)
                )
                return
            }
            await HTTPResumableUploadAttachment.serve(
                upload: upload,
                generation: generation,
                reader: reader,
                responseSender: responseSender,
                requestComplete: complete,
                location: nil,
                version: version
            )

        case .uploadCancellation(let path):
            guard let upload = self.context.findUpload(path: path) else {
                try await responseSender.sendAndFinish(HTTPResumableUploadProtocol.notFoundResponse(version: version))
                return
            }
            upload.cancel()
            try await responseSender.sendAndFinish(HTTPResumableUploadProtocol.cancelledResponse(version: version))
        }
    }
}

/// Serves a request attached to a resumable upload.
@available(anyAppleOS 26.0, *)
private enum HTTPResumableUploadAttachment<
    Reader: AsyncReader & ~Copyable & SendableMetatype,
    ResponseSender: HTTPResponseSender & ~Copyable & SendableMetatype
>
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    ResponseSender.Writer: ~Copyable
{
    /// Pumps the body of a request attached to an upload into the upload, while either
    /// relaying the response of the next middleware, or acknowledging the partial upload.
    ///
    /// - Parameters:
    ///   - location: The upload URL, if the request is the upload creation request.
    ///   - version: The interop version of the request.
    static func serve(
        upload: HTTPResumableUpload,
        generation: UInt64,
        reader: consuming sending Reader,
        responseSender: consuming sending ResponseSender,
        requestComplete: Bool,
        location: String?,
        version: HTTPResumableUploadProtocol.Version
    ) async {
        // The next middleware may respond before reading the entire upload, so the body is
        // pumped concurrently with the response.
        let transferredReader = SendingBox(reader)
        var responseSender: ResponseSender? = .some(responseSender)
        await withDiscardingTaskGroup { group in
            group.addTask {
                await Self.pumpBody(
                    upload: upload,
                    generation: generation,
                    reader: transferredReader.take(),
                    requestComplete: requestComplete
                )
            }
            await Self.respond(
                upload: upload,
                generation: generation,
                responseSender: responseSender.take()!,
                location: location,
                version: version
            )
        }
    }

    /// Sends the body of the request to the next middleware.
    static func pumpBody(
        upload: HTTPResumableUpload,
        generation: UInt64,
        reader: consuming Reader,
        requestComplete: Bool
    ) async {
        var reader = reader
        do throws(EitherError<Reader.ReadFailure, any Error>) {
            var trailers: HTTPFields? = nil
            var bodyEnded = false
            while !bodyEnded {
                try await reader.read { (chunk: inout Reader.Buffer, finalElement: consuming HTTPFields??) in
                    let bytes = chunk.drainBytes()
                    if !bytes.isEmpty {
                        try await upload.send(body: .data(bytes), generation: generation)
                    }
                    if let finalElement {
                        trailers = finalElement
                        bodyEnded = true
                    }
                }
            }
            if requestComplete {
                do {
                    try await upload.send(body: .end(trailers), generation: generation)
                } catch {
                    throw .second(error)
                }
            } else {
                // Let the request acknowledge the partial upload, unless it is already relaying
                // the response.
                upload.detach(generation: generation, acknowledge: true)
            }
        } catch {
            switch error {
            case .first:
                // The request was interrupted. Wait for the client to resume the upload.
                upload.detach(generation: generation, acknowledge: false)
            case .second:
                // A newer request has taken over the upload, or the upload is over. Either way,
                // the response is handled by `respond`.
                break
            }
        }
    }

    /// Sends the response produced by the next middleware to the attached request, or
    /// acknowledges the partial upload if the request body ended first.
    static func respond(
        upload: HTTPResumableUpload,
        generation: UInt64,
        responseSender: consuming ResponseSender,
        location: String?,
        version: HTTPResumableUploadProtocol.Version
    ) async {
        var responseSender = responseSender
        let head: HTTPResponse
        do {
            receiving: while true {
                switch try await upload.receiveResponsePart(generation: generation) {
                case .informational(let response):
                    // Informational responses are advisory, so failing to send one is ignored.
                    try? await responseSender.sendInformational(response)
                case .head(let response):
                    head = response
                    break receiving
                case .body:
                    preconditionFailure("The response must start with a head")
                case .end:
                    preconditionFailure("The response must start with a head")
                }
            }
        } catch HTTPResumableUpload.AttachmentSignal.detached {
            // A newer request has taken over the upload.
            return
        } catch HTTPResumableUpload.AttachmentSignal.incomplete {
            // Acknowledge the partial upload, so that the client continues with the next part.
            try? await responseSender.sendAndFinish(
                HTTPResumableUploadProtocol.incompleteResponse(
                    status: upload.status,
                    location: location,
                    version: version
                )
            )
            return
        } catch let error as HTTPResumableUploadError where error != .uploadFinished {
            // The upload failed because of the client.
            try? await responseSender.sendAndFinish(HTTPResumableUploadProtocol.badRequestResponse(version: version))
            return
        } catch {
            // The next middleware failed without producing a response.
            try? await responseSender.sendAndFinish(HTTPResumableUploadProtocol.internalServerErrorResponse(version: version))
            return
        }

        do {
            let response = HTTPResumableUploadProtocol.processResponse(
                head,
                status: upload.status,
                version: version
            )
            var writer = try await responseSender.send(response)
            while true {
                switch try await upload.receiveResponsePart(generation: generation) {
                case .informational:
                    preconditionFailure("The response must only have one head")
                case .head:
                    preconditionFailure("The response must only have one head")
                case .body(var bytes):
                    try await writer.write(buffer: &bytes)
                case .end(var bytes, let trailers):
                    try await writer.finish(buffer: &bytes, finalElement: trailers)
                    return
                }
            }
        } catch {
            upload.responseFailed(error)
        }
    }
}

/// Moves a value received as `sending` into a child task.
///
/// The value is received as `sending` and handed out as `sending` exactly once, so no other
/// reference to it can remain in the original isolation region.
@available(anyAppleOS 26.0, *)
private final class SendingBox<Value: ~Copyable>: @unchecked Sendable {
    private nonisolated(unsafe) var value: Value?

    init(_ value: consuming sending Value) {
        unsafe self.value = .some(value)
    }

    func take() -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        return unsafe value
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPServerMiddleware
where
    Self: Sendable,
    Self.RequestContextIn: ~Copyable,
    Self.RequestContextOut: ~Copyable,
    Self.ValueIn: ~Copyable,
    Self.ValueOut: ~Copyable,
    Self.ReaderIn: ~Copyable & ~Escapable,
    Self.ReaderOut: ~Copyable & SendableMetatype,
    Self.SenderIn: ~Copyable,
    Self.SenderIn.Writer: ~Copyable,
    Self.SenderOut: ~Copyable & SendableMetatype,
    Self.SenderOut.Writer: ~Copyable
{
    /// Chains resumable upload support onto this middleware.
    ///
    /// See ``HTTPServerResumableUploadMiddleware``.
    public func withResumableUpload(
        context: HTTPResumableUploadContext
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, Self.RequestContextOut,
        Self.ValueIn, Self.ValueOut,
        Self.ReaderIn, HTTPResumableUploadReader<Self.ReaderOut>,
        Self.SenderIn, HTTPResumableUploadResponseSender<Self.SenderOut>
    > {
        self.then(
            HTTPServerResumableUploadMiddleware<RequestContextOut, ValueOut, ReaderOut, SenderOut>(context: context)
        )
    }
}
