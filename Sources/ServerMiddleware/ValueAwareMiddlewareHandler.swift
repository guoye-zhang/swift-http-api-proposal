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
import HTTPAPIs

/// Backs every ``HTTPServerMiddleware/finally(_:)`` shape — conforming-type,
/// value-blind, value-aware, and value-factory — by running the middleware and
/// dispatching the terminal closure built for each. Callers do not name this
/// type directly.
@available(anyAppleOS 26.0, *)
struct ValueAwareMiddlewareHandler<M: HTTPServerMiddleware & Sendable>:
    HTTPServerRequestHandler, Sendable
where
    M.RequestContextIn: ~Copyable,
    M.RequestContextOut: ~Copyable,
    M.ValueIn == Void,
    M.ValueOut: ~Copyable,
    M.ReaderIn: ~Copyable & Escapable,
    M.ReaderOut: ~Copyable & Escapable,
    M.SenderIn: ~Copyable,
    M.SenderIn.Writer: ~Copyable,
    M.SenderOut: ~Copyable,
    M.SenderOut.Writer: ~Copyable
{
    typealias RequestContext = M.RequestContextIn
    typealias Reader = M.ReaderIn
    typealias ResponseSender = M.SenderIn

    private let middleware: M
    private let body:
        @Sendable (
            HTTPRequest,
            consuming M.RequestContextOut,
            consuming sending M.ValueOut,
            consuming sending M.ReaderOut,
            consuming sending M.SenderOut
        ) async throws -> Void

    init(
        _ middleware: M,
        body:
            @escaping @Sendable (
                HTTPRequest,
                consuming M.RequestContextOut,
                consuming sending M.ValueOut,
                consuming sending M.ReaderOut,
                consuming sending M.SenderOut
            ) async throws -> Void
    ) {
        self.middleware = middleware
        self.body = body
    }

    func handle(
        request: HTTPRequest,
        requestContext: consuming M.RequestContextIn,
        reader: consuming sending M.ReaderIn,
        responseSender: consuming sending M.SenderIn
    ) async throws {
        try await self.middleware.intercept(
            request: request,
            requestContext: requestContext,
            value: (),
            reader: reader,
            responseSender: responseSender
        ) { req, ctx, value, body, sender in
            try await self.body(req, ctx, value, body, sender)
        }
    }
}
