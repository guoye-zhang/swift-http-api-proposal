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

/// An identity ``HTTPServerMiddleware`` used as the start of a fluent middleware
/// chain.
///
/// `MiddlewareBuilder` carries no behavior — it forwards every parameter into
/// `next` unchanged. Its purpose is to give a `~Copyable` request reader, a
/// response sender, and a context type a place to live so that the fluent
/// combinators (``HTTPServerMiddleware/mapRequestReader(_:)``,
/// ``HTTPServerMiddleware/mapResponse(_:)``, etc.) have a `Self` to extend off.
///
/// The carried value channel is fixed to `Void` at the chain entry — chains
/// start with no upstream stage to provide a value.
///
/// Generic parameters are usually inferred from the chain's terminator, so you
/// rarely need to spell them out:
///
/// ```swift
/// MiddlewareBuilder()
///   .mapRequestReader { $0.withElementCount(.max(4096)) }
///   .finally(EchoHandler())
/// ```
///
/// Use this when starting a new chain. To extend an existing concrete
/// middleware, call the combinators directly on it instead.
@available(anyAppleOS 26.0, *)
public struct MiddlewareBuilder<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable & ~Escapable,
    Sender: HTTPResponseSender & ~Copyable
>: HTTPServerMiddleware, Sendable
where
    Reader.ReadElement == UInt8,
    Reader.FinalElement == HTTPFields?,
    Sender.Writer: ~Copyable
{
    public typealias RequestContextIn = Context
    public typealias RequestContextOut = Context
    public typealias ValueIn = Void
    public typealias ValueOut = Void
    public typealias ReaderIn = Reader
    public typealias ReaderOut = Reader
    public typealias SenderIn = Sender
    public typealias SenderOut = Sender

    /// Creates an empty middleware chain.
    public init() {}

    public func intercept(
        request: HTTPRequest,
        requestContext: consuming Context,
        value: Void,
        reader: consuming sending Reader,
        responseSender: consuming sending Sender,
        next: (
            HTTPRequest,
            consuming Context,
            consuming sending Void,
            consuming sending Reader,
            consuming sending Sender
        ) async throws -> Void
    ) async throws {
        try await next(request, requestContext, (), reader, responseSender)
    }
}
