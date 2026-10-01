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

/// A single stage in an HTTP request/response middleware pipeline.
///
/// ``HTTPServerMiddleware`` spreads the pieces of an HTTP exchange — the request
/// head, the request context, an optional carried value, the request body
/// reader, and the response sender — directly across the parameters of
/// ``intercept(request:requestContext:value:reader:responseSender:next:)``.
/// There is no currency "box" type bundling them together; a stage reads the
/// values it cares about and forwards the rest to `next`.
///
/// A stage may transform the request body reader type (``ReaderIn`` →
/// ``ReaderOut``) and/or the response sender type (``SenderIn`` →
/// ``SenderOut``) before calling `next` — for example by buffering the body
/// into a ``CollectedBodyReader`` or wrapping the sender with deadline
/// enforcement. A stage that passes either side through unchanged omits the
/// corresponding output type, which defaults to its input.
///
/// Reader types may be `~Escapable` so that intermediate stages can produce
/// lifetime-bound wrappers (e.g. slice readers or readers with a lifetime
/// dependency on their underlying source).
///
/// ``RequestContextIn`` is the per-request server-provided context type this stage
/// receives, mirroring `HTTPServerRequestHandler.RequestContext`.
///
/// ## Carrying a Value Across Stages
///
/// ``ValueIn`` and ``ValueOut`` form an optional channel for one stage to hand a
/// computed value to the next without that downstream stage re-deriving it. For
/// example, a content-length validation stage parses the `Content-Length` header
/// once and emits the parsed result; the buffering stage downstream consumes
/// that value as a precondition instead of re-parsing. Both default to `Void`,
/// so chains that don't use the value channel are unchanged.
///
/// A stage consumes the value as the `value:` parameter of its own `intercept`
/// (when ``ValueIn`` matches the upstream ``ValueOut``) or through a value-aware
/// or value-factory combinator (see below).
///
/// ## Combinators
///
/// Chain stages with ``then(_:)`` and close the chain with ``finally(_:)`` to
/// produce a fully-formed `HTTPServerRequestHandler`; the first stage runs
/// first. Each comes in four symmetric shapes — `then` supplies the next
/// *stage*, `finally` the terminal *handler*:
///
/// - **Conforming type** — a middleware (`then`) or handler (`finally`) that
///   conforms directly; for named, reusable stages.
/// - **Value-blind closure** — an inline closure that sees the exchange but not
///   the carried value, which passes through untouched.
/// - **Value-aware closure** — an inline closure that also receives the carried
///   ``ValueOut``.
/// - **Value factory** — `{ value in … }` builds the next stage / terminal from
///   the carried value, consuming the channel.
///
/// `then` closures receive a `next` to forward to — call it at most once, or
/// skip it to short-circuit. `finally` closures own the response and have no
/// `next`. A chain emitting a non-`Void` value must consume it — via a
/// value-aware or value-factory `finally` — before the chain can close.
///
/// ## Conformance Contract
///
/// - `intercept` must call `next` **at most once**. A stage that short-circuits the
///   exchange (e.g. sends an error response itself) must not call `next`.
/// - Ownership of `requestContext`, `value`, `reader`, and `responseSender`
///   transfers into `intercept`. On any path that calls `next`, the stage forwards
///   (possibly transformed) request body and response sender values into it
///   exactly once, along with the request context and value.
@available(anyAppleOS 26.0, *)
public protocol HTTPServerMiddleware<
    RequestContextIn,
    RequestContextOut,
    ValueIn,
    ValueOut,
    ReaderIn,
    ReaderOut,
    SenderIn,
    SenderOut
>: Sendable {
    /// The per-request context type this stage receives.
    associatedtype RequestContextIn: HTTPServerCapability.RequestContext, ~Copyable

    /// The per-request context type passed to the next stage.
    ///
    /// Defaults to ``RequestContextIn`` for stages that leave the context untouched.
    associatedtype RequestContextOut: HTTPServerCapability.RequestContext, ~Copyable =
        RequestContextIn

    /// The carried value type this stage receives from the previous stage.
    ///
    /// Defaults to `Void` for stages that don't consume an upstream value.
    associatedtype ValueIn: ~Copyable = Void

    /// The carried value type this stage hands to the next stage.
    ///
    /// Defaults to ``ValueIn`` for stages that pass the value through unchanged.
    associatedtype ValueOut: ~Copyable = ValueIn

    /// The request body reader type this stage accepts.
    associatedtype ReaderIn: AsyncReader & ~Copyable & ~Escapable
    where ReaderIn.ReadElement == UInt8, ReaderIn.FinalElement == HTTPFields?

    /// The request body reader type passed to the next stage.
    ///
    /// Defaults to ``ReaderIn`` for stages that leave the request body
    /// untouched.
    associatedtype ReaderOut: AsyncReader & ~Copyable & ~Escapable = ReaderIn
    where ReaderOut.ReadElement == UInt8, ReaderOut.FinalElement == HTTPFields?

    /// The response sender type this stage accepts.
    associatedtype SenderIn: HTTPResponseSender & ~Copyable
    where SenderIn.Writer: ~Copyable

    /// The response sender type passed to the next stage.
    ///
    /// Defaults to ``SenderIn`` for stages that leave the response sender
    /// untouched.
    associatedtype SenderOut: HTTPResponseSender & ~Copyable = SenderIn
    where SenderOut.Writer: ~Copyable

    /// Intercepts an HTTP exchange, optionally transforms the carried value,
    /// request body reader, and/or response sender, then forwards control to the
    /// next stage.
    ///
    /// - Parameters:
    ///   - request: The request head.
    ///   - requestContext: Per-request context.
    ///   - value: The carried value handed in by the previous stage, or `()` if
    ///     this is the first stage in the chain.
    ///   - reader: The request body reader.
    ///   - responseSender: The response sender.
    ///   - next: The next stage in the pipeline. Call at most once, passing the
    ///     request context, the (possibly transformed) carried value, and the
    ///     (possibly transformed) request body and response sender.
    /// - Throws: Rethrows errors from `next`, or any error raised while handling the
    ///   exchange.
    func intercept(
        request: HTTPRequest,
        requestContext: consuming RequestContextIn,
        value: consuming sending ValueIn,
        reader: consuming sending ReaderIn,
        responseSender: consuming sending SenderIn,
        next: (
            HTTPRequest,
            consuming RequestContextOut,
            consuming sending ValueOut,
            consuming sending ReaderOut,
            consuming sending SenderOut
        ) async throws -> Void
    ) async throws
}
