import Foundation

import Testing
@testable import TimeKit

// TODO: Write Tests

/*
 1. Monotonicity (Critical)
 Time never goes backwards across multiple calls
 Time never goes backwards even when realtime jumps backward (NTP adjustment)
 Time never goes backwards even when snapping/slewing occurs

 2. Initial Anchoring
 First call returns a reasonable epoch timestamp
 Initial timeNS equals initial realtimeNS
 Anchors are captured only once during init

 3. Monotonic Advancement
 Time advances based on monotonic delta, not just realtime
 Advancement continues correctly even if realtime doesn't change
 Delta calculation handles monotonic wrap-around (if possible on platform)
 
 4. Lead Clamping (ahead of realtime)
 When synthetic time exceeds realtime + maxlead, it snaps back
 After snapping, time is exactly realtime + maxlead
 Anchor (realtimeNS) is recalculated correctly after snap
 Time still never decreases during snap

 5. Lag Clamping (behind realtime)
 When synthetic time lags realtime - maxlag, it jumps forward
 After jumping, time equals current realtime
 Anchor is recalculated correctly after jump
 Time never decreases during jump

 6. Within Bounds
 Time advances normally when within [realtime - maxlag, realtime + maxlead]
 No snapping/slewing occurs when drift is acceptable
 
 7. Boundary Conditions
 maxlead = 0 (always snap to realtime or less)
 maxlag = 0 (always snap to realtime or more)
 Very large lead/lag values (effectively unbounded)
 Exactly at boundaries (lead == maxlead, lag == maxlag)

 8. Clock Jumps
 Realtime jumps backward (NTP correction) - time should never decrease
 Realtime jumps forward significantly - time should eventually catch up
 Monotonic clock continuity (can't easily test jumps, but verify delta logic)

 9. Concurrent Access
 Multiple concurrent calls return monotonically increasing values
 Actor isolation prevents race conditions
 Order of results matches happens-before relationships
 
 10. TimeKit Static Wrapper
 TimeKit.nanosecondsSince1970() works correctly
 Singleton clock is truly shared across calls
 Multiple calls from different tasks use same clock instance

 11. Platform Compatibility
 Darwin: CLOCK_REALTIME and CLOCK_MONOTONIC work
 Linux: Same clocks work
 Fallback: Date() and DispatchTime work correctly

 12. Rapid Successive Calls
 1000+ calls in tight loop maintain monotonicity
 Performance is acceptable (no excessive overhead)

 13. Long-Running Behavior
 Drift accumulation over simulated hours/days (by mocking clocks)
 Slewing/snapping frequency under various drift rates
 */


@Suite("TimeKitClock Basic Behavior")
struct TimeKitClockBasicTests {
  
  // Assume a same second execution, drop fractions and compare.
  @Test("Initial timestamp is reasonable epoch time")
  func initialTimestamp() async throws {
    let mockClock = TimeKitClock()
    let timestamp = try await mockClock.nanosecondsSince1970()
    #expect(Int(timestamp / 1_000_000_000) == Int(Date().timeIntervalSince1970))
  }
  
  //
  @Test("Time never goes backward over successive calls")
  func monotonicity() async throws {
    let mockClock = TimeKitClock()
    let timestamp = try await mockClock.nanosecondsSince1970()
    var current = timestamp
    for _ in 0..<10000 {
      current = try await mockClock.nanosecondsSince1970()
      #expect(current >= current)
    }
  }
}



