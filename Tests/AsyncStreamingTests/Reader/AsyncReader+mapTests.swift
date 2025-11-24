//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP API Proposal open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP API Proposal project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP API Proposal project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import AsyncStreaming
import Testing

@Suite
struct AsyncReaderMapTests {
    @Test
    func mapTransformsElements() async throws {
        let reader = [1, 2, 3, 4, 5].asyncReader()
        let mappedReader = reader.map { $0 * 2 }

        var results: [Int] = []
        try await mappedReader.forEach { span in
            for i in span.indices {
                results.append(span[i])
            }
        }

        #expect(results == [2, 4, 6, 8, 10])
    }

    @Test
    func mapWithTypeConversion() async throws {
        let reader = [1, 2, 3].asyncReader()
        let mappedReader = reader.map { String($0) }

        var results: [String] = []
        try await mappedReader.forEach { span in
            for i in span.indices {
                results.append(span[i])
            }
        }

        #expect(results == ["1", "2", "3"])
    }

    @Test
    func mapEmptyReader() async throws {
        let reader = [Int]().asyncReader()
        let mappedReader = reader.map { $0 * 2 }

        var count = 0
        try await mappedReader.forEach { span in
            count += span.count
        }

        #expect(count == 0)
    }

    @Test
    func mapWithAsyncTransformation() async throws {
        let reader = [1, 2, 3].asyncReader()
        let mappedReader = reader.map { value in
            // Simulate async work
            await Task.yield()
            return value * 10
        }

        var results: [Int] = []
        try await mappedReader.forEach { span in
            for i in span.indices {
                results.append(span[i])
            }
        }

        #expect(results == [10, 20, 30])
    }

    @Test
    func mapPreservesChunking() async {
        let reader = [1, 2, 3, 4, 5, 6].asyncReader()
        var mappedReader = reader.map { $0 + 100 }

        // Read in chunks
        var chunks: [[Int]] = []
        while true {
            let chunk = try! await mappedReader.read(maximumCount: 2) { span in
                return Array(span)
            }
            if chunk.isEmpty {
                break
            }
            chunks.append(chunk)
        }

        #expect(chunks == [[101, 102], [103, 104], [105, 106]])
    }

    @Test
    func mapChaining() async throws {
        let reader = [1, 2, 3].asyncReader()
        let mappedReader =
            reader
            .map { $0 * 2 }
            .map { $0 + 10 }

        var results: [Int] = []
        try await mappedReader.forEach { span in
            for i in span.indices {
                results.append(span[i])
            }
        }

        #expect(results == [12, 14, 16])
    }
}
