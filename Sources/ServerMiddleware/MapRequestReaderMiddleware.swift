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

/// A middleware that transforms only the request reader and forwards the rest
/// of the pipeline unchanged.
///
/// Produced by the ``HTTPServerMiddleware/mapRequestReader(_:)`` combinator;
/// callers do not name this type directly.
@available(anyAppleOS 26.0, *)
struct MapRequestReaderMiddleware<
    Context: HTTPServerCapability.RequestContext & ~Copyable,
    Value: ~Copyable,
    In: AsyncReader & ~Copyable & ~Escapable,
    Out: AsyncReader & ~Copyable & ~Escapable,
    Sender: HTTPResponseSender & ~Copyable
>: HTTPServerMiddleware, Sendable
where
    In.ReadElement == UInt8,
    In.FinalElement == HTTPFields?,
    Out.ReadElement == UInt8,
    Out.FinalElement == HTTPFields?,
    Sender.Writer: ~Copyable
{
    typealias RequestContextIn = Context
    typealias ValueIn = Value
    typealias ValueOut = Value
    typealias ReaderIn = In
    typealias ReaderOut = Out
    typealias SenderIn = Sender
    typealias SenderOut = Sender

    private let transform: @Sendable (consuming sending In) -> sending Out

    init(_ transform: @escaping @Sendable (consuming sending In) -> sending Out) {
        self.transform = transform
    }

    func intercept(
        request: HTTPRequest,
        requestContext: consuming Context,
        value: consuming sending Value,
        reader: consuming sending In,
        responseSender: consuming sending Sender,
        next: (
            HTTPRequest,
            consuming Context,
            consuming sending Value,
            consuming sending Out,
            consuming sending Sender
        ) async throws -> Void
    ) async throws {
        let transformed = self.transform(reader)
        try await next(request, requestContext, value, transformed, responseSender)
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
    /// Chains a request-reader transform onto this stage, returning a new
    /// middleware whose `ReaderOut` is whatever the closure returns.
    ///
    /// Use this to wrap the request reader inline without defining a named
    /// middleware struct:
    ///
    /// ```swift
    /// timeoutMiddleware
    ///   .mapRequestReader { $0.withElementCount(.max(4096)) }
    ///   .finally(EchoHandler())
    /// ```
    ///
    /// The closure runs once per request and is invoked with the reader produced
    /// by this stage's `ReaderOut`. The returned reader becomes the
    /// downstream stage's input.
    public func mapRequestReader<NewReader: AsyncReader & ~Copyable & ~Escapable>(
        _ transform:
            @escaping @Sendable (consuming sending ReaderOut) -> sending NewReader
    ) -> some HTTPServerMiddleware<
        Self.RequestContextIn, RequestContextOut,
        Self.ValueIn, ValueOut,
        Self.ReaderIn, NewReader,
        Self.SenderIn, SenderOut
    >
    where
        Self: Sendable,
        NewReader.ReadElement == UInt8,
        NewReader.FinalElement == HTTPFields?
    {
        let mapper:
            MapRequestReaderMiddleware<
                RequestContextOut, ValueOut, ReaderOut, NewReader, SenderOut
            > = MapRequestReaderMiddleware(transform)
        return self.then(mapper)
    }
}
