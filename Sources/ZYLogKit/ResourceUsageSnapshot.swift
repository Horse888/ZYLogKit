import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ResourceUsageSnapshot {
    let cpuUsageRatio: Double
    let residentMemoryBytes: UInt64
    let physicalFootprintBytes: UInt64?

    var metadata: [String: String] {
        var metadata = [
            "resource.cpu.percent": Self.format(cpuUsageRatio * 100, fractionDigits: 1),
            "resource.memory.resident.mb": Self.format(Self.megabytes(from: residentMemoryBytes), fractionDigits: 1),
            "resource.memory.resident.bytes": "\(residentMemoryBytes)"
        ]

        if let physicalFootprintBytes {
            metadata["resource.memory.physical_footprint.mb"] = Self.format(
                Self.megabytes(from: physicalFootprintBytes),
                fractionDigits: 1
            )
            metadata["resource.memory.physical_footprint.bytes"] = "\(physicalFootprintBytes)"
        }

        return metadata
    }

    static func current() -> ResourceUsageSnapshot? {
#if canImport(Darwin)
        guard let memory = currentMemoryUsage() else {
            return nil
        }

        return ResourceUsageSnapshot(
            cpuUsageRatio: currentCPUUsageRatio(),
            residentMemoryBytes: memory.resident,
            physicalFootprintBytes: memory.physicalFootprint
        )
#else
        return nil
#endif
    }

    private static func megabytes(from bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    private static func format(_ value: Double, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

#if canImport(Darwin)
private extension ResourceUsageSnapshot {
    static func currentCPUUsageRatio() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)

        let result = task_threads(mach_task_self_, &threadList, &threadCount)
        guard result == KERN_SUCCESS, let threadList else {
            return 0
        }

        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var totalUsage: Double = 0

        for index in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)

            let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(
                        threadList[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        $0,
                        &threadInfoCount
                    )
                }
            }

            if infoResult == KERN_SUCCESS, threadInfo.flags & TH_FLAGS_IDLE == 0 {
                totalUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE)
            }
        }

        return totalUsage
    }

    static func currentMemoryUsage() -> (resident: UInt64, physicalFootprint: UInt64?)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return (
            resident: UInt64(info.resident_size),
            physicalFootprint: UInt64(info.phys_footprint)
        )
    }
}
#endif
