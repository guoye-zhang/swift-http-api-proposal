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
public import BasicContainers
public import HTTPAPIs

/// The request body reader passed on by ``HTTPServerResumableUploadMiddleware``.
///
/// For resumable uploads, this reads the entire upload, which may arrive over multiple
/// HTTP requests. Otherwise, it reads the body of the original request.
@available(anyAppleOS 26.0, *)
public struct HTTPResumableUploadReader<Base: AsyncReader & ~Copyable>: AsyncReader, ~Copyable
where Base.ReadElement == UInt8, Base.FinalElement == HTTPFields? {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = any Error
    public typealias Buffer = UniqueArray<UInt8>
    public typealias FinalElement = HTTPFields?

    private var base: Base?
    private let upload: HTTPResumableUpload?

    init(base: consuming Base) {
        self.base = .some(base)
        self.upload = nil
    }

    init(upload: HTTPResumableUpload) {
        self.base = nil
        self.upload = upload
    }

    public mutating func read<Return: ~Copyable, Failure>(
        body: (inout Buffer, consuming HTTPFields??) async throws(Failure) -> Return
    ) async throws(EitherError<any Error, Failure>) -> Return {
        guard let upload = self.upload else {
            do throws(EitherError<Base.ReadFailure, Failure>) {
                return try await self.base!.read {
                    (chunk: inout Base.Buffer, finalElement: consuming HTTPFields??) async throws(Failure) -> Return in
                    var buffer = UniqueArray<UInt8>(minimumCapacity: chunk.count)
                    var consumer = chunk.consumeAll()
                    while let byte = consumer.next() {
                        buffer.append(byte)
                    }
                    return try await body(&buffer, finalElement)
                }
            } catch {
                switch error {
                case .first(let error): throw .first(error)
                case .second(let error): throw .second(error)
                }
            }
        }

        let event: HTTPResumableUpload.BodyEvent
        do {
            event = try await upload.receiveBody()
        } catch {
            throw .first(error)
        }
        var buffer: UniqueArray<UInt8>
        let finalElement: HTTPFields??
        switch consume event {
        case .data(let bytes):
            buffer = bytes
            finalElement = nil
        case .end(let trailers):
            buffer = UniqueArray()
            finalElement = .some(trailers)
        }
        do throws(Failure) {
            return try await body(&buffer, finalElement)
        } catch {
            throw .second(error)
        }
    }
}

@available(*, unavailable)
extension HTTPResumableUploadReader: Sendable {}

/// The response sender passed on by ``HTTPServerResumableUploadMiddleware``.
///
/// For resumable uploads, the response is sent to the HTTP request that completes the upload.
/// Informational responses are not forwarded for resumable uploads.
@available(anyAppleOS 26.0, *)
public struct HTTPResumableUploadResponseSender<
    Base: HTTPResponseSender & ~Copyable
>: HTTPResponseSender, ~Copyable
where Base.Writer: ~Copyable {
    public typealias Writer = HTTPResumableUploadResponseWriter<Base.Writer>

    private var base: Base?
    private let processResponse: (@Sendable (HTTPResponse) -> HTTPResponse)?
    private let upload: HTTPResumableUpload?

    init(base: consuming Base, processResponse: (@Sendable (HTTPResponse) -> HTTPResponse)? = nil) {
        self.base = .some(base)
        self.processResponse = processResponse
        self.upload = nil
    }

    init(upload: HTTPResumableUpload) {
        self.base = nil
        self.processResponse = nil
        self.upload = upload
    }

    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        if let upload = self.upload {
            try await upload.send(response: .informational(response))
        } else {
            try await self.base!.sendInformational(response)
        }
    }

    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        if let upload = self.upload {
            try await upload.send(response: .head(response))
            return Writer(upload: upload)
        }
        let response = self.processResponse?(response) ?? response
        return Writer(base: try await self.base.take()!.send(response))
    }
}

@available(*, unavailable)
extension HTTPResumableUploadResponseSender: Sendable {}

/// The response body writer of ``HTTPResumableUploadResponseSender``.
@available(anyAppleOS 26.0, *)
public struct HTTPResumableUploadResponseWriter<Base: CallerAsyncWriter & ~Copyable>: CallerAsyncWriter, ~Copyable
where Base.WriteElement == UInt8, Base.FinalElement == HTTPFields? {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = any Error
    public typealias FinalElement = HTTPFields?

    private var base: Base?
    private let upload: HTTPResumableUpload?

    init(base: consuming Base) {
        self.base = .some(base)
        self.upload = nil
    }

    init(upload: HTTPResumableUpload) {
        self.base = nil
        self.upload = upload
    }

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(any Error) where Buffer.Element: ~Copyable {
        if let upload = self.upload {
            try await upload.send(response: .body(buffer.drainBytes()))
        } else {
            try await self.base!.write(buffer: &buffer)
        }
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming HTTPFields?
    ) async throws(any Error) where Buffer.Element: ~Copyable {
        if let upload = self.upload {
            try await upload.send(response: .end(buffer.drainBytes(), finalElement))
        } else {
            try await self.base.take()!.finish(buffer: &buffer, finalElement: finalElement)
        }
    }
}

@available(*, unavailable)
extension HTTPResumableUploadResponseWriter: Sendable {}

@available(anyAppleOS 26.0, *)
extension RangeReplaceableContainer where Self: ~Copyable, Element == UInt8 {
    /// Moves all bytes out of the container into a `UniqueArray`.
    mutating func drainBytes() -> UniqueArray<UInt8> {
        var bytes = UniqueArray<UInt8>(minimumCapacity: self.count)
        var consumer = self.consumeAll()
        while let byte = consumer.next() {
            bytes.append(byte)
        }
        return bytes
    }
}
