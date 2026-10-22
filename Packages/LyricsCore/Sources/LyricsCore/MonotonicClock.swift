import Foundation

/// Seconds on a clock that only moves forward and keeps counting while the
/// phone sleeps. (`ProcessInfo.systemUptime` stops during sleep, which would
/// leave the lyrics behind by the sleep time after the phone wakes up.)
public enum MonotonicClock {
    public static func now() -> TimeInterval {
        #if canImport(Darwin)
        return TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #else
        var time = timespec()
        clock_gettime(CLOCK_BOOTTIME, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
        #endif
    }
}
