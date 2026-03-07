# Swift HTTP Client API

* Proposal: [SE-NNNN](NNNN-swift-http-client.md)
* Authors: [Swift Networking Workgroup](https://github.com/apple/swift-http-api-proposal)
* Review Manager: TBD
* Status: **Awaiting implementation**
* Implementation: [apple/swift-http-api-proposal](https://github.com/apple/swift-http-api-proposal)
* Review: ([pitch](https://forums.swift.org/...))

## Summary of changes

Introduces a unified, cross-platform HTTP Client API for Swift that leverages modern concurrency features, supports streaming bodies and trailers, enables dependency injection through protocol abstraction, and provides progressive disclosure from simple to advanced use cases.

## Motivation

HTTP is the internet's foundational application-layer protocol, yet the Swift ecosystem lacks a standardized, modern HTTP Client API that takes full advantage of Swift's evolving language capabilities. Current solutions like URLSession and AsyncHTTPClient were designed before Swift concurrency and carry legacy patterns that are no longer recommended.

### Problems with existing solutions

**URLSession** was designed before Swift concurrency and includes patterns that are now outdated:
- Delegate queue pattern with deep object hierarchies
- Callback-based APIs that don't integrate naturally with async/await
- Platform-specific to Apple platforms
- Limited streaming support
- Mixes HTTP concerns with other URL schemes (file://, data://, custom schemes)

**AsyncHTTPClient** relies heavily on NIO EventLoop and:
- Requires understanding of EventLoop threading model
- Less natural integration with Swift's structured concurrency
- Primarily designed for server-side use cases

Both APIs present challenges for:
- Library authors who want platform-agnostic code without depending on specific implementations
- Middleware developers who want to extend HTTP client functionality
- App developers who need simple APIs for common cases but full power for advanced scenarios
- Developers targeting multiple platforms (Apple, Linux, Windows, etc.)

### Use cases driving the design

1. **App developers** need simple, safe APIs for common HTTP requests with sensible defaults
2. **Library authors** need protocol abstractions to avoid coupling to specific HTTP client implementations
3. **Middleware developers** need extension points to add cross-cutting concerns like logging, metrics, and retry logic
4. **Advanced users** need access to HTTP features like bidirectional streaming, trailers, resumable uploads, and fine-grained control

## Proposed solution

We propose a new HTTP Client API built on three foundational pieces:

1. **Abstract protocol interface** (`HTTPClient`) for dependency injection and testability
2. **Convenience methods** for common use cases with progressive disclosure
3. **Platform-default implementations** optimized for each platform

### Core protocol

The `HTTPClient` protocol provides a single `perform` method that handles all HTTP interactions:

```swift
public protocol HTTPClient<RequestOptions>: ~Copyable {
    associatedtype RequestOptions: HTTPClientCapability.RequestOptions
    associatedtype RequestWriter: AsyncWriter
    associatedtype ResponseConcludingReader: ConcludingAsyncReader

    var defaultRequestOptions: RequestOptions { get }

    func perform<Return: ~Copyable>(
        request: HTTPRequest,
        body: consuming HTTPClientRequestBody<RequestWriter>?,
        options: RequestOptions,
        responseHandler: (HTTPResponse, consuming ResponseConcludingReader) async throws -> Return
    ) async throws -> Return
}
```

### Request and response bodies

Request bodies support streaming, trailers, and restarting (for redirects and authentication challenges):

```swift
public struct HTTPClientRequestBody<Writer>: Sendable {
    public static func restartable(
        knownLength: Int64? = nil,
        _ body: @escaping @Sendable (consuming Writer) async throws -> HTTPFields?
    ) -> Self

    public static func seekable(
        knownLength: Int64? = nil,
        _ body: @escaping @Sendable (Int64, consuming Writer) async throws -> HTTPFields?
    ) -> Self
}

extension HTTPClientRequestBody {
    public static func data(_ data: Data) -> Self
}
```

### Capability-based request options

Configuration is modeled through capability protocols, allowing clients to advertise supported features:

```swift
public enum HTTPClientCapability {
    public protocol RequestOptions {}

    public protocol TLSVersionSelection: RequestOptions {
        var minimumTLSVersion: TLSVersion { get set }
        var maximumTLSVersion: TLSVersion { get set }
    }
}
```

### Platform default implementation

Simple HTTP requests use static methods on the `HTTP` enum:

```swift
import HTTPClient

// Simple GET request
let (response, data) = try await HTTP.get(url, collectUpTo: .max)

// Advanced usage with streaming
try await HTTP.perform(request: request) { response, body in
    guard response.status == .ok else {
        throw MyNetworkingError.badResponse(response)
    }

    // Stream the response body
    let (_, trailers) = try await body.collect(upTo: 1024 * 1024) { span in
        print("Received \(span.count) bytes")
    }

    if let trailers = trailers {
        print("Trailers: \(trailers)")
    }
}
```

### Benefits over current solutions

1. **Swift-first design**: Built from the ground up for Swift concurrency and modern language features like `~Copyable` and `~Escapable`
2. **Progressive disclosure**: Simple cases are simple; advanced features don't require rewrites
3. **Cross-platform**: Single API works on all Swift platforms with platform-optimized implementations
4. **Dependency injection**: Protocol abstraction enables testing and library modularity
5. **Streaming first**: Full support for bidirectional streaming, trailers, and resumable uploads
6. **Performance**: Designed to allow efficient implementations expected of a systems language

## Detailed design

### Module structure

The proposal consists of several interconnected modules:

- **AsyncStreaming**: Modern streaming primitives based on `~Copyable`, `~Escapable`, and structured concurrency
- **NetworkTypes**: Basic cross-platform network configuration types (e.g., `TLSVersion`)
- **HTTPAPIs**: Protocol definitions for `HTTPClient` and shared types
- **HTTPClient**: Platform-default HTTP client implementation
- **URLSessionHTTPClient**: URLSession-based implementation for Apple platforms
- **AHCHTTPClient**: AsyncHTTPClient-based implementation

### HTTPClient protocol

```swift
public protocol HTTPClient<RequestOptions>: ~Copyable {
    associatedtype RequestOptions: HTTPClientCapability.RequestOptions
    associatedtype RequestWriter: AsyncWriter
    associatedtype ResponseConcludingReader: ConcludingAsyncReader

    var defaultRequestOptions: RequestOptions { get }

    func perform<Return: ~Copyable>(
        request: HTTPRequest,
        body: consuming HTTPClientRequestBody<RequestWriter>?,
        options: RequestOptions,
        responseHandler: (HTTPResponse, consuming ResponseConcludingReader) async throws -> Return
    ) async throws -> Return
}
```

**Key design decisions:**

- `~Copyable` conformance enables efficient resource management and exclusive ownership
- `HTTPRequest` and `HTTPResponse` from swift-http-types package provide standardized HTTP representations
- `RequestWriter` enables streaming request bodies with platform-specific buffer types
- `ResponseConcludingReader` provides streaming response bodies with optional trailers
- `responseHandler` closure receives both response headers and body stream for efficient processing

### Request body

```swift
public struct HTTPClientRequestBody<Writer>: Sendable where Writer: AsyncWriter {
    /// Create a restartable request body that can be retransmitted upon redirects or auth challenges
    public static func restartable(
        knownLength: Int64? = nil,
        _ body: @escaping @Sendable (consuming Writer) async throws -> HTTPFields?
    ) -> Self

    /// Create a seekable request body that supports resumable uploads
    public static func seekable(
        knownLength: Int64? = nil,
        _ body: @escaping @Sendable (Int64, consuming Writer) async throws -> HTTPFields?
    ) -> Self
}

extension HTTPClientRequestBody {
    public static func data(_ data: Data) -> Self
}
```

**Design rationale:**

- Restartable bodies support HTTP redirects and authentication challenges
- Seekable bodies enable resumable uploads by accepting a starting offset
- Closure-based design allows lazy generation of body content
- Trailer support via optional `HTTPFields` return value
- `knownLength` parameter enables Content-Length header and progress tracking

### Request options and capabilities

```swift
public enum HTTPClientCapability {
    public protocol RequestOptions {}

    public protocol TLSVersionSelection: RequestOptions {
        var minimumTLSVersion: TLSVersion { get set }
        var maximumTLSVersion: TLSVersion { get set }
    }

    public protocol RedirectionHandler: RequestOptions {
        var redirectionHandler: HTTPClientRedirectionHandler? { get set }
    }

    public protocol ServerTrustHandler: RequestOptions {
        var serverTrustHandler: HTTPClientServerTrustHandler? { get set }
    }
}
```

**Capability pattern benefits:**

- Clients advertise supported features through protocol conformance
- Library code can require specific capabilities via generic constraints
- Future capabilities can be added without breaking existing clients
- Clear separation between core functionality and optional features

### Convenience methods

```swift
extension HTTPClient {
    public func get(
        url: URL,
        headerFields: HTTPFields = [:],
        options: RequestOptions? = nil,
        collectUpTo limit: Int
    ) async throws -> (response: HTTPResponse, bodyData: Data)

    public func post(
        url: URL,
        headerFields: HTTPFields = [:],
        body: Data,
        options: RequestOptions? = nil,
        collectUpTo limit: Int
    ) async throws -> (response: HTTPResponse, bodyData: Data)
}
```

These methods handle common patterns while preserving access to the full `perform` API for advanced cases.

### Default platform implementation

```swift
public struct DefaultHTTPClient: HTTPClient, Sendable, ~Copyable {
    public static var shared: DefaultHTTPClient { get }

    public static func withClient<Return: ~Copyable, E: Error>(
        poolConfiguration: HTTPConnectionPoolConfiguration,
        body: (DefaultHTTPClient) async throws(E) -> Return
    ) async throws(E) -> Return
}

enum HTTP {
    public static func perform<Client: HTTPClient, Return>(
        request: HTTPRequest,
        body: consuming HTTPClientRequestBody<Client.RequestWriter>? = nil,
        options: Client.RequestOptions? = nil,
        on client: Client = DefaultHTTPClient.shared,
        responseHandler: (HTTPResponse, consuming Client.ResponseConcludingReader) async throws -> Return
    ) async throws -> Return

    public static func get(
        url: URL,
        headerFields: HTTPFields = [:],
        options: DefaultHTTPClient.RequestOptions? = nil,
        collectUpTo limit: Int,
        on client: DefaultHTTPClient = .shared
    ) async throws -> (response: HTTPResponse, bodyData: Data)
}
```

**Implementation strategy:**

- On Apple platforms: URLSession-based implementation
- On other platforms: AsyncHTTPClient-based implementation
- Connection pooling controlled via `HTTPConnectionPoolConfiguration`
- Shared instance for simple use cases
- Scoped instances for isolated connection pools

## Source compatibility

This proposal is purely additive and introduces new API surface. It does not modify or deprecate any existing Swift APIs, so there is no impact on source compatibility.

## ABI compatibility

This proposal is purely an extension of the Swift ecosystem with new packages and does not modify any existing ABI.

The new APIs are designed to be ABI-stable once finalized, with implementation details hidden behind protocol abstractions. Platform-specific implementations (URLSession-based, AsyncHTTPClient-based) can evolve independently without breaking ABI.

## Implications on adoption

### Deployment requirements

- The core `HTTPClient` protocol and convenience methods can be back-deployed as a Swift package
- Platform-default implementations may have minimum platform requirements:
  - URLSession implementation: iOS 26.2
  - AsyncHTTPClient implementation: Swift 6.2
- Libraries depending only on the `HTTPClient` protocol can support older platforms if users provide compatible implementations

### Library adoption considerations

- Library authors can freely adopt `HTTPClient` protocol as a dependency
- Adding `HTTPClient` conformance to a type is ABI-additive
- Libraries can expose protocol-based APIs without coupling to specific implementations
- Middleware can be added and removed without breaking changes

### Package versioning

This feature can be adopted through Swift Package Manager with appropriate versioning:
- Initial release will be marked as pre-1.0 during evolution review
- Breaking changes to protocols or core types will require major version bumps
- Platform implementations can evolve independently with appropriate `@available` annotations

## Future directions

### URLClient abstraction

While `HTTPClient` focuses exclusively on HTTP/HTTPS, a future `URLClient` protocol could be built on top to support additional URL schemes (file://, data://, custom schemes). This separation keeps `HTTPClient` focused and simple.

### Background transfer API

Background URLSession supports system-scheduled uploads, downloads, and media asset downloads. The current streaming-based design is not suitable for file-based background transfers. A future manifest-based bulk transfer API could manage uploads and downloads both in-process and out-of-process, complementing `HTTPClient` for different use cases.

### WebSocket support

WebSocket connections upgrade from HTTP but have significantly different semantics. A separate `WebSocketClient` API could be designed in the future, potentially sharing some abstractions with `HTTPClient`.

### Middleware standardization

While the repository explores middleware patterns, standardizing middleware protocols for HTTP clients could be addressed in a follow-up proposal, enabling composable request/response transformations.

## Alternatives considered

### Extending URLSession

Rather than creating a new API, we could modernize URLSession with async/await wrappers and streaming support.

**Advantages:**
- Familiar API for Apple platform developers
- Incremental migration path

**Disadvantages:**
- URLSession's delegate-based architecture doesn't map well to structured concurrency
- Deep object hierarchies and platform-specific behaviors are hard to abstract
- Supporting non-Apple platforms would require re-implementing URLSession semantics
- Mixing HTTP with other URL schemes complicates the abstraction
- ABI stability constraints limit evolution

### Standardizing AsyncHTTPClient

We could promote AsyncHTTPClient to be the standard Swift HTTP client across all platforms.

**Advantages:**
- Proven in production server-side use
- Already cross-platform

**Disadvantages:**
- EventLoop model doesn't align with structured concurrency
- NIO dependency is heavyweight for client applications
- Apple platform optimizations (URLSession networking stack) would be lost
- Not designed for progressive disclosure from simple to advanced use cases

We believe the proposed design strikes the right balance between simplicity and power, providing progressive disclosure while enabling all HTTP features.
