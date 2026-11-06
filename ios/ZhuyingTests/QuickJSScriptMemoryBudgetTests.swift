import XCTest
@testable import Zhuying

final class QuickJSScriptMemoryBudgetTests: XCTestCase {
    private let heap = 2 * 1024 * 1024
    private let library = "var count=0;var retained=new ArrayBuffer(128*1024);function next(){return ++count;}"
    private func policy() -> LegadoScriptPolicy { var value = LegadoScriptPolicy(); value.memoryLimitBytes = heap; return value }
    private func evaluate(_ session: QuickJSScriptSession, script: String = "next()", library: String? = nil,
                          policy: LegadoScriptPolicy? = nil) async throws -> Int {
        let library = library ?? self.library, policy = policy ?? self.policy()
        let result = try await Task.detached { try session.evaluate(script, bindings: [:], library: library, policy: policy) { _, _ in NSNull() } }.value
        return try XCTUnwrap(result as? Int)
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw QuickJSScriptError.timedOut
    }

    func testDefaultBudgetCountsConfiguredHeapReservationsRatherThanProcessMemory() {
        XCTAssertEqual(QuickJSScriptMemoryBudget.shared.limitBytes, 96 * 1024 * 1024)
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap)
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, 0)
    }

    func testLeastRecentlyUsedIdleVMIsRebuiltAndRecentlyUsedGlobalsSurvive() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: 2 * heap)
        let a = QuickJSScriptSession(budget: budget), b = QuickJSScriptSession(budget: budget), c = QuickJSScriptSession(budget: budget)
        let a1 = try await evaluate(a), b1 = try await evaluate(b), a2 = try await evaluate(a), c1 = try await evaluate(c)
        XCTAssertEqual([a1,b1,a2,c1], [1,1,2,1])
        let a3 = try await evaluate(a), bRebuilt = try await evaluate(b)
        XCTAssertEqual(a3, 3); XCTAssertEqual(bRebuilt, 1)
        XCTAssertEqual(budget.snapshot.reservedSessionCount, 2)
        XCTAssertEqual(budget.snapshot.reservedBytes, 2 * heap)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, 2 * heap)
        XCTAssertGreaterThanOrEqual(budget.snapshot.evictedSessionCount, 2)
    }

    func testOperationLeaseProtectsTheLibraryBetweenRulesWhileOtherSourceWaits() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap)
        let active = QuickJSScriptSession(budget: budget), waiting = QuickJSScriptSession(budget: budget)
        let entered = expectation(description: "between source rules"), gate = DispatchSemaphore(value: 0)
        let library = library, policy = policy(), heap = heap
        defer { gate.signal() }
        let operation = Task.detached {
            try active.withLease(memoryLimitBytes: heap) {
                let first = try active.evaluate("next()", bindings: [:], library: library, policy: policy) { _, _ in NSNull() } as? Int
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw QuickJSScriptError.timedOut }
                let second = try active.evaluate("next()", bindings: [:], library: library, policy: policy) { _, _ in NSNull() } as? Int
                return [first,second]
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let waiter = Task { try await evaluate(waiting) }
        defer { operation.cancel(); waiter.cancel() }
        try await waitFor { budget.snapshot.waitingCount == 1 }
        XCTAssertEqual(budget.snapshot.activeSessionCount, 1)
        XCTAssertEqual(budget.snapshot.evictedSessionCount, 0)
        gate.signal()
        let original = try await operation.value, following = try await waiter.value
        XCTAssertEqual(original, [1,2]); XCTAssertEqual(following, 1)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, heap)
    }

    func testBrowserLikeHostWaitStaysPinnedDuringMemoryPressure() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: 2 * heap)
        let active = QuickJSScriptSession(budget: budget), idle = QuickJSScriptSession(budget: budget)
        _ = try await evaluate(idle)
        let entered = expectation(description: "host is waiting"), gate = DispatchSemaphore(value: 0)
        let library = library, policy = policy()
        defer { gate.signal() }
        let operation = Task.detached {
            try active.evaluate("next();java.startBrowserAwait('https://fixture.test');next()", bindings: [:], library: library, policy: policy) { _, _ in
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw QuickJSScriptError.timedOut }
                return NSNull()
            }
        }
        defer { operation.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        await MainActor.run { budget.handleMemoryPressure(.critical) }
        try await waitFor { budget.snapshot.reservedSessionCount == 1 }
        XCTAssertEqual(budget.snapshot.activeSessionCount, 1)
        XCTAssertEqual(budget.snapshot.reservedBytes, heap)
        gate.signal()
        let value = try await operation.value
        XCTAssertEqual(value as? Int, 2)
        try await waitFor { budget.snapshot.reservedBytes == 0 }
        budget.handleMemoryPressure(.normal)
        let rebuilt = try await evaluate(active)
        XCTAssertEqual(rebuilt, 1)
    }

    func testWaitingBudgetObservesExternalCancellationSwiftCancellationAndSessionReset() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap)
        let active = QuickJSScriptSession(budget: budget), waiting = QuickJSScriptSession(budget: budget)
        let entered = expectation(description: "lease occupied"), gate = DispatchSemaphore(value: 0), heap = heap
        defer { gate.signal() }
        let holder = Task.detached {
            try active.withLease(memoryLimitBytes: heap) {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw QuickJSScriptError.timedOut }
            }
        }
        defer { holder.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        for mode in 0..<3 {
            let cancellation = LegadoScriptCancellation()
            var policy = policy(); policy.cancelled = { cancellation.isCancelled }
            let worker = Task.detached { try waiting.evaluate("42", bindings: [:], policy: policy) { _, _ in NSNull() } }
            defer { worker.cancel() }
            try await waitFor { budget.snapshot.waitingCount == 1 }
            switch mode { case 0: cancellation.cancel(); case 1: worker.cancel(); default: waiting.reset() }
            do { _ = try await worker.value; XCTFail("A cancelled reservation must not create a VM") } catch is CancellationError {}
            XCTAssertEqual(budget.snapshot.waitingCount, 0)
            XCTAssertEqual(budget.snapshot.reservedBytes, heap)
            XCTAssertEqual(budget.snapshot.activeSessionCount, 1)
        }
        gate.signal(); try await holder.value
        try await waitFor { budget.snapshot.reservedBytes == 0 }
    }

    func testBudgetWaitHasItsOwnBoundedTimeoutAndCannotExceedTheConfiguredPeak() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap)
        let active = QuickJSScriptSession(budget: budget), waiting = QuickJSScriptSession(budget: budget)
        let entered = expectation(description: "lease occupied"), gate = DispatchSemaphore(value: 0), heap = heap
        defer { gate.signal() }
        let holder = Task.detached {
            try active.withLease(memoryLimitBytes: heap) {
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw QuickJSScriptError.timedOut }
            }
        }
        defer { holder.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        var limited = policy(); limited.timeoutSeconds = 0.03
        do { _ = try await evaluate(waiting, policy: limited); XCTFail("Expected a bounded reservation wait") }
        catch { XCTAssertEqual(error as? QuickJSScriptError, .memoryBudgetTimedOut) }
        XCTAssertEqual(budget.snapshot.peakReservedBytes, heap)
        XCTAssertEqual(budget.snapshot.waitingCount, 0)
        gate.signal(); try await holder.value
    }

    func testManySourcesRetainOnlyTheConfiguredNumberOfRealVMs() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: 3 * heap)
        let sources = (0..<24).map { _ in QuickJSScriptSession(budget: budget) }
        let library = library, policy = policy()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for session in sources {
                group.addTask {
                    let result = try session.evaluate("next()", bindings: [:], library: library, policy: policy) { _, _ in NSNull() }
                    return result as? Int ?? -1
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(values, [Int](repeating: 1, count: 24))
        XCTAssertEqual(budget.snapshot.reservedSessionCount, 3)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, 3 * heap)
        XCTAssertGreaterThanOrEqual(budget.snapshot.evictedSessionCount, 21)
    }

    func testFailedOuterOperationDropsPartialGlobalsAndReleasesItsReservation() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap), session = QuickJSScriptSession(budget: budget)
        let library = library, policy = policy(), heap = heap
        do {
            try await Task.detached {
                try session.withLease(memoryLimitBytes: heap) {
                    _ = try session.evaluate("next()", bindings: [:], library: library, policy: policy) { _, _ in NSNull() }
                    throw NSError(domain: "Zhuying.Budget.Test", code: 1)
                }
            }.value
            XCTFail("Expected the original operation failure")
        } catch { XCTAssertEqual((error as NSError).domain, "Zhuying.Budget.Test") }
        XCTAssertEqual(budget.snapshot.reservedBytes, 0)
        let rebuilt = try await evaluate(session)
        XCTAssertEqual(rebuilt, 1)
    }

    func testResetFromMainThreadReclaimsIdleVMInTheBackgroundAndAllowsRecreation() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap), session = QuickJSScriptSession(budget: budget)
        _ = try await evaluate(session)
        await MainActor.run { session.reset() }
        try await waitFor { budget.snapshot.reservedBytes == 0 }
        let rebuilt = try await evaluate(session)
        XCTAssertEqual(rebuilt, 1)
    }

    func testResetBetweenRulesCancelsTheOperationLeaseAndReclaimsItsReservation() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap), session = QuickJSScriptSession(budget: budget)
        let entered = expectation(description: "rule completed"), gate = DispatchSemaphore(value: 0)
        let library = library, policy = policy(), heap = heap
        defer { gate.signal() }
        let operation = Task.detached {
            try session.withLease(memoryLimitBytes: heap) {
                _ = try session.evaluate("next()", bindings: [:], library: library, policy: policy) { _,_ in NSNull() }
                entered.fulfill()
                guard gate.wait(timeout: .now() + 3) == .success else { throw QuickJSScriptError.timedOut }
                return 42
            }
        }
        defer { operation.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        session.reset(); gate.signal()
        do { _ = try await operation.value; XCTFail("Reset must also invalidate the gap between JS rules") } catch is CancellationError {}
        try await waitFor { budget.snapshot.reservedBytes == 0 }
        let rebuilt = try await evaluate(session)
        XCTAssertEqual(rebuilt, 1)
    }

    @MainActor func testReleasingTheLastOwnerOnMainThreadDefersCDestructionAndReleasesReservation() async throws {
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap)
        var session: QuickJSScriptSession? = QuickJSScriptSession(budget: budget)
        _ = try await evaluate(try XCTUnwrap(session))
        XCTAssertEqual(budget.snapshot.reservedBytes, heap)
        session = nil
        try await waitFor { budget.snapshot.reservedBytes == 0 }
        XCTAssertEqual(budget.snapshot.reservedSessionCount, 0)
    }

    func testHostStateSurvivesEvictionWhileJavaScriptGlobalsReinitialize() async throws {
        let suite = "Zhuying.Budget.Persistence." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let budget = QuickJSScriptMemoryBudget(limitBytes: heap), session = QuickJSScriptSession(budget: budget), other = QuickJSScriptSession(budget: budget)
        let library = "var count=0;var durable=Number(java.get('saved')||0);function next(){java.put('saved',String(++durable));return [++count,durable]}"
        let policy = policy()
        func next() async throws -> [Int] {
            let value = try await Task.detached {
                try session.evaluate("next()", bindings: [:], library: library, policy: policy) { method,args in
                    if method == "java.get" { return defaults.string(forKey: args[0] as! String) ?? "" }
                    defaults.set(args[1] as? String, forKey: args[0] as! String); return NSNull()
                }
            }.value
            return try XCTUnwrap(value as? [Int])
        }
        let first = try await next()
        _ = try await evaluate(other)
        let rebuilt = try await next()
        XCTAssertEqual(first, [1,1]); XCTAssertEqual(rebuilt, [1,2])
        XCTAssertEqual(defaults.string(forKey: "saved"), "2")
    }
}
