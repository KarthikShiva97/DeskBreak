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
              let idleNanoseconds = dict["HIDIdleTime"] as? Int64
        else { return 0 }

        return TimeInterval(idleNanoseconds) / 1_000_000_000
    }

    /// Returns `true` if the user is currently active (idle time below threshold).
    func isUserActive() -> Bool {
        return systemIdleTime() < idleThresholdSeconds
    }
}
