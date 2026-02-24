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

/// The namespace for all protocols defining HTTP client capabilities.
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
public enum HTTPClientCapability {
    /// The request options protocol.
    ///
    /// Additional options supported by a subset of clients are defined in child
    /// protocols to allow libraries to depend on a specific capabilities.
    public protocol RequestOptions {
        var requiredFeatures: Set<HTTPClientCapability.Feature> { get set }
        var agnosticFeatures: Set<HTTPClientCapability.Feature> { get set }
        var evaluationMode: Bool { get set }

        init()
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension HTTPClientCapability.RequestOptions {
    public var requiresAutomaticCookieHandling: HTTPClientCapability.FeatureRequirement {
        get {
            if self.requiredFeatures.contains(.automaticCookieHandling) {
                return .required
            }
            if self.agnosticFeatures.contains(.automaticCookieHandling) {
                return .agnostic
            }
            return .undeclared
        }
        set {
            switch newValue {
            case .required:
                self.requiredFeatures.insert(.automaticCookieHandling)
                self.agnosticFeatures.remove(.automaticCookieHandling)
            case .agnostic:
                self.requiredFeatures.remove(.automaticCookieHandling)
                self.agnosticFeatures.insert(.automaticCookieHandling)
            case .undeclared:
                self.requiredFeatures.remove(.automaticCookieHandling)
                self.agnosticFeatures.remove(.automaticCookieHandling)
            }
        }
    }
}
