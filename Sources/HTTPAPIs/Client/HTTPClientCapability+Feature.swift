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
extension HTTPClientCapability {
    public struct Feature: Sendable, Hashable {
        var name: String
        public init(name: String) {
            self.name = name
        }

        public static var trailers: Self { .init(name: "builtin.trailers") }
        public static var requestBodyStreaming: Self { .init(name: "builtin.requestBodyStreaming") }
        public static var bidirectionalStreaming: Self { .init(name: "builtin.bidirectionalStreaming") }
        public static var automaticCookieHandling: Self { .init(name: "builtin.automaticCookieHandling") }
    }

    public enum FeatureRequirement: Sendable, Hashable {
        case required
        case agnostic
        case undeclared
    }
}
