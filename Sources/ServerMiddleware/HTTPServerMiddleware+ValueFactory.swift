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

/// Backs the value-factory ``HTTPServerMiddleware/then(_:)``; callers do not
/// name this type directly.
@available(anyAppleOS 26.0, *)
struct ValueFactoryMiddleware<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    Value: ~Copyable,
    Reader: AsyncReader & ~Copyable & ~Escapable,
    Sender: HTTPResponseSender & ~Copyable,
    Next: HTTPServerMiddleware & Sendable
>: HTTPServerMiddleware, Sendable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    Sender.Writer: ~Copyable,
    Next.RequestContextIn: ~Copyable,
    Next.RequestContextOut: ~Copyable,
    Next.ValueIn == Void,
    Next.ValueOut: ~Copyable,
    Next.ReaderIn: ~Copyable & ~Escapable,
    Next.ReaderOut: ~Copyable & ~Escapable,
    Next.SenderIn: ~Copyable,
    Next.SenderIn.Writer: ~Copyable,
    Next.SenderOut: ~Copyable,
    Next.SenderOut.Writer: ~Copyable,
    Next.RequestContextIn == Context,
    Next.RequestContextOut == Context,
    Next.ReaderIn == Reader,
    Next.SenderIn == Sender
{
    typealias RequestContextIn = Context
    typealias RequestContextOut = Context
    typealias ValueIn = Value
    typealias ValueOut = Next.ValueOut
    typealias ReaderIn = Reader
    typealias ReaderOut = Next.ReaderOut
    typealias SenderIn = Sender
    typealias SenderOut = Next.SenderOut

    private let build: @Sendable (consuming sending Value) throws -> sending Next

    init(build: @escaping @Sendable (consuming sending Value) throws -> sending Next) {
        self.build = build
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
            consuming sending Next.ValueOut,
            consuming sending Next.ReaderOut,
            consuming sending Next.SenderOut
        ) async throws -> Void
    ) async throws {
        let downstream = try self.build(value)
        try await downstream.intercept(
            request: request,
            requestContext: requestContext,
            value: (),
            reader: reader,
            responseSender: responseSender,
            next: next
        )
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
    Self.ReaderOut: ~Copyable & ~Escapable,
    Self.SenderIn: ~Copyable,
    Self.SenderIn.Writer: ~Copyable,
    Self.SenderOut: ~Copyable,
    Self.SenderOut.Writer: ~Copyable
{
    /// Chains a stage built from the carried value — the value-factory shape (see
    /// ``HTTPServerMiddleware``). `build` runs once per request; the stage it
    /// returns then runs with `value: ()`.
    public func then<Next: HTTPServerMiddleware & Sendable>(
        _ build: @escaping @Sendable (consuming sending ValueOut) throws -> sending Next
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, Self.RequestContextOut,
        Self.ValueIn, Next.ValueOut,
        Self.ReaderIn, Next.ReaderOut,
        Self.SenderIn, Next.SenderOut
    >
    where
        Next.RequestContextIn: ~Copyable,
        Next.RequestContextOut: ~Copyable,
        Next.ValueIn == Void,
        Next.ValueOut: ~Copyable,
        Next.ReaderIn: ~Copyable & ~Escapable,
        Next.ReaderOut: ~Copyable & ~Escapable,
        Next.SenderIn: ~Copyable,
        Next.SenderIn.Writer: ~Copyable,
        Next.SenderOut: ~Copyable,
        Next.SenderOut.Writer: ~Copyable,
        Next.RequestContextIn == Self.RequestContextOut,
        Next.RequestContextOut == Self.RequestContextOut,
        Next.ReaderIn == Self.ReaderOut,
        Next.SenderIn == Self.SenderOut
    {
        let factory:
            ValueFactoryMiddleware<
                RequestContextOut, ValueOut, ReaderOut, SenderOut, Next
            > = ValueFactoryMiddleware(build: build)
        return self.then(factory)
    }
}
