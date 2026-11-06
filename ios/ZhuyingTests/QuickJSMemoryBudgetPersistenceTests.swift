import XCTest
@testable import Zhuying

private final class BudgetPersistenceVault: LegadoSecretVault {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ data: Data, id: String) throws { lock.lock(); values[id] = data; lock.unlock() }
    func remove(id: String) throws { lock.lock(); values[id] = nil; lock.unlock() }
}

final class QuickJSMemoryBudgetPersistenceTests: XCTestCase {
    func testEvictingAndRebuildingARealVMPreservesEncryptedSourceStateAcrossStorageReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZhuyingBudgetState-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = BudgetPersistenceVault()
        let original = try LegadoPersistentState(sourceID: "budget-original", directory: directory, vault: vault)
        try original.setVariable("7", key: "saved-counter")
        let heap = 2 * 1024 * 1024, budget = QuickJSScriptMemoryBudget(limitBytes: 2 * 1024 * 1024)
        let source = QuickJSScriptSession(budget: budget), other = QuickJSScriptSession(budget: budget)
        var policy = LegadoScriptPolicy(); policy.memoryLimitBytes = heap
        let library = "var local=0;var saved=Number(java.get('saved-counter'));function next(){java.put('saved-counter',String(++saved));return [++local,saved]}"
        func next(_ state: LegadoPersistentState) async throws -> [Int] {
            let result = try await Task.detached {
                try source.evaluate("next()", bindings: [:], library: library, policy: policy) { method,args in
                    let key = args[0] as! String
                    if method == "java.get" { return try state.getVariable(key) }
                    try state.setVariable(args[1] as! String, key: key); return NSNull()
                }
            }.value
            return try XCTUnwrap(result as? [Int])
        }
        let first = try await next(original)
        _ = try await Task.detached { try other.evaluate("42", bindings: [:], policy: policy) { _,_ in NSNull() } }.value
        let reopened = try LegadoPersistentState(sourceID: "budget-original", directory: directory, vault: vault)
        let rebuilt = try await next(reopened)
        XCTAssertEqual(first, [1,8]); XCTAssertEqual(rebuilt, [1,9])
        XCTAssertEqual(try original.getVariable("saved-counter"), "9")
        XCTAssertEqual(try reopened.getVariable("saved-counter"), "9")
        XCTAssertEqual(budget.snapshot.reservedSessionCount, 1)
        XCTAssertEqual(budget.snapshot.peakReservedBytes, heap)
    }
}
