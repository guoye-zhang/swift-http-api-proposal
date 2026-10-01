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

import HTTPAPIs
import StructuredFieldValues

/// Implements interop versions 6 and 10 of the resumable upload internet-draft.
///
/// Draft documents:
/// - Interop version 6, the version supported by `URLSession`:
///   https://datatracker.ietf.org/doc/draft-ietf-httpbis-resumable-upload/05/
/// - Interop version 10, the latest version:
///   https://httpwg.org/http-extensions/draft-ietf-httpbis-resumable-upload.html
@available(anyAppleOS 26.0, *)
enum HTTPResumableUploadProtocol {
    /// The interop version of the draft implemented by a client.
    ///
    /// Responses use the interop version of the request they respond to.
    enum Version: Int64, Sendable {
        case v6 = 6
        case v10 = 10
    }

    /// The current progress of an upload, reported back to the client.
    struct Status: Sendable {
        var offset: Int64
        var complete: Bool
        var uploadLength: Int64?
    }

    enum RequestType {
        case uploadCreation(complete: Bool, contentLength: Int64?, uploadLength: Int64?)
        case offsetRetrieving(path: String)
        case uploadAppending(path: String, offset: Int64, complete: Bool, contentLength: Int64?, uploadLength: Int64?)
        case uploadCancellation(path: String)
        case options
    }

    struct InvalidRequestError: Error {
        /// The interop version of the request, if supported.
        var version: Version?
    }

    /// Classifies a request.
    ///
    /// - Returns: `nil` if the request is not part of the resumable upload protocol.
    /// - Throws: `InvalidRequestError` if the request is malformed.
    static func identifyRequest(
        _ request: HTTPRequest,
        in context: HTTPResumableUploadContext
    ) throws(InvalidRequestError) -> (version: Version, type: RequestType)? {
        guard request.headerFields[.uploadDraftInteropVersion] != nil else {
            return nil
        }
        guard let version = request.headerFields.uploadDraftInteropVersion.flatMap(Version.init) else {
            throw InvalidRequestError(version: nil)
        }
        // Fields with invalid values are ignored.
        let complete = request.headerFields.uploadComplete
        let offset = request.headerFields.uploadOffset
        let uploadLength = request.headerFields.uploadLength
        let contentLength = request.headerFields[.contentLength].flatMap(Int64.init)

        if request.method == .options {
            guard complete == nil && offset == nil && uploadLength == nil else {
                throw InvalidRequestError(version: version)
            }
            return (version, .options)
        }
        if let path = request.path, context.isResumption(path: path) {
            switch request.method {
            case .head, .get:
                guard complete == nil && offset == nil && uploadLength == nil else {
                    throw InvalidRequestError(version: version)
                }
                return (version, .offsetRetrieving(path: path))
            case .patch:
                // Interop version 6 treats a missing `Upload-Complete` as completing the upload.
                guard let offset, let complete = complete ?? (version == .v6 ? true : nil),
                    request.headerFields[.contentType] == "application/partial-upload"
                else {
                    throw InvalidRequestError(version: version)
                }
                return (
                    version,
                    .uploadAppending(
                        path: path,
                        offset: offset,
                        complete: complete,
                        contentLength: contentLength,
                        uploadLength: uploadLength
                    )
                )
            case .delete:
                guard complete == nil && offset == nil && uploadLength == nil else {
                    throw InvalidRequestError(version: version)
                }
                return (version, .uploadCancellation(path: path))
            default:
                throw InvalidRequestError(version: version)
            }
        }
        guard let complete else {
            return nil
        }
        if let offset, offset != 0 {
            throw InvalidRequestError(version: version)
        }
        return (version, .uploadCreation(complete: complete, contentLength: contentLength, uploadLength: uploadLength))
    }

    /// Removes the protocol fields from an upload creation request before handing it to the
    /// next middleware, which sees the entire upload as a single request.
    static func stripRequest(_ request: HTTPRequest, uploadLength: Int64?) -> HTTPRequest {
        var request = request
        request.headerFields[.uploadDraftInteropVersion] = nil
        request.headerFields[.uploadComplete] = nil
        request.headerFields[.uploadOffset] = nil
        // The original `Content-Length` only covers the first part of an incomplete upload.
        request.headerFields[.contentLength] = uploadLength.map { "\($0)" }
        return request
    }

    static func featureDetectionResponse(location: String, version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .init(code: 104, reasonPhrase: "Upload Resumption Supported"))
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields[.location] = location
        return response
    }

    static func offsetRetrievingResponse(status: Status, version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .noContent)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields.uploadComplete = status.complete
        response.headerFields.uploadOffset = status.offset
        response.headerFields.uploadLength = status.uploadLength
        // Required since interop version 10, and allowed before.
        response.headerFields.uploadLimit = .init(minSize: 0)
        response.headerFields[.cacheControl] = "no-store"
        return response
    }

    static func incompleteResponse(status: Status, location: String?, version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .created)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields[.location] = location
        response.headerFields.uploadComplete = false
        response.headerFields.uploadOffset = status.offset
        return response
    }

    static func cancelledResponse(version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .noContent)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        return response
    }

    static func notFoundResponse(version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .notFound)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields[.contentLength] = "0"
        return response
    }

    static func conflictResponse(status: Status, version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .conflict)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        // The rejected request didn't complete the upload, even if an earlier request did.
        response.headerFields.uploadComplete = false
        response.headerFields.uploadOffset = status.offset
        response.headerFields[.contentLength] = "0"
        return response
    }

    /// - Parameter version: The interop version of the request, or `nil` if it is unsupported.
    static func badRequestResponse(version: Version?) -> HTTPResponse {
        var response = HTTPResponse(status: .badRequest)
        response.headerFields.uploadDraftInteropVersion = version?.rawValue
        response.headerFields[.contentLength] = "0"
        return response
    }

    static func internalServerErrorResponse(version: Version) -> HTTPResponse {
        var response = HTTPResponse(status: .internalServerError)
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields[.contentLength] = "0"
        return response
    }

    /// Adds the protocol fields to the response produced by the next middleware.
    ///
    /// The response keeps its own `Location`, if any. Interop version 10 exempts responses from
    /// the targeted resource from carrying the upload URL.
    static func processResponse(
        _ response: HTTPResponse,
        status: Status,
        version: Version
    ) -> HTTPResponse {
        var response = response
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        // `Upload-Complete` reports that the response comes from the targeted resource, even if
        // it responded before receiving the entire upload. Interop version 10 defines it this way.
        // Version 6 defines it as whether the entire upload was received, but its clients also
        // stop the upload on `?1`, so the same value is used for all versions.
        response.headerFields.uploadComplete = true
        response.headerFields.uploadOffset = status.offset
        return response
    }

    /// Advertises resumable upload support in the response to an `OPTIONS` request.
    static func processOptionsResponse(_ response: HTTPResponse, version: Version) -> HTTPResponse {
        var response = response
        if response.status == .notImplemented {
            response = HTTPResponse(status: .ok)
        }
        response.headerFields.uploadDraftInteropVersion = version.rawValue
        response.headerFields.uploadLimit = .init(minSize: 0)
        return response
    }

}

extension HTTPField.Name {
    fileprivate static let uploadDraftInteropVersion = Self("Upload-Draft-Interop-Version")!
    fileprivate static let uploadComplete = Self("Upload-Complete")!
    fileprivate static let uploadOffset = Self("Upload-Offset")!
    fileprivate static let uploadLength = Self("Upload-Length")!
    fileprivate static let uploadLimit = Self("Upload-Limit")!
}

@available(anyAppleOS 26.0, *)
extension HTTPFields {
    private struct BoolFieldValue: StructuredFieldValue {
        static var structuredFieldType: StructuredFieldValues.StructuredFieldType { .item }
        var item: Bool
    }

    private struct Int64FieldValue: StructuredFieldValue {
        static var structuredFieldType: StructuredFieldValues.StructuredFieldType { .item }
        var item: Int64
    }

    fileprivate struct UploadLimitFieldValue: StructuredFieldValue {
        static var structuredFieldType: StructuredFieldValues.StructuredFieldType { .dictionary }
        var maxSize: Int64?
        var minSize: Int64?
        var maxAppendSize: Int64?
        var minAppendSize: Int64?
        var expires: Int64?

        enum CodingKeys: String, CodingKey {
            case maxSize = "max-size"
            case minSize = "min-size"
            case maxAppendSize = "max-append-size"
            case minAppendSize = "min-append-size"
            case expires = "expires"
        }
    }

    /// Decodes a structured field, or returns `nil` if the field is absent or its value is invalid.
    private func decode<Value: StructuredFieldValue>(_ type: Value.Type, from name: HTTPField.Name) -> Value? {
        guard let fieldValue = self[name] else {
            return nil
        }
        return try? StructuredFieldValueDecoder().decode(Value.self, from: Array(fieldValue.utf8))
    }

    /// Encodes a structured field, or removes the field if the value is `nil`.
    private mutating func encode<Value: StructuredFieldValue>(_ value: Value?, to name: HTTPField.Name) {
        self[name] = value.map { String(decoding: try! StructuredFieldValueEncoder().encode($0), as: UTF8.self) }
    }

    fileprivate var uploadDraftInteropVersion: Int64? {
        get { self.decode(Int64FieldValue.self, from: .uploadDraftInteropVersion)?.item }
        set { self.encode(newValue.map(Int64FieldValue.init), to: .uploadDraftInteropVersion) }
    }

    fileprivate var uploadComplete: Bool? {
        get { self.decode(BoolFieldValue.self, from: .uploadComplete)?.item }
        set { self.encode(newValue.map(BoolFieldValue.init), to: .uploadComplete) }
    }

    /// Negative values are invalid.
    fileprivate var uploadOffset: Int64? {
        get { self.decode(Int64FieldValue.self, from: .uploadOffset)?.item.nonNegative }
        set { self.encode(newValue.map(Int64FieldValue.init), to: .uploadOffset) }
    }

    /// Negative values are invalid.
    fileprivate var uploadLength: Int64? {
        get { self.decode(Int64FieldValue.self, from: .uploadLength)?.item.nonNegative }
        set { self.encode(newValue.map(Int64FieldValue.init), to: .uploadLength) }
    }

    fileprivate var uploadLimit: UploadLimitFieldValue? {
        get { self.decode(UploadLimitFieldValue.self, from: .uploadLimit) }
        set { self.encode(newValue, to: .uploadLimit) }
    }
}

extension Int64 {
    fileprivate var nonNegative: Int64? {
        self >= 0 ? self : nil
    }
}
