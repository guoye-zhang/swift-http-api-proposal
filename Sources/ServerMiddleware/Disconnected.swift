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

/// Moves a non-Sendable value across isolation regions by erasing its
/// isolation via `nonisolated(unsafe)`.
struct Disconnected<Value: ~Copyable>: ~Copyable, Sendable {
    private nonisolated(unsafe) var value: Value?

    /// Creates a new disconnected container holding the given value.
    ///
    /// - Parameter value: The value to store. Must be passed as `sending`
    ///   to prove the caller has relinquished ownership.
    init(value: consuming sending Value) {
        unsafe self.value = .some(value)
    }

    /// Takes the stored value out of the container, returning it as `sending`.
    ///
    /// - Returns: The stored value, transferred to the caller.
    consuming func take() -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        return unsafe value
    }

    /// Swaps the stored value with a new one, returning the old value as `sending`.
    ///
    /// - Parameter newValue: The replacement value.
    /// - Returns: The previously stored value.
    mutating func swap(newValue: consuming sending Value) -> sending Value {
        nonisolated(unsafe) let value = unsafe self.value.take()!
        unsafe self.value = consume newValue
        return unsafe value
    }
}
