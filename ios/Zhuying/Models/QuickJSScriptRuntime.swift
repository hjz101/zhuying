import Foundation
import Darwin
import ZhuyingScriptCore

struct LegadoScriptPolicy {
    var timeoutSeconds: TimeInterval = 5
    var memoryLimitBytes = 16 * 1024 * 1024
    var stackLimitBytes = 512 * 1024
    var maximumHostCalls = 128
    var maximumBridgeBytes = 4 * 1024 * 1024
    var maximumOutputBytes = 2 * 1024 * 1024
    var cancelled: () -> Bool = { false }
}

/// A cancellation handle can be shared with a synchronous host's network wait.
/// Cancelling a Swift task is also observed by the runtime interrupt callback.
final class LegadoScriptCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum QuickJSScriptError: LocalizedError, Equatable {
    case invalidInput
    case mainThread
    case javascript(String)
    case memoryLimit
    case timedOut
    case bridgeLimit

    var errorDescription: String? {
        switch self {
        case .invalidInput: "Legado 脚本、变量或执行额度无效。"
        case .mainThread: "Legado 同步脚本必须在独立后台线程执行。"
        case .javascript(let message): "Legado 脚本执行失败：\(message)"
        case .memoryLimit: "Legado 脚本超过内存额度，已停止执行。"
        case .timedOut: "Legado 脚本执行超时，已停止执行。"
        case .bridgeLimit: "Legado 脚本的宿主调用次数或数据量超过额度。"
        }
    }
}

/// A synchronous, isolated execution scope for Legado rule completion values.
/// Pure JavaScript libraries share this call's bindings. Host I/O must enforce
/// its own timeout and wake on cancellation; an interpreter interrupt cannot
/// interrupt a blocked native callback. No OS/libc/module loader is installed.
enum QuickJSScriptRuntime {
    static var version: String { String(cString: ZYQuickJSVersion()) }

    static func evaluate(_ script: String, bindings: [String: Any], library: String = "",
                         policy: LegadoScriptPolicy = .init(),
                         host: (String, [Any]) throws -> Any) throws -> Any {
        guard !Thread.isMainThread else { throw QuickJSScriptError.mainThread }
        guard policy.timeoutSeconds.isFinite, (0.01...30).contains(policy.timeoutSeconds),
              (256 * 1024...128 * 1024 * 1024).contains(policy.memoryLimitBytes),
              (64 * 1024...2 * 1024 * 1024).contains(policy.stackLimitBytes),
              (0...4096).contains(policy.maximumHostCalls),
              (1...16 * 1024 * 1024).contains(policy.maximumBridgeBytes),
              (1...8 * 1024 * 1024).contains(policy.maximumOutputBytes),
              script.utf8.count <= 256 * 1024, library.utf8.count <= 2 * 1024 * 1024 else { throw QuickJSScriptError.invalidInput }
        try Task.checkCancellation()
        if policy.cancelled() { throw CancellationError() }
        // Values are data, never interpolated into JavaScript source. Protect
        // the intrinsic names used by the fixed host shim from input collisions.
        let reserved: Set<String> = ["__zhuyingHost", "globalThis", "Object", "Array", "JSON", "Proxy", "Reflect"]
        guard Set(bindings.keys).isDisjoint(with: reserved),
              let bytes = try? JSONSerialization.data(withJSONObject: bindings, options: [.sortedKeys]),
              bytes.count <= policy.maximumBridgeBytes,
              let json = String(data: bytes, encoding: .utf8) else { throw QuickJSScriptError.invalidInput }
        let limits = ZYQJSLimits(memory_limit_bytes: policy.memoryLimitBytes, stack_limit_bytes: policy.stackLimitBytes,
                                timeout_milliseconds: UInt64(ceil(policy.timeoutSeconds * 1000)),
                                maximum_output_bytes: policy.maximumOutputBytes, maximum_host_calls: policy.maximumHostCalls,
                                maximum_bridge_bytes: policy.maximumBridgeBytes)
        return try withoutActuallyEscaping(host) { callback in
            let callbacks = Callbacks(policy: policy, host: callback)
            let opaque = Unmanaged.passUnretained(callbacks).toOpaque()
            var result = script.withCString { scriptBytes in
                library.withCString { libraryBytes in
                    json.withCString { bindingBytes in
                        ZYQuickJSEvaluate(scriptBytes, script.utf8.count, libraryBytes, library.utf8.count,
                                          bindingBytes, bytes.count, limits, invokeHost, isCancelled, opaque)
                    }
                }
            }
            defer { ZYQuickJSFreeResult(&result) }
            try Task.checkCancellation()
            if policy.cancelled() || result.status == ZYQJS_CANCELLED { throw CancellationError() }
            if callbacks.bridgeOverflow { throw QuickJSScriptError.bridgeLimit }
            switch result.status {
            case ZYQJS_OK:
                guard let output = result.json else { throw QuickJSScriptError.memoryLimit }
                let data = Data(bytes: output, count: strlen(output))
                guard data.count <= policy.maximumOutputBytes,
                      let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw QuickJSScriptError.invalidInput }
                return value
            case ZYQJS_TIMED_OUT: throw QuickJSScriptError.timedOut
            case ZYQJS_MEMORY_LIMIT: throw QuickJSScriptError.memoryLimit
            case ZYQJS_BRIDGE_LIMIT: throw QuickJSScriptError.bridgeLimit
            case ZYQJS_SCRIPT_EXCEPTION:
                throw QuickJSScriptError.javascript(result.message.map { String(cString: $0) } ?? "未知异常")
            default: throw QuickJSScriptError.invalidInput
            }
        }
    }

    private final class Callbacks {
        let policy: LegadoScriptPolicy
        let host: (String, [Any]) throws -> Any
        var bridgeOverflow = false
        init(policy: LegadoScriptPolicy, host: @escaping (String, [Any]) throws -> Any) { self.policy = policy; self.host = host }
    }

    private static let invokeHost: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>? = { opaque, method, input, isError in
        guard let opaque, let method, let input, let isError else { return nil }
        let callbacks = Unmanaged<Callbacks>.fromOpaque(opaque).takeUnretainedValue()
        do {
            try Task.checkCancellation()
            if callbacks.policy.cancelled() { throw CancellationError() }
            let bytes = Data(bytes: input, count: strlen(input))
            guard let arguments = try JSONSerialization.jsonObject(with: bytes) as? [Any] else { throw QuickJSScriptError.invalidInput }
            let value = try callbacks.host(String(cString: method), arguments)
            let output = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            guard output.count <= callbacks.policy.maximumBridgeBytes else {
                callbacks.bridgeOverflow = true
                throw QuickJSScriptError.bridgeLimit
            }
            return output.withUnsafeBytes { buffer in
                guard let allocation = malloc(buffer.count + 1)?.assumingMemoryBound(to: CChar.self) else { return nil }
                if let base = buffer.baseAddress { memcpy(allocation, base, buffer.count) }
                allocation[buffer.count] = 0
                return allocation
            }
        } catch {
            isError.pointee = 1
            return strdup(error.localizedDescription)
        }
    }

    private static let isCancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
        guard let opaque else { return 1 }
        let callbacks = Unmanaged<Callbacks>.fromOpaque(opaque).takeUnretainedValue()
        return Task.isCancelled || callbacks.policy.cancelled() ? 1 : 0
    }
}
