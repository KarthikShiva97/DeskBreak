import Foundation
import IOKit

/// Monitors user activity by reading the system's HID idle time.
/// When idle time exceeds a threshold, the user is considered "away."
final class ActivityMonitor {
    /// Idle duration (seconds) before we consider the user away from the computer.
    var idleThresholdSeconds: TimeInterval = 120 // 2 minutes default

    /// Returns the number of seconds the user has been idle (no mouse/keyboard input).
    func systemIdleTime() -> TimeInterval {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem"),
            &iterator
        )
        guard result == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return 0 }
        defer { IOObjectRelease(entry) }

        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry,
            &unmanagedDict,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS else { return 0 }

        guard let dict = unmanagedDict?.takeRetainedValue() as? [String: Any],
              let idleValue = dict["HIDIdleTime"]
        else { return 0 }

        // IOKit may bridge HIDIdleTime as Int64, UInt64, or NSNumber depending
        // on macOS version. Handle all cases to avoid silent idle detection failure.
        let nanoseconds: Int64
        if let val = idleValue as? Int64 {
            nanoseconds = val
        } else if let val = idleValue as? UInt64 {
            nanoseconds = Int64(clamping: val)
        } else if let num = idleValue as? NSNumber {
            nanoseconds = num.int64Value
        } else {
            return 0
        }

        return TimeInterval(nanoseconds) / 1_000_000_000
    }

    /// Returns `true` if the user is currently active (idle time below threshold).
    func isUserActive() -> Bool {
        return systemIdleTime() < idleThresholdSeconds
    }
}
