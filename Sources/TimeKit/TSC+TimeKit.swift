import Foundation
import CTimeKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif



// MARK: - Public Interface

/// High-performance physical clock optimized for x86_64 servers
///
/// **Primary path:** TSC (Intel Xeon / AMD EPYC) - ~15ns per read
/// **Fallback:** CLOCK_MONOTONIC (calibrated to wall time) - ~100ns per read
public enum TimeKitClock {
  
  /// Read current physical time in nanoseconds since Unix epoch
  @inline(__always)
  public static func read() -> UInt64 {
#if arch(x86_64) || arch(i386)
    // PRIMARY PATH: TSC (90% of servers)
    if let cal = tscCalibration {
      let cycles = c_rdtsc()
      let nanos = UInt64(Double(cycles) / cal.cyclesPerNanosecond)
      return UInt64(Int64(nanos) + cal.offsetNanoseconds)
    }
#endif
    
    // FALLBACK: Calibrated CLOCK_MONOTONIC
    return readMonotonicClock()
  }
  
  /// Whether TSC is being used (vs fallback)
  public static var isUsingTSC: Bool {
#if arch(x86_64) || arch(i386)
    return tscCalibration != nil
#else
    return false
#endif
  }
  
  /// Information about the clock source being used
  public static var clockInfo: ClockInfo {
#if arch(x86_64) || arch(i386)
    if let cal = tscCalibration {
      return ClockInfo(
        source: .tsc,
        estimatedLatencyNanoseconds: 15,
        cyclesPerNanosecond: cal.cyclesPerNanosecond
      )
    }
#endif
    
    return ClockInfo(
      source: .monotonicClock,
      estimatedLatencyNanoseconds: 100,
      cyclesPerNanosecond: nil
    )
  }
}

// MARK: - Clock Info

public struct ClockInfo: CustomStringConvertible {
  public enum Source {
    case tsc
    case monotonicClock
  }
  
  public let source: Source
  public let estimatedLatencyNanoseconds: UInt64
  public let cyclesPerNanosecond: Double?
  
  public var description: String {
    switch source {
    case .tsc:
      let freq = cyclesPerNanosecond.map { String(format: "%.2f", $0) } ?? "unknown"
      return "TSC (\(freq) cycles/ns, ~\(estimatedLatencyNanoseconds)ns latency)"
    case .monotonicClock:
      return "CLOCK_MONOTONIC (calibrated, ~\(estimatedLatencyNanoseconds)ns latency)"
    }
  }
}

// MARK: - x86/x86_64 TSC Implementation

#if arch(x86_64) || arch(i386)

/// TSC calibration data (initialized once at startup)
private struct TSCCalibration {
  let offsetNanoseconds: Int64
  let cyclesPerNanosecond: Double
}

/// Global TSC calibration (lazy initialized)
private let tscCalibration: TSCCalibration? = {
  return calibrateTSC()
}()

/// Check if CPU supports invariant TSC
private func hasInvariantTSC() -> Bool {
#if os(Linux)
  // Check /proc/cpuinfo (most reliable on Linux servers)
  guard let cpuinfo = try? String(contentsOfFile: "/proc/cpuinfo") else {
    return c_has_invariant_tsc()  // Fallback to CPUID
  }
  
  // Modern Intel Xeon (Nehalem+, 2008) and AMD EPYC all have both flags
  let hasConstantTSC = cpuinfo.contains("constant_tsc")
  let hasNonstopTSC = cpuinfo.contains("nonstop_tsc")
  
  return hasConstantTSC && hasNonstopTSC
  
#else
  // On non-Linux, use CPUID instruction via C
  return c_has_invariant_tsc()
#endif
}

/// Calibrate TSC frequency and offset to wall-clock time
private func calibrateTSC() -> TSCCalibration? {
  // Verify TSC is safe to use
  guard hasInvariantTSC() else {
    print("⚠️  TimeKitClock: TSC not invariant - using CLOCK_MONOTONIC fallback")
    return nil
  }
  
  // Calibrate TSC frequency by sampling over 100ms
  var samples: [(tsc: UInt64, nanos: UInt64)] = []
  
  for _ in 0..<10 {
    let tsc1 = c_rdtsc()
    let nanos1 = readWallClockForCalibration()
    
    usleep(10_000) // 10ms
    
    let tsc2 = c_rdtsc()
    let nanos2 = readWallClockForCalibration()
    
    samples.append((tsc1, nanos1))
    samples.append((tsc2, nanos2))
  }
  
  // Calculate TSC frequency (cycles per nanosecond)
  guard let first = samples.first, let last = samples.last else {
    print("⚠️  TimeKitClock: TSC calibration failed (no samples)")
    return nil
  }
  
  let tscDelta = Double(last.tsc - first.tsc)
  let nanosDelta = Double(last.nanos - first.nanos)
  
  guard nanosDelta > 0 else {
    print("⚠️  TimeKitClock: TSC calibration failed (zero time delta)")
    return nil
  }
  
  let cyclesPerNanosecond = tscDelta / nanosDelta
  
  // Calculate offset to align TSC with wall clock
  let currentTSC = c_rdtsc()
  let currentNanos = readWallClockForCalibration()
  let offsetNanoseconds = Int64(currentNanos) - Int64(Double(currentTSC) / cyclesPerNanosecond)
  
  let freqMHz = cyclesPerNanosecond * 1000
  print("✅ TimeKitClock: TSC calibrated at \(String(format: "%.2f", freqMHz)) MHz (~15ns latency)")
  
  return TSCCalibration(
    offsetNanoseconds: offsetNanoseconds,
    cyclesPerNanosecond: cyclesPerNanosecond
  )
}

#endif

// arch(x86_64) || arch(i386)


// MARK: - Monotonic Clock Fallback

/// Monotonic clock calibration (initialized once at startup)
private struct MonotonicCalibration {
  let offsetNanoseconds: Int64
}

/// Global monotonic calibration (lazy initialized)
private let monotonicCalibration: MonotonicCalibration = {
  return calibrateMonotonicClock()
}()

/// Read monotonic clock calibrated to wall-clock time
@inline(__always)
private func readMonotonicClock() -> UInt64 {
  let monotonic = readRawMonotonicClock()
  return UInt64(Int64(monotonic) + monotonicCalibration.offsetNanoseconds)
}

/// Read raw CLOCK_MONOTONIC (nanoseconds since boot)
@inline(__always)
private func readRawMonotonicClock() -> UInt64 {
  var ts = timespec()
  
#if os(Linux)
  // Use CLOCK_MONOTONIC_RAW on Linux (not adjusted by NTP)
  guard clock_gettime(CLOCK_MONOTONIC_RAW, &ts) == 0 else {
    preconditionFailure("Failed to read CLOCK_MONOTONIC_RAW")
  }
#else
  // Use CLOCK_MONOTONIC on other platforms
  guard clock_gettime(CLOCK_MONOTONIC, &ts) == 0 else {
    preconditionFailure("Failed to read CLOCK_MONOTONIC")
  }
#endif
  
  return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

/// Calibrate CLOCK_MONOTONIC to wall-clock time
private func calibrateMonotonicClock() -> MonotonicCalibration {
  let monotonic = readRawMonotonicClock()
  let wallClock = readWallClockForCalibration()
  
  let offsetNanoseconds = Int64(wallClock) - Int64(monotonic)
  
  print("✅ TimeKitClock: CLOCK_MONOTONIC calibrated (offset: \(offsetNanoseconds)ns, ~100ns latency)")
  
  return MonotonicCalibration(offsetNanoseconds: offsetNanoseconds)
}

// MARK: - Wall Clock (for calibration only)

/// Read wall clock (CLOCK_REALTIME) - only used for calibration
private func readWallClockForCalibration() -> UInt64 {
  var ts = timespec()
  guard clock_gettime(CLOCK_REALTIME, &ts) == 0 else {
    preconditionFailure("Failed to read CLOCK_REALTIME")
  }
  return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}
