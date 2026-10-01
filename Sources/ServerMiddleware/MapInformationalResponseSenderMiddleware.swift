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

/// A sender that wraps an upstream ``HTTPResponseSender``, intercepting calls
/// to ``HTTPResponseSender/sendInformational(_:)`` while forwarding the final
/// response unchanged.
@available(anyAppleOS 26.0, *)
public struct MappedInformationalResponseSender<Upstream: HTTPResponseSender & ~Copyable>:
    HTTPResponseSender, ~Copyable, Sendable
where Upstream.Writer: ~Copyable {
    public typealias Writer = Upstream.Writer

    private var upstream: Disconnected<Upstream>
    private let wrap:
        @Sendable (
            HTTPResponse,
            (HTTPResponse) async throws -> Void
        ) async throws -> Void

    init(
        upstream: consuming sending Upstream,
        wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> Void
            ) async throws -> Void
    ) {
        self.upstream = Disconnected(value: upstream)
        self.wrap = wrap
    }

    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        let savedWrap = self.wrap
        var upstream = self.upstream.take()
        do {
            try await savedWrap(response) { responseToSend in
                try await upstream.sendInformational(responseToSend)
            }
        } catch {
            self = MappedInformationalResponseSender(upstream: upstream, wrap: savedWrap)
            throw error
        }
        self = MappedInformationalResponseSender(upstream: upstream, wrap: savedWrap)
    }

    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        try await self.upstream.take().send(response)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        try await self.upstream.take().sendAndFinish(response, buffer: &buffer, trailer: trailer)
    }
}

/// A middleware that intercepts each call to
/// ``HTTPResponseSender/sendInformational(_:)``, allowing the closure to
/// inspect or modify the informational response or time the call.
///
/// Produced by ``HTTPServerMiddleware/mapInformationalResponseSender(_:)`` and
/// ``HTTPServerMiddleware/mapInformationalResponse(_:)``; callers do not name
/// this type directly.
@available(anyAppleOS 26.0, *)
struct MapInformationalResponseSenderMiddleware<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    Value: ~Copyable,
    Reader: AsyncReader & ~Copyable & ~Escapable,
    Sender: HTTPResponseSender & ~Copyable
>: HTTPServerMiddleware, Sendable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    Sender.Writer: ~Copyable
{
    typealias RequestContextIn = Context
    typealias ValueIn = Value
    typealias ValueOut = Value
    typealias ReaderIn = Reader
    typealias ReaderOut = Reader
    typealias SenderIn = Sender
    typealias SenderOut = MappedInformationalResponseSender<Sender>

    private let wrap:
        @Sendable (
            HTTPResponse,
            (HTTPResponse) async throws -> Void
        ) async throws -> Void

    init(
        _ wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> Void
            ) async throws -> Void
    ) {
        self.wrap = wrap
    }

    func intercept(
        request: HTTPRequest,
        requestContext: consuming Context,
        value: consuming sending Value,
        reader: consuming sending Reader,
        responseSender: consuming sending Sender,
        next: (
            HTTPRequest,
            consuming Context,
            consuming sending Value,
            consuming sending Reader,
            consuming sending MappedInformationalResponseSender<Sender>
        ) async throws -> Void
    ) async throws {
        let wrapped = MappedInformationalResponseSender<Sender>(
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
    /// Chains an informational-response sender wrap onto this stage, intercepting
    /// each call to ``HTTPResponseSender/sendInformational(_:)``.
    ///
    /// The closure receives the informational response head and a `sendOriginal`
    /// continuation. It may call `sendOriginal` zero or more times with a
    /// (possibly modified) response.
    ///
    /// ```swift
    /// existingMiddleware
    ///   .mapInformationalResponseSender { response, sendOriginal in
    ///     try await timed(operation: "informational") {
    ///       try await sendOriginal(response)
    ///     }
    ///   }
    ///   .finally(EchoHandler())
    /// ```
    ///
    /// The final response passes through unchanged. To intercept the final
    /// response's send call, use ``mapFinalResponseSender(_:)``.
    public func mapInformationalResponseSender(
        _ wrap:
            @escaping @Sendable (
                HTTPResponse,
                (HTTPResponse) async throws -> Void
            ) async throws -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, MappedInformationalResponseSender<SenderOut>
    >
    where Self: Sendable {
        let mapper:
            MapInformationalResponseSenderMiddleware<
                RequestContextOut, ValueOut, ReaderOut, SenderOut
            > = MapInformationalResponseSenderMiddleware(wrap)
        return self.then(mapper)
    }

    /// Chains an informational-response transform onto this stage, mutating each
    /// 1xx response head before it is sent.
    ///
    /// ```swift
    /// existingMiddleware
    ///   .mapInformationalResponse {
    ///     $0.headerFields[.init("Link")!] = "</style.css>; rel=preload"
    ///   }
    ///   .finally(EchoHandler())
    /// ```
    ///
    /// The final response passes through unchanged.
    public func mapInformationalResponse(
        _ transform: @escaping @Sendable (inout HTTPResponse) -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, MappedInformationalResponseSender<SenderOut>
    >
    where Self: Sendable {
        self.mapInformationalResponseSender { response, sendOriginal in
            var response = response
            transform(&response)
            try await sendOriginal(response)
        }
    }
}
