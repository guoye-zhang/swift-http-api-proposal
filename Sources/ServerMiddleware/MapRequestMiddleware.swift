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
    /// Chains a request-head transform onto this stage, mutating the request head
    /// before it is handed to the next stage. Value, reader, sender, and context
    /// pass through unchanged.
    ///
    /// Mirrors ``mapResponse(_:)`` on the request side; to transform the request
    /// body reader use ``mapRequestReader(_:)``.
    ///
    /// ```swift
    /// existingMiddleware
    ///   .mapRequest { $0.headerFields[.init("X-Request-ID")!] = UUID().uuidString }
    ///   .finally(EchoHandler())
    /// ```
    public func mapRequest(
        _ transform: @escaping @Sendable (inout HTTPRequest) -> Void
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, ReaderOut,
        Self.SenderIn, SenderOut
    >
    where Self: Sendable {
        self.then { request, context, value, body, sender, next in
            var request = request
            transform(&request)
            try await next(request, context, value, body, sender)
        }
    }
}
