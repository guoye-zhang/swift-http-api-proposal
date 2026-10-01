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

public import HTTPAPIs

/// Two middleware stages composed into one: `First` runs, then `Second`, with the
/// first stage's output reader/sender/value types feeding the second stage's inputs.
///
/// Produced by the ``HTTPServerMiddleware/then(_:)`` combinator; callers do not
/// name this type directly.
@available(anyAppleOS 26.0, *)
struct ChainedHTTPServerMiddleware<
    First: HTTPServerMiddleware,
    Second: HTTPServerMiddleware
>:
    HTTPServerMiddleware
where
    First.RequestContextIn: ~Copyable,
    First.RequestContextOut: ~Copyable,
    First.ValueIn: ~Copyable,
    First.ValueOut: ~Copyable,
    First.ReaderIn: ~Copyable & ~Escapable,
    First.ReaderOut: ~Copyable & ~Escapable,
    First.SenderIn: ~Copyable,
    First.SenderIn.Writer: ~Copyable,
    First.SenderOut: ~Copyable,
    First.SenderOut.Writer: ~Copyable,
    First.RequestContextOut == Second.RequestContextIn,
    First.ValueOut == Second.ValueIn,
    First.ReaderOut == Second.ReaderIn,
    First.SenderOut == Second.SenderIn,
    Second.RequestContextIn: ~Copyable,
    Second.RequestContextOut: ~Copyable,
    Second.ValueIn: ~Copyable,
    Second.ValueOut: ~Copyable,
    Second.ReaderIn: ~Copyable & ~Escapable,
    Second.ReaderOut: ~Copyable & ~Escapable,
    Second.SenderIn: ~Copyable,
    Second.SenderIn.Writer: ~Copyable,
    Second.SenderOut: ~Copyable,
    Second.SenderOut.Writer: ~Copyable
{
    typealias RequestContextIn = First.RequestContextIn
    typealias RequestContextOut = Second.RequestContextOut
    typealias ValueIn = First.ValueIn
    typealias ValueOut = Second.ValueOut
    typealias ReaderIn = First.ReaderIn
    typealias ReaderOut = Second.ReaderOut
    typealias SenderIn = First.SenderIn
    typealias SenderOut = Second.SenderOut

    private let first: First
    private let second: Second

    init(first: First, second: Second) {
        self.first = first
        self.second = second
    }

    /// Runs `First` around `Second`, threading the chain's terminal `next` closure
    /// through both stages.
    ///
    /// `First` sees the inbound request body and outbound response sender, can
    /// transform either, and ultimately invokes `Second.intercept`, which in
    /// turn calls the supplied `next` with the chain's final reader/sender/value
    /// types. This is the protocol-required entry point — ``HTTPServerMiddleware``
    /// conformance — and adds no behavior of its own beyond the wiring.
    func intercept(
        request: HTTPRequest,
        requestContext: consuming First.RequestContextIn,
        value: consuming sending First.ValueIn,
        reader: consuming sending First.ReaderIn,
        responseSender: consuming sending First.SenderIn,
        next: (
            HTTPRequest,
            consuming Second.RequestContextOut,
            consuming sending Second.ValueOut,
            consuming sending Second.ReaderOut,
            consuming sending Second.SenderOut
        ) async throws -> Void
    ) async throws {
        try await self.first.intercept(
            request: request,
            requestContext: requestContext,
            value: value,
            reader: reader,
            responseSender: responseSender
        ) { req, ctx, midValue, body, sender in
            try await self.second.intercept(
                request: req,
                requestContext: ctx,
                value: midValue,
                reader: body,
                responseSender: sender,
                next: next
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension ChainedHTTPServerMiddleware: Sendable
where
    First: Sendable,
    First.RequestContextIn: ~Copyable,
    First.RequestContextOut: ~Copyable,
    First.ValueIn: ~Copyable,
    First.ValueOut: ~Copyable,
    First.ReaderIn: ~Copyable & ~Escapable,
    First.ReaderOut: ~Copyable & ~Escapable,
    First.SenderIn: ~Copyable,
    First.SenderIn.Writer: ~Copyable,
    First.SenderOut: ~Copyable,
    First.SenderOut.Writer: ~Copyable,
    Second: Sendable,
    Second.RequestContextIn: ~Copyable,
    Second.RequestContextOut: ~Copyable,
    Second.ValueIn: ~Copyable,
    Second.ValueOut: ~Copyable,
    Second.ReaderIn: ~Copyable & ~Escapable,
    Second.ReaderOut: ~Copyable & ~Escapable,
    Second.SenderIn: ~Copyable,
    Second.SenderIn.Writer: ~Copyable,
    Second.SenderOut: ~Copyable,
    Second.SenderOut.Writer: ~Copyable
{}

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
    /// Chains a conforming stage after this one — the conforming-type shape (see
    /// ``HTTPServerMiddleware``). This stage's output reader/sender/value/context
    /// types must match `next`'s inputs.
    public func then<Next: HTTPServerMiddleware>(
        _ next: Next
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, Next.RequestContextOut,
        Self.ValueIn, Next.ValueOut,
        Self.ReaderIn, Next.ReaderOut,
        Self.SenderIn, Next.SenderOut
    >
    where
        Next.RequestContextIn: ~Copyable,
        Next.RequestContextOut: ~Copyable,
        Next.ValueIn: ~Copyable,
        Next.ValueOut: ~Copyable,
        Next.ReaderIn: ~Copyable & ~Escapable,
        Next.ReaderOut: ~Copyable & ~Escapable,
        Next.SenderIn: ~Copyable,
        Next.SenderIn.Writer: ~Copyable,
        Next.SenderOut: ~Copyable,
        Next.SenderOut.Writer: ~Copyable,
        Self.RequestContextOut == Next.RequestContextIn,
        Self.ValueOut == Next.ValueIn,
        Self.ReaderOut == Next.ReaderIn,
        Self.SenderOut == Next.SenderIn
    {
        ChainedHTTPServerMiddleware(first: self, second: next)
    }

    /// Closes the chain with a conforming terminal handler — the conforming-type
    /// shape (see ``HTTPServerMiddleware``) — producing an
    /// `HTTPServerRequestHandler`. Requires a `Void` value channel; the terminal's
    /// reader (which must be `Escapable`), sender, and context types must match
    /// this stage's. A chain carrying a value closes with a value-aware or
    /// value-factory ``finally(_:)`` instead.
    public func finally<Terminal: HTTPServerRequestHandler>(
        _ terminal: Terminal
    ) -> some HTTPServerRequestHandler<
        Self.RequestContextIn, Self.ReaderIn, Self.SenderIn
    >
    where
        Self: Sendable,
        Self.ValueIn == Void,
        Self.ValueOut == Void,
        Self.ReaderIn: Escapable,
        Self.ReaderOut: Escapable,
        Terminal.RequestContext: ~Copyable,
        Terminal.Reader: ~Copyable,
        Terminal.ResponseSender: ~Copyable,
        Terminal.ResponseSender.Writer: ~Copyable,
        Terminal.RequestContext == Self.RequestContextOut,
        Terminal.Reader == Self.ReaderOut,
        Terminal.ResponseSender == Self.SenderOut
    {
        ValueAwareMiddlewareHandler(self) { request, context, _, reader, sender in
            try await terminal.handle(
                request: request,
                requestContext: context,
                reader: reader,
                responseSender: sender
            )
        }
    }
}
