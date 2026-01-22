// TODO: https://github.com/tikv/minstant a monotonic_coarse combining tsc and rdscp to optimize further sounds great.

import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `TimeKit` lazily initializes a single shared `TimeKitClock` (anchors captured on first access),
/// then `nanosecondsSince1970()` forwards to that actor-safe instance.
///
///     let t0 = await TimeKit.nanosecondsSince1970()
///
public enum TimeKit: Sendable {
  private static let clock = TimeKitClock()
  
  public static func nanosecondsSince1970() async throws -> UInt64 {
    try await clock.nanosecondsSince1970()
  }
}

/// Returns a synthetic Unix-epoch nanosecond timestamp: anchored to realtime for UTC meaning,
/// advanced by monotonic deltas for stability, never decreases,
/// and optionally snaps/slews to keep bounded drift (max lead/lag) relative to realtime.
///
/// Initialized once by capturing the current realtime (epoch) and monotonic clocks as anchors;
/// all subsequent timestamps are derived from these anchors plus monotonic deltas.
///
///     let clock = TimeKitClock()   // captures initial realtime + monotonic anchors
///
public actor TimeKitClock: Sendable {
  private var maxleadNS: UInt64
  private var maxlagNS: UInt64
  
  private var realtimeNS: UInt64
  private var monotimeNS: UInt64
  private var timeNS: UInt64
  
  public init(
    _ maxleadNS: UInt64 = 50_000_000,
    _ maxlagNS: UInt64 = 250_000_000
  ) {
    let realtimeNow = Self.realtimeNow()
    let monotimeNow = Self.monotimeNow()
    
    self.maxleadNS = maxleadNS
    self.maxlagNS = maxlagNS
    
    self.realtimeNS = realtimeNow
    self.monotimeNS = monotimeNow
    self.timeNS = realtimeNow
  }
  
  /// Get realtime in nanoseconds
  private static func realtimeNow() -> UInt64 {
#if canImport(Darwin)
    var ts = timespec()
    precondition(clock_gettime(CLOCK_REALTIME, &ts) == 0, "clock_gettime REALTIME failed")
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
#elseif os(Linux)
    var ts = timespec()
    precondition(clock_gettime(CLOCK_REALTIME, &ts) == 0, "clock_gettime REALTIME failed")
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
#else
    let timeInterval = Date().timeIntervalSince1970
    return UInt64(timeInterval * 1_000_000_000)
#endif  // os(Linux)
  }
  
  /// Get monotonic time in nanoseconds
  private static func monotimeNow() -> UInt64 {
#if os(Darwin)
    var ts = timespec()
    precondition(clock_gettime(CLOCK_MONOTONIC, &ts) == 0, "clock_gettime MONOTONIC failed")
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
#elseif os(Linux)
    var ts = timespec()
    precondition(clock_gettime(CLOCK_MONOTONIC, &ts) == 0, "clock_gettime MONOTONIC failed")
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
#else
    return DispatchTime.now().uptimeNanoseconds
#endif  // os(Linux)
  }
  
  /// Get current timestamp in nanoseconds
  private func clock() -> UInt64 {
    let realtimeNow = Self.realtimeNow()
    let monotimeNow = Self.monotimeNow()
    
    let delta = monotimeNow &- monotimeNS
    var anchor = max(realtimeNS &+ delta, timeNS)
    
    if anchor < timeNS { anchor = timeNS }
    
    if anchor >= realtimeNow {
      let lead = anchor - realtimeNow
      if lead > maxleadNS {
        realtimeNS = (realtimeNow &+ maxleadNS) &- (monotimeNow &- monotimeNS)
        anchor = realtimeNow &+ maxleadNS } }
    
    else {
      let lag = realtimeNow - anchor
      if lag > maxlagNS {
        realtimeNS = realtimeNow &- (monotimeNow &- monotimeNS)
        anchor = realtimeNow } }
    
    timeNS = anchor
    return anchor
  }
  
  public func nanosecondsSince1970() async throws -> UInt64 {
    return clock()
  }
}
