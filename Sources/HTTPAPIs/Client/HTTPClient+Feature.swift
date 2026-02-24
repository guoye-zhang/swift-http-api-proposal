//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP API Proposal open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP API Proposal project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP API Proposal project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension HTTPClient where Self: ~Copyable {
    public func validateConformance(
        request: HTTPRequest,
        body: borrowing HTTPClientRequestBody<RequestWriter>?,
        options: RequestOptions
    ) {
        switch body {
        case .some(let body) where body.requiresStreaming == .required:
            if !self.supportedFeatures.contains(.requestBodyStreaming) {
                fatalError("Request body streaming not supported")
            }
        default:
            break
        }
        switch body {
        case .some(let body) where body.requiresBidirectionalStreaming == .required:
            if !self.supportedFeatures.contains(.bidirectionalStreaming) {
                fatalError("Bidirectional streaming not supported")
            }
        default:
            break
        }
        let unsupportedFeatures = options.requiredFeatures.subtracting(self.supportedFeatures)
        if !unsupportedFeatures.isEmpty {
            fatalError("Unsupported features required: \(unsupportedFeatures)")
        }
    }

    public static func reportUndeclaredFeatureUsage(feature: HTTPClientCapability.Feature) {
        fatalError("Undeclared feature used: \(feature.name)")
    }
}
