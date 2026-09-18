import Darwin
import Foundation

private let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

/** Monotonic milliseconds since boot. */
@inline(__always)
func nowMs() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
}

@inline(__always)
private func ticks(nanoseconds: UInt64) -> UInt64 {
    nanoseconds * UInt64(timebase.denom) / UInt64(timebase.numer)
}

/** Absolute-deadline wait: a background process gets its timers coalesced by up to 100 ms, a real-time thread waking on a mach deadline does not. */
func sleepMs(_ ms: Int) {
    guard ms > 0 else { return }
    mach_wait_until(mach_absolute_time() + ticks(nanoseconds: UInt64(ms) * 1_000_000))
}

/** Busy-waits until the deadline: no timer is involved, so the background timer coalescing (up to 100 ms) cannot stretch it; only for waits of a few ms. */
func spinUntil(_ deadlineMs: Double) {
    while nowMs() < deadlineMs {}
}

func spinMs(_ ms: Int) {
    guard ms > 0 else { return }
    spinUntil(nowMs() + Double(ms))
}

/** Gives the calling thread the time-constraint (real-time) scheduling policy so its waits are not coalesced with the background timer budget. */
@discardableResult
func makeCurrentThreadRealtime(periodMs: Int, computationMs: Int) -> Bool {
    var policy = thread_time_constraint_policy(period: UInt32(ticks(nanoseconds: UInt64(periodMs) * 1_000_000)),
                                               computation: UInt32(ticks(nanoseconds: UInt64(computationMs) * 1_000_000)),
                                               constraint: UInt32(ticks(nanoseconds: UInt64(periodMs) * 1_000_000)), preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &policy) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    if result != KERN_SUCCESS { Log.warn("realtime thread policy failed (\(result)), timing may be coalesced") }
    return result == KERN_SUCCESS
}
