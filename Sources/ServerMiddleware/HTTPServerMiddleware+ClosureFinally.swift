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

import AsyncStreaming
public import HTTPAPIs

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
    /// Closes the chain with an inline terminal written as a closure — the
    /// value-blind shape (see ``HTTPServerMiddleware``). Requires a `Void` value
    /// channel.
    public func finally(
        _ body:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContextOut,
                consuming sending ReaderOut,
                consuming sending SenderOut
            ) async throws -> Void
    ) -> some HTTPServerRequestHandler<
        Self.RequestContextIn, Self.ReaderIn, Self.SenderIn
    >
    where
        Self: Sendable,
        Self.ValueIn == Void,
        Self.ValueOut == Void,
        Self.ReaderIn: Escapable,
        Self.ReaderOut: Escapable
    {
        self.finally(
            HTTPServerClosureRequestHandler<RequestContextOut, ReaderOut, SenderOut>(
                handler: body
            )
        )
    }

    /// Closes the chain with an inline terminal written as a closure that also
    /// receives the carried ``ValueOut`` — the value-aware shape (see
    /// ``HTTPServerMiddleware``).
    public func finally(
        _ body:
            @escaping @Sendable (
                HTTPRequest,
                consuming RequestContextOut,
                consuming sending ValueOut,
                consuming sending ReaderOut,
                consuming sending SenderOut
            ) async throws -> Void
    ) -> some HTTPServerRequestHandler<
        Self.RequestContextIn, Self.ReaderIn, Self.SenderIn
    >
    where
        Self: Sendable,
        Self.ValueIn == Void,
        Self.ReaderIn: Escapable,
        Self.ReaderOut: Escapable
    {
        ValueAwareMiddlewareHandler(self, body: body)
    }

    /// Closes the chain with a terminal built from the carried value — the
    /// value-factory shape (see ``HTTPServerMiddleware``). `build` runs once per
    /// request before the terminal is dispatched.
    public func finally<Terminal: HTTPServerRequestHandler & Sendable>(
        _ build:
            @escaping @Sendable (consuming sending ValueOut) throws -> sending Terminal
    ) -> some HTTPServerRequestHandler<
        Self.RequestContextIn, Self.ReaderIn, Self.SenderIn
    >
    where
        Self: Sendable,
        Self.ValueIn == Void,
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
        ValueAwareMiddlewareHandler(self) { request, context, value, body, sender in
            let terminal = try build(value)
            try await terminal.handle(
                request: request,
                requestContext: context,
                reader: body,
                responseSender: sender
            )
        }
    }
}
