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

/// Backs the value-aware closure ``HTTPServerMiddleware/then(_:)``; callers do
/// not name this type directly.
///
/// The carried value, request reader, and response sender are each split into
/// independent in/out types (`InValue` → `OutValue`, `InReader` → `OutReader`,
/// `InSender` → `OutSender`) so the closure may retype any of them: it consumes
/// the upstream trio and forwards freshly-typed ones to `next`. A pass-through
/// closure (calling `next` with the same values it received) leaves all three
/// unchanged, with the out types inferred from the forwarded arguments.
@available(anyAppleOS 26.0, *)
struct ValueAwareClosureMiddleware<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    InValue: ~Copyable,
    OutValue: ~Copyable,
    InReader: AsyncReader & ~Copyable & ~Escapable,
    OutReader: AsyncReader & ~Copyable & ~Escapable,
    InSender: HTTPResponseSender & ~Copyable,
    OutSender: HTTPResponseSender & ~Copyable
>: HTTPServerMiddleware, Sendable
where
    InReader.ReadElement == UInt8,
    InReader.FinalElement == HTTPFields?,
    OutReader.ReadElement == UInt8,
    OutReader.FinalElement == HTTPFields?,
    InSender.Writer: ~Copyable,
    OutSender.Writer: ~Copyable
{
    typealias RequestContextIn = Context
    typealias ValueIn = InValue
    typealias ValueOut = OutValue
    typealias ReaderIn = InReader
    typealias ReaderOut = OutReader
    typealias SenderIn = InSender
    typealias SenderOut = OutSender

    private let body:
        @Sendable (
            HTTPRequest,
            consuming Context,
            consuming sending InValue,
            consuming sending InReader,
            consuming sending InSender,
            (
                HTTPRequest,
                consuming Context,
                consuming sending OutValue,
                consuming sending OutReader,
                consuming sending OutSender
            ) async throws -> Void
        ) async throws -> Void

    init(
        _ body:
            @escaping @Sendable (
                HTTPRequest,
                consuming Context,
                consuming sending InValue,
                consuming sending InReader,
                consuming sending InSender,
                (
                    HTTPRequest,
                    consuming Context,
                    consuming sending OutValue,
                    consuming sending OutReader,
                    consuming sending OutSender
                ) async throws -> Void
            ) async throws -> Void
    ) {
        self.body = body
    }

    func intercept(
        request: HTTPRequest,
        requestContext: consuming Context,
        value: consuming sending InValue,
        reader: consuming sending InReader,
        responseSender: consuming sending InSender,
        next: (
            HTTPRequest,
            consuming Context,
            consuming sending OutValue,
            consuming sending OutReader,
            consuming sending OutSender
        ) async throws -> Void
    ) async throws {
        try await self.body(request, requestContext, value, reader, responseSender, next)
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
    /// Chains an inline stage written as a closure — the value-blind shape (see
    /// ``HTTPServerMiddleware``). The carried value passes through unseen.
    public func then(
        _ body:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContextOut,
                consuming sending ReaderOut,
                consuming sending SenderOut,
                (
                    HTTPRequest,
                    consuming RequestContextOut,
                    consuming sending ReaderOut,
                    consuming sending SenderOut
                ) async throws -> Void
            ) async throws -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, SenderOut
    >
    where Self: Sendable {
        // Delegates to the value-aware overload, parking the carried value in a
        // take-once box: the value-blind closure's `next` has no value slot, so
        // the move-only value must be re-injected when the closure forwards.
        self.then { request, context, value, reader, sender, next in
            var carried: Disconnected<ValueOut>? = Disconnected(value: value)
            try await body(request, context, reader, sender) { req, ctx, rdr, sndr in
                try await next(req, ctx, carried.take()!.take(), rdr, sndr)
            }
        }
    }

    /// Chains an inline stage written as a closure that also receives the carried
    /// ``ValueOut`` — the value-aware shape (see ``HTTPServerMiddleware``).
    ///
    /// The closure may retype the carried value, the request reader, and/or the
    /// response sender: it forwards a `NewValue`, `NewReader`, and `NewSender` to
    /// `next`, which become the chained stage's ``HTTPServerMiddleware/ValueOut``,
    /// ``HTTPServerMiddleware/ReaderOut``, and ``HTTPServerMiddleware/SenderOut``.
    /// Forwarding the values it received leaves every axis unchanged — the out
    /// types are inferred from the arguments passed to `next`, so pass-through
    /// callers need no annotation. The request context passes through unchanged.
    public func then<
        NewValue: ~Copyable,
        NewReader: AsyncReader & ~Copyable & ~Escapable,
        NewSender: HTTPResponseSender & ~Copyable
    >(
        _ body:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContextOut,
                consuming sending ValueOut,
                consuming sending ReaderOut,
                consuming sending SenderOut,
                (
                    HTTPRequest,
                    consuming RequestContextOut,
                    consuming sending NewValue,
                    consuming sending NewReader,
                    consuming sending NewSender
                ) async throws -> Void
            ) async throws -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, NewValue,
        Self.ReaderIn, NewReader,
        Self.SenderIn, NewSender
    >
    where
        Self: Sendable,
        NewReader.ReadElement == UInt8,
        NewReader.FinalElement == HTTPFields?,
        NewSender.Writer: ~Copyable
    {
        self.then(
            ValueAwareClosureMiddleware<
                RequestContextOut, ValueOut, NewValue, ReaderOut, NewReader, SenderOut, NewSender
            >(body)
        )
    }
}
