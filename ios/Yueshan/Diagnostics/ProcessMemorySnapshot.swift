import Darwin
import Foundation

/// RSS includes resident file-backed/shared pages. Physical footprint is an
/// additional process allocation measure, never a replacement for an RSS gate.
struct ProcessMemorySnapshot: Codable, Sendable {
    let residentMiB: Double
    let peakResidentMiB: Double
    let physicalFootprintMiB: Double

    static func capture() throws -> Self {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        guard result == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0 else { throw CaptureFailure.unavailable }
        let mib = 1_048_576.0
        return .init(residentMiB: Double(info.resident_size) / mib,
                     peakResidentMiB: Double(usage.ru_maxrss) / mib,
                     physicalFootprintMiB: Double(info.phys_footprint) / mib)
    }
    private enum CaptureFailure: Error { case unavailable }
}
