# Resumable upload server middleware

`HTTPServerResumableUploadMiddleware` implements resumable uploads for servers. It supports two
interop versions of the resumable upload internet-draft:

- Interop version 6
  ([draft-ietf-httpbis-resumable-upload-05](https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-resumable-upload-05)),
  which is the version `URLSession` supports today.
- Interop version 10, the
  [latest draft](https://httpwg.org/http-extensions/draft-ietf-httpbis-resumable-upload.html).

Each request is handled according to the version in its `Upload-Draft-Interop-Version` field,
and responses use the same version. The two versions behave the same except where noted under
[Version differences](#version-differences). The implementation is modeled after
`NIOResumableUpload` in swift-nio-extras.

The handler behind the middleware sees each resumable upload as one ordinary request. Its body
is the entire upload, even when the client sends it over several HTTP requests after
interruptions.

## Usage

```swift
let context = HTTPResumableUploadContext(origin: "https://example.com")
let handler = MiddlewareBuilder<RequestContext, Reader, ResponseSender>()
    .withResumableUpload(context: context)
    .finally { request, requestContext, reader, responseSender in
        // Read the entire upload from `reader`, then respond with `responseSender`.
    }
```

Share one `HTTPResumableUploadContext` across all connections of a server. It owns the table of
ongoing uploads.

## Middleware shape

The middleware is built on the `ServerMiddleware` module (`Sources/ServerMiddleware`). That
module is copied from the `HTTPMiddlewareFramework` module in private-relay-proxy. In that
shape:

- `intercept` returns `Void`.
- A stage hands off to the next stage by calling `next`, at most once, and short-circuits by
  not calling it.
- The request, context, value, body reader, and response sender are separate parameters, passed
  as `consuming sending`.

The middleware relies on short-circuiting, so it does not use the `Middleware` module, whose
middlewares must return the value produced by the rest of the chain.

The stage replaces the reader with `HTTPResumableUploadReader` and the response sender with
`HTTPResumableUploadResponseSender`. For requests that are not part of an upload, both forward
to the original reader and sender.

## Request handling

`HTTPResumableUploadProtocol.identifyRequest` classifies each request:

| Request | Handled by | Behavior |
| --- | --- | --- |
| No `Upload-Draft-Interop-Version` field, or no valid `Upload-Complete` field outside the resumption path | Next stage | Passed through unchanged. |
| `OPTIONS` | Next stage | `Upload-Draft-Interop-Version` and `Upload-Limit: min-size=0` are added to the response. A 501 response becomes 200. |
| Upload creation (any method with `Upload-Complete`) | Next stage | Sends 104 with `Location`, then hands the upload to the next stage. |
| `HEAD` or `GET` on the resumption path | This stage | 204 with `Upload-Offset`, `Upload-Complete`, `Upload-Length`, `Upload-Limit: min-size=0`, and `Cache-Control: no-store`. Detaches any request that is still attached. |
| `PATCH` on the resumption path | This stage | Attaches to the upload. Requires `Upload-Offset` and `Content-Type: application/partial-upload`. Version 10 also requires `Upload-Complete`; version 6 treats a missing one as `?1`. |
| `DELETE` on the resumption path | This stage | Cancels the upload and responds with 204. |
| Unknown upload on the resumption path | This stage | 404. |
| Offset or length mismatch, an upload that is already complete, or another request still attached | This stage | 409 with the current offset and `Upload-Complete: ?0`. |
| Unsupported interop version, a required field that is missing, or another method on the resumption path | This stage | 400. A 400 for an unsupported version has no `Upload-Draft-Interop-Version`. |

The protocol fields are structured fields, parsed and serialized with `StructuredFieldValues`
from swift-http-structured-headers, as in `NIOResumableUpload`. Fields with invalid values, such
as `Upload-Complete: yes` or a negative `Upload-Offset`, are ignored as if they were absent.
Both drafts require this.

Resumption URLs are `origin + path + token`. The path defaults to `/resumable_upload/`, and the
token is random.

Before calling the next stage, the creation request has its protocol fields removed.
`Content-Length` is replaced with the full upload length if that is known, and removed
otherwise.

### Version differences

The only difference between the versions is whether `PATCH` requires `Upload-Complete` (see the
table above).

Both versions process the next stage's response the same way:

- `Upload-Complete` is always `?1`, because the response comes from the targeted resource, even
  if it responded before receiving the entire upload. This is how version 10 defines the field.
  Version 6 defines it as whether the entire upload was received, but version 6 clients also stop
  uploading when they receive `?1`.
- `Location` is left as the next stage set it. Version 10 exempts these responses from carrying
  the upload URL. Version 6 expects it, but a 2xx response from the next stage is unlikely to
  have a `Location` of its own.

## Design

### The upload and its attachments

`HTTPResumableUpload` is a single logical upload. It is guarded by a `Mutex` and carries data in
both directions:

- **Body:** the attached request calls `send(body:)` and the next stage calls `receiveBody()`.
  Each handoff waits for the other side, so the upload is never buffered beyond one chunk.
- **Response:** the next stage calls `send(response:)` and the attached request calls
  `receiveResponsePart()`. If no request is attached, the response waits until the client
  resumes. Informational (1xx) responses go only to the request attached when the next stage
  sends them. If no request is attached, or the final response has started, they are dropped.

Each request that carries upload data (the creation request or a `PATCH`) *attaches* to the
upload. At most one request is attached at a time. Every attachment gets a new generation
number, so a request that was superseded can no longer affect the upload. For example, the
client may resume on a new connection after the server failed to notice the old one dropped.

Once the attached request receives the response head, it is *responding*:

- It keeps the response even after its body ends or a `HEAD` request detaches it.
- No other request can attach (409).
- No resumption timeout is scheduled, because the client stops the upload once it receives the
  response. If the request's body ends before the entire upload, the next stage's further body
  reads fail with `uploadIncomplete`.

### Running the next stage

The next stage runs in the task of the creation request. The creation request's handler
therefore stays running until the entire upload has been processed, even if that request's own
connection was interrupted long before.

The creation request uses `async let` to run its attachment concurrently with `next`.
`SendingBox` moves the `sending` reader and response sender into that child task. It hands each
value out exactly once, so the region-based isolation checker can still prove that the values
passed to `next` are disconnected.

Another `async let` child task enforces the resumption timeout. When a request detaches and the
client may resume, the upload records a deadline. The child task sleeps until the deadline and
fails the upload if no request has attached by then. The child task is cancelled when the
creation request's handler returns, so the middleware creates no unstructured tasks.

### Serving an attached request

`HTTPResumableUploadAttachment.serve` runs two jobs concurrently:

- **`pumpBody`** feeds the request body into the upload. When the body ends:
  - If the request has `Upload-Complete: ?1`, it sends the end of the upload.
  - Otherwise it detaches with `acknowledge: true`.

  If the connection fails, it detaches with `acknowledge: false`.
- **`respond`** waits for the response:
  - It forwards informational responses from the next stage unchanged. A failure to send one is
    ignored.
  - If the next stage produces a head, `respond` adds `Upload-Draft-Interop-Version`,
    `Upload-Complete`, and `Upload-Offset`, then relays the response body.
  - If the request was detached with `acknowledge: true` (`AttachmentSignal.incomplete`) before
    the head, it responds with 201 and the current offset so that the client sends the next
    part.
  - If the request was superseded or interrupted (`AttachmentSignal.detached`), it sends
    nothing.
  - If the upload failed because of the client, it responds with 400. If the next stage threw
    without responding, it responds with 500.

Running both jobs concurrently prevents a deadlock when the next stage responds before it has
read the whole body.

### Failure and cleanup

The upload ends, and is removed from the context, when any of these happen:

- the next stage returns (`uploadFinished`) or throws;
- the client cancels it (`uploadCancelled`);
- the client sends more than the declared length (`uploadLengthExceeded`);
- relaying the response fails;
- no request attaches within the context's timeout, which defaults to one hour
  (`timeoutWaitingForResumption`).

When the upload ends, every pending operation fails with the same error.

## Limitations

- **Lost early responses:** if the connection drops while a response is being relayed, the
  upload fails. The response is not replayed to a later request, which the latest draft allows.
- **Informational responses between parts:** 1xx responses from the next stage are dropped
  while no request is attached. A `100 (Continue)` is forwarded even to a `PATCH` that didn't
  send `Expect: 100-continue`.
- **Copies:** the reader and writer accept any buffer type, so each chunk is copied once into a
  `UniqueArray`: request body chunks (including for requests that pass through) and upload
  response chunks. That array is then moved between tasks without further copies, through the
  upload's state, because continuations can't carry non-copyable values.
- **Long-running creation request:** the creation request's handler doesn't return until the
  upload ends. It may wait up to the context's timeout for the client to resume.
- **In-memory state:** uploads live in a single `HTTPResumableUploadContext`. They don't survive
  a restart and can't be shared across processes. A load balancer has to route resumptions to
  the same server.
- **Spec versions:** only interop versions 6 and 10 are accepted. Version 6 follows
  `NIOResumableUpload` rather than an independent reading of the draft.
- **Optional features of version 10:** none of these are implemented:
  - 104 progress responses carrying `Upload-Offset`;
  - limits other than `min-size=0`, such as `max-size` or `max-age`;
  - problem-type response bodies;
  - rejecting inconsistent lengths with 400 (409 is used instead).

  Incomplete appends respond with 201, as in version 6, where the version 10 examples show 204.
- **Other examples:** the other server examples (`HTTPServerLoggingMiddleware`,
  `HTTPServerRequestHandlerMiddleware`, and `MiddlewareServer`) still use the `Middleware`
  module rather than `ServerMiddleware`.

## Tests

`Tests/ExampleMiddlewareTests/HTTPServerResumableUploadMiddlewareTests.swift` uses in-memory
readers and senders to cover:

- passthrough;
- an upload completed in one request;
- resuming after an interruption (with `HEAD` and `PATCH`);
- an upload sent in several parts, including appends that conflict on offset or length;
- cancellation;
- `HEAD` while a stalled request is attached, before and after it started responding;
- the resumption timeout;
- a body longer than the declared upload length;
- invalid requests;
- `OPTIONS`;
- an early response to a request with `Upload-Complete: ?0`, in both versions;
- informational responses, in one request and across parts;
- version 10: an upload in one request, an upload in several parts with `GET`, a `PATCH` without
  `Upload-Complete`, and invalid field values.
