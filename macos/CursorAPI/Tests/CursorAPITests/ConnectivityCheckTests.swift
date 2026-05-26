@testable import CursorAPICore
import XCTest

final class ConnectivityCheckTests: XCTestCase {
    func testConnectivityCheckUsesHarness() async throws {
        let recorder = ConnectivityRecorder()
        let check = CursorSDKConnectivityCheck(harness: ConnectivityHarness(recorder: recorder))
        let settings = CursorAPISettings(
            cursorAPIKey: "crsr_test",
            backendBaseURL: "https://transport.example",
            localAgentEndpoint: "/sdk/run"
        )

        let output = try await check.run(settings: settings, timeoutNanoseconds: 1_000_000_000)

        XCTAssertEqual(output.text, "OK")
        let recorded = await recorder.recordedRequest()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.model, "composer-2.5-fast")
        XCTAssertTrue(request.prompt.contains("Connectivity check"))
        XCTAssertTrue(request.sessionKey?.hasPrefix("diagnostics:") == true)
    }

    func testSDKSessionStoreReusesAndBoundsAgentIDs() async throws {
        let store = CursorSDKSessionStore(maxEntries: 2)

        let first = await store.agentID(for: "project-a")
        let second = await store.agentID(for: "project-b")
        let firstAgain = await store.agentID(for: "project-a")
        let third = await store.agentID(for: "project-c")
        let secondAfterEviction = await store.agentID(for: "project-b")
        let count = await store.count()

        XCTAssertEqual(first, firstAgain)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(secondAfterEviction, second)
        XCTAssertEqual(count, 2)
    }

    func testSDKSessionStoreDoesNotPersistAnonymousSessions() async throws {
        let store = CursorSDKSessionStore(maxEntries: 2)

        let first = await store.agentID(for: nil)
        let second = await store.agentID(for: nil)
        let empty = await store.agentID(for: "")
        let count = await store.count()

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, empty)
        XCTAssertEqual(count, 0)
    }

    func testSDKAccessTokenCacheReusesTokenUntilExpiry() async throws {
        let cache = CursorSDKAccessTokenCache(ttl: 60)
        let counter = ExchangeCounter()
        let firstDate = Date(timeIntervalSince1970: 100)

        let first = try await cache.token(for: "crsr_one", origin: "https://exchange.example", now: firstDate) {
            await counter.next()
        }
        let second = try await cache.token(for: "crsr_one", origin: "https://exchange.example", now: firstDate.addingTimeInterval(30)) {
            await counter.next()
        }
        let third = try await cache.token(for: "crsr_one", origin: "https://exchange.example", now: firstDate.addingTimeInterval(61)) {
            await counter.next()
        }

        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(second, "token-1")
        XCTAssertEqual(third, "token-2")
        let exchangeCount = await counter.value()
        XCTAssertEqual(exchangeCount, 2)
    }

    func testSDKAccessTokenCacheSeparatesOriginsAndInvalidates() async throws {
        let cache = CursorSDKAccessTokenCache(ttl: 60)
        let counter = ExchangeCounter()
        let now = Date(timeIntervalSince1970: 100)

        let first = try await cache.token(for: "crsr_one", origin: "https://one.example", now: now) {
            await counter.next()
        }
        let secondOrigin = try await cache.token(for: "crsr_one", origin: "https://two.example", now: now) {
            await counter.next()
        }
        await cache.invalidate(apiKey: "crsr_one", origin: "https://one.example")
        let refreshed = try await cache.token(for: "crsr_one", origin: "https://one.example", now: now) {
            await counter.next()
        }

        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(secondOrigin, "token-2")
        XCTAssertEqual(refreshed, "token-3")
        let cacheCount = await cache.count()
        XCTAssertEqual(cacheCount, 2)
    }

    func testSDKAccessTokenCacheCoalescesConcurrentExchanges() async throws {
        let cache = CursorSDKAccessTokenCache(ttl: 60)
        let counter = ExchangeCounter()
        let now = Date(timeIntervalSince1970: 100)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await cache.token(for: "crsr_one", origin: "https://exchange.example", now: now) {
                        try await Task.sleep(nanoseconds: 50_000_000)
                        return await counter.next()
                    }
                }
            }

            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        let exchangeCount = await counter.value()

        XCTAssertEqual(Set(tokens), ["token-1"])
        XCTAssertEqual(exchangeCount, 1)
    }

    func testSDKHarnessUsesSavedKeyForLocalPlaceholderTokens() {
        let settings = CursorAPISettings(cursorAPIKey: "crsr_saved")

        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: nil, settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer cursor-local", settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer CURSOR_API_KEY", settings: settings), "crsr_saved")
        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer {env:CURSOR_API_KEY}", settings: settings), "crsr_saved")
    }

    func testSDKHarnessAllowsDirectBearerKeys() {
        let settings = CursorAPISettings(cursorAPIKey: "crsr_saved")

        XCTAssertEqual(LocalCursorSDKHarness.resolvedCursorAPIKey(from: "Bearer crsr_direct", settings: settings), "crsr_direct")
    }
}

private actor ExchangeCounter {
    private var count = 0

    func next() -> String {
        count += 1
        return "token-\(count)"
    }

    func value() -> Int {
        count
    }
}

private actor ConnectivityRecorder {
    private var request: PreparedChatRequest?

    func record(_ request: PreparedChatRequest) {
        self.request = request
    }

    func recordedRequest() -> PreparedChatRequest? {
        request
    }
}

private struct ConnectivityHarness: CursorSDKHarness {
    let recorder: ConnectivityRecorder

    func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await recorder.record(prepared)
                continuation.yield(.text("OK"))
                continuation.yield(.done(CursorSDKOutput(text: "OK", agentID: "agent-diagnostics", runID: "run-diagnostics")))
                continuation.finish()
            }
        }
    }
}
