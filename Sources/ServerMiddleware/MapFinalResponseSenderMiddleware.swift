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
public import HTTPAPIs

/// A sender that wraps an upstream ``HTTPResponseSender``, intercepting the
/// final response's send call to mutate the response head and/or transform the
/// writer it returns.
///
/// Informational responses pass through unchanged.
@available(anyAppleOS 26.0, *)
public struct MappedFinalResponseSender<
    Upstream: HTTPResponseSender & ~Copyable,
    Writer: CallerAsyncWriter & ~Copyable
>: HTTPResponseSender, ~Copyable, Sendable
where
    Upstream.Writer: ~Copyable,
    Writer.WriteElement == UInt8,
    Writer.FinalElement == HTTPFields?
{
    private var upstream: Disconnected<Upstream>
    private let wrap:
        @Sendable (
            HTTPResponse,
            (HTTPResponse) async throws -> sending Upstream.Writer
        ) async throws -> sending Writer

    init(
        upstream: consuming sending Upstream,
        wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> sending Upstream.Writer
            ) async throws -> sending Writer
    ) {
        self.upstream = Disconnected(value: upstream)
        self.wrap = wrap
    }

    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        let savedWrap = self.wrap
        var upstream = self.upstream.take()
        do {
            try await upstream.sendInformational(response)
        } catch {
            self = MappedFinalResponseSender(upstream: upstream, wrap: savedWrap)
            throw error
        }
        self = MappedFinalResponseSender(upstream: upstream, wrap: savedWrap)
    }

    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        var upstreamBox: Disconnected<Upstream>? = self.upstream
        return try await self.wrap(response) { responseToSend in
            guard let box = upstreamBox.take() else {
                fatalError("send called more than once on response sender")
            }
            return try await box.take().send(responseToSend)
        }
    }
}

/// A middleware that intercepts the final response's send call, allowing the
/// closure to inspect or modify the response, time the call, or transform the
/// writer that ``HTTPResponseSender/send(_:)`` returns.
///
/// Produced by ``HTTPServerMiddleware/mapFinalResponseSender(_:)`` and
/// ``HTTPServerMiddleware/mapResponse(_:)``; callers do not name this type
/// directly.
@available(anyAppleOS 26.0, *)
struct MapFinalResponseSenderMiddleware<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    Value: ~Copyable,
    Reader: AsyncReader & ~Copyable & ~Escapable,
    In: HTTPResponseSender & ~Copyable,
    OutWriter: CallerAsyncWriter & ~Copyable
>: HTTPServerMiddleware, Sendable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    In.Writer: ~Copyable,
    OutWriter.WriteElement == UInt8,
    OutWriter.FinalElement == HTTPFields?
{
    typealias RequestContextIn = Context
    typealias ValueIn = Value
    typealias ValueOut = Value
    typealias ReaderIn = Reader
    typealias ReaderOut = Reader
    typealias SenderIn = In
    typealias SenderOut = MappedFinalResponseSender<In, OutWriter>

    private let wrap:
        @Sendable (
            HTTPResponse,
            (HTTPResponse) async throws -> sending In.Writer
        ) async throws -> sending OutWriter

    init(
        _ wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> sending In.Writer
            ) async throws -> sending OutWriter
    ) {
        self.wrap = wrap
    }

    func intercept(
        request: HTTPRequest,
        requestContext: consuming Context,
        value: consuming sending Value,
        reader: consuming sending Reader,
        responseSender: consuming sending In,
        next: (
            HTTPRequest,
            consuming Context,
            consuming sending Value,
            consuming sending Reader,
            consuming sending MappedFinalResponseSender<In, OutWriter>
        ) async throws -> Void
    ) async throws {
        let wrapped = MappedFinalResponseSender<In, OutWriter>(
            upstream: responseSender,
            wrap: self.wrap
        )
        try await next(request, requestContext, value, reader, wrapped)
    }
}

@available(anyAppleOS 26.0, *)
extension HTTPServerMiddleware
where
    Self.RequestContextIn: ~Copyable,
    Self.RequestContextOut: ~Copyable,
    Self.ValueIn: ~Copyable,
    Self.ValueOut: ~Copyable,
    Self.ReaderIn: ~Copyable & ~Escapable,
    Self.ReaderOut: ~Copyable & ~Escapable,
    Self.SenderIn: ~Copyable,
    Self.SenderIn.Writer: ~Copyable,
    Self.SenderOut: ~Copyable,
    Self.SenderOut.Writer: ~Copyable
{
    /// Chains a final-response sender wrap onto this stage, intercepting the
    /// call to ``HTTPResponseSender/send(_:)``.
    ///
    /// The closure receives the response head and a `sendOriginal` continuation.
    /// It must invoke `sendOriginal` exactly once with a (possibly modified)
    /// response, and returns the (possibly transformed) writer for the response
    /// body.
    ///
    /// ```swift
    /// existingMiddleware
    ///   .mapFinalResponseSender { response, sendOriginal in
    ///     let writer = try await sendOriginal(response)
    ///     return writer.withByteCounter()
    ///   }
    ///   .finally(EchoHandler())
    /// ```
    ///
    /// Informational (1xx) responses pass through unchanged. To intercept those,
    /// use ``mapInformationalResponseSender(_:)``.
    public func mapFinalResponseSender<NewWriter: CallerAsyncWriter & ~Copyable>(
        _ wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> sending SenderOut.Writer
            ) async throws -> sending NewWriter
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, MappedFinalResponseSender<SenderOut, NewWriter>
    >
    where
        Self: Sendable,
        NewWriter.WriteElement == UInt8,
        NewWriter.FinalElement == HTTPFields?
    {
        let mapper:
            MapFinalResponseSenderMiddleware<
                RequestContextOut, ValueOut, ReaderOut, SenderOut, NewWriter
            > = MapFinalResponseSenderMiddleware(wrap)
        return self.then(mapper)
    }

    /// Chains a final-response transform onto this stage, mutating each
    /// non-informational response head before it is sent.
    ///
    /// ```swift
    /// existingMiddleware
    ///   .mapResponse { $0.headerFields[.server] = "TestServer/1.0" }
    ///   .finally(EchoHandler())
    /// ```
    ///
    /// Informational (1xx) responses pass through unchanged.
    public func mapResponse(
        _ transform: @escaping @Sendable (inout HTTPResponse) -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, MappedFinalResponseSender<SenderOut, SenderOut.Writer>
    >
    where Self: Sendable {
        self.mapFinalResponseSender { response, sendOriginal in
            var response = response
            transform(&response)
            return try await sendOriginal(response)
        }
    }
}
