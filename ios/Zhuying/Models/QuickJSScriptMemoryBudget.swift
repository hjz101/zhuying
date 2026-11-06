import Foundation
import Dispatch
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide reservations of configured QuickJS heap ceilings. These values
/// are upper-bound reservations, not a measurement of process RSS or JS usage.
final class QuickJSScriptMemoryBudget: @unchecked Sendable {
    static let shared = QuickJSScriptMemoryBudget(limitBytes: 96 * 1024 * 1024, observesMemoryPressure: true)

    struct Snapshot: Equatable, Sendable {
        let limitBytes: Int
        let reservedBytes: Int
        let peakReservedBytes: Int
        let reservedSessionCount: Int
        let activeSessionCount: Int
        let waitingCount: Int
        let evictedSessionCount: Int
    }
    enum MemoryPressure: Equatable { case normal, warning, critical }

    final class Reservation: @unchecked Sendable {
        let id: UUID
        weak var session: QuickJSScriptSession?
        let bytes: Int
        var leases = 1
        var lastUse: UInt64
        var retiring = false
        init(session: QuickJSScriptSession, bytes: Int, lastUse: UInt64) {
            id = session.memoryBudgetID; self.session = session; self.bytes = bytes; self.lastUse = lastUse
        }
    }
    private struct Retirement: Sendable {
        let reservation: Reservation
        let session: QuickJSScriptSession
    }

    let limitBytes: Int
    private let condition = NSCondition()
    private let reclamationQueue = DispatchQueue(label: "com.zhuying.quickjs.reclamation", qos: .utility)
    private var records: [UUID: Reservation] = [:]
    private var reservedBytes = 0
    private var peakReservedBytes = 0
    private var waitingCount = 0
    private var clock: UInt64 = 0
    private var evictedSessionCount = 0
    private var pressureIsHigh = false
    private var pressureSource: DispatchSourceMemoryPressure?
    private var warningObserver: NSObjectProtocol?

    init(limitBytes: Int, observesMemoryPressure: Bool = false) {
        precondition(limitBytes >= 256 * 1024)
        self.limitBytes = limitBytes
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: reclamationQueue)
            source.setEventHandler { [weak self] in
                guard let self, let value = pressureSource?.data else { return }
                handleMemoryPressure(value.contains(.critical) ? .critical : value.contains(.warning) ? .warning : .normal)
            }
            pressureSource = source; source.resume()
            #if canImport(UIKit)
            warningObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                                                      object: nil, queue: nil) { [weak self] _ in
                self?.handleMemoryPressure(.warning)
            }
            #endif
        }
    }
    deinit { pressureSource?.cancel(); if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) } }

    var snapshot: Snapshot {
        condition.lock(); defer { condition.unlock() }
        return .init(limitBytes: limitBytes, reservedBytes: reservedBytes, peakReservedBytes: peakReservedBytes,
                     reservedSessionCount: records.count, activeSessionCount: records.values.filter { $0.leases > 0 }.count,
                     waitingCount: waitingCount, evictedSessionCount: evictedSessionCount)
    }

    /// Nonblocking on every caller, including the main thread. Active leases
    /// remain protected; a high-pressure event reclaims them only once idle.
    func handleMemoryPressure(_ pressure: MemoryPressure = .warning) {
        condition.lock(); pressureIsHigh = pressure != .normal
        let victims = pressureIsHigh ? records.values.compactMap(beginRetirement) : []
        condition.unlock()
        victims.forEach(schedule)
    }

    func acquire(session: QuickJSScriptSession, bytes: Int, timeoutSeconds: TimeInterval,
                             cancelled: () -> Bool) throws -> Reservation {
        guard !Thread.isMainThread else { throw QuickJSScriptError.mainThread }
        guard (256 * 1024...128 * 1024 * 1024).contains(bytes), timeoutSeconds.isFinite,
              (0.01...900).contains(timeoutSeconds) else { throw QuickJSScriptError.invalidInput }
        guard bytes <= limitBytes else { throw QuickJSScriptError.memoryLimit }
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while true {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw QuickJSScriptError.memoryBudgetTimedOut }
            condition.lock()
            var victim: Retirement?
            if let current = records[session.memoryBudgetID] {
                if !current.retiring {
                    // A nested rule can use less than its operation reserved,
                    // but cannot expand an active reservation and deadlock on
                    // its own pinned VM.
                    if current.leases > 0 {
                        guard bytes <= current.bytes else { condition.unlock(); throw QuickJSScriptError.memoryLimit }
                        current.leases += 1; condition.unlock(); return current
                    }
                    if current.bytes == bytes {
                        current.leases = 1; condition.unlock(); return current
                    }
                    victim = beginRetirement(current)
                }
            } else if bytes <= limitBytes - reservedBytes {
                clock &+= 1
                let reservation = Reservation(session: session, bytes: bytes, lastUse: clock)
                records[reservation.id] = reservation; reservedBytes += bytes
                peakReservedBytes = max(peakReservedBytes, reservedBytes)
                condition.unlock(); return reservation
            } else {
                let oldest = records.values.filter { !$0.retiring && $0.leases == 0 && $0.session != nil }
                    .min { $0.lastUse < $1.lastUse }
                if let oldest { victim = beginRetirement(oldest) }
            }
            if let victim {
                condition.unlock()
                // This caller is already a background worker. Dispose before
                // returning the reservation, so ceilings never overlap while
                // a large VM is still being freed.
                reclaim(victim)
            } else {
                waitingCount += 1
                _ = condition.wait(until: Date().addingTimeInterval(min(0.025, max(0, deadline - ProcessInfo.processInfo.systemUptime))))
                waitingCount -= 1; condition.unlock()
            }
        }
    }

    func release(_ reservation: Reservation, retainsRuntime: Bool) {
        condition.lock()
        guard records[reservation.id] === reservation else { condition.unlock(); return }
        reservation.leases -= 1
        var victim: Retirement?
        if reservation.leases == 0 {
            clock &+= 1; reservation.lastUse = clock
            if !retainsRuntime { remove(reservation) }
            else if pressureIsHigh || reservation.session?.needsBudgetReclamation() == true { victim = beginRetirement(reservation) }
        }
        condition.broadcast(); condition.unlock()
        if let victim { schedule(victim) }
    }

    func resetIdleSession(_ id: UUID) {
        condition.lock(); let victim = records[id].flatMap(beginRetirement); condition.unlock()
        if let victim { schedule(victim) }
    }

    /// The owner can disappear on the main thread. Moving the C pointer out of
    /// Swift is cheap; destruction and releasing its reservation happen here.
    func ownerDeinitialized(_ id: UUID, dispose: @escaping @Sendable () -> Void) {
        condition.lock(); let reservation = records[id]; reservation?.retiring = true; condition.unlock()
        reclamationQueue.async { [self] in
            dispose()
            if let reservation { finishRetirement(reservation) }
        }
    }

    // These helpers require condition to be locked.
    private func beginRetirement(_ value: Reservation) -> Retirement? {
        guard value.leases == 0, !value.retiring, let session = value.session else { return nil }
        value.retiring = true; evictedSessionCount += 1
        return .init(reservation: value, session: session)
    }
    private func remove(_ value: Reservation) {
        records[value.id] = nil; reservedBytes -= value.bytes
    }
    private func schedule(_ value: Retirement) {
        reclamationQueue.async { [self] in reclaim(value) }
    }
    private func reclaim(_ value: Retirement) {
        value.session.reclaimMemoryForBudget()
        finishRetirement(value.reservation)
    }
    private func finishRetirement(_ value: Reservation) {
        condition.lock()
        if records[value.id] === value {
            precondition(value.leases == 0)
            remove(value)
        }
        condition.broadcast(); condition.unlock()
    }
}
