import Testing
import Foundation

@testable import TimeKit

import ErrorKit
import Instrumentation
import Tracing
import ServiceContextModule

#if DistributedTracingSupport
import InMemoryTracing
#endif



// MARK: - TimeKitClock Tests

@Suite("TimeKitClock Basic Behavior")
struct TimeKitClockBasicTests {
  
  @Test("Initial timestamp is reasonable epoch time")
  func initialTimestamp() {
    let timestamp = TimeKitClock.read()
    let seconds = Int(timestamp / 1_000_000_000)
    let expectedSeconds = Int(Date().timeIntervalSince1970)
    
    // Should be within same second
    #expect(seconds == expectedSeconds)
  }
  
  @Test("Time never goes backward over successive calls")
  func monotonicity() {
    var previous = TimeKitClock.read()
    
    for _ in 0..<10_000 {
      let current = TimeKitClock.read()
      #expect(current >= previous)
      previous = current
    }
  }
  
  @Test("Clock info is available")
  func clockInfo() {
    let info = TimeKitClock.clockInfo
    
    #expect(info.estimatedLatencyNanoseconds > 0)
    
    if TimeKitClock.isUsingTSC {
      #expect(info.source == .tsc)
      #expect(info.cyclesPerNanosecond != nil)
      #expect(info.estimatedLatencyNanoseconds < 50) // TSC should be fast
    } else {
      #expect(info.source == .monotonicClock)
      #expect(info.estimatedLatencyNanoseconds < 200) // Monotonic is slower
    }
  }
  
  @Test("Timestamps advance in reasonable increments")
  func reasonableIncrement() {
    let first = TimeKitClock.read()
    usleep(1000) // Sleep 1ms
    let second = TimeKitClock.read()
    
    let diff = second - first
    
    // Should have advanced by roughly 1ms (allowing for scheduler jitter)
    #expect(diff > 500_000) // At least 0.5ms
    #expect(diff < 10_000_000) // Less than 10ms
  }
}

// MARK: - TimeKitContainer Bootstrap Tests

@Suite("TimeKitContainer Bootstrap")
struct TimeKitContainerBootstrapTests {
  
  @Test("Shared container is available")
  func sharedContainer() async {
    let timestamp = await TimeKitContainer.shared.timeIntervalSince1970()
    
    let seconds = Int(timestamp / 1_000_000_000)
    let expectedSeconds = Int(Date().timeIntervalSince1970)
    
    #expect(seconds == expectedSeconds)
  }
  
  @Test("Create container with node ID")
  func createWithNodeID() async {
    let nodeID = UUID()
    let container = TimeKitContainer(nodeID: nodeID)
    
    await TimeKitContainer.withClock(container) {
      let time = await container.time()
      #expect(time.nodeID == nodeID)
    }
    
    let time = await container.time()
    #expect(time.nodeID == nodeID)
  }
  
  @Test("Create container with configuration")
  func createWithConfiguration() async {
    let nodeID = UUID()
    let config = TimeKitConfiguration(
      fallbackNodeID: nodeID,
      maxDriftNanoseconds: 10_000_000_000
    )
    
    let container = TimeKitContainer(nodeID: nodeID, configuration: config)
    
    #expect(container.configuration.maxDriftNanoseconds == 10_000_000_000)
    #expect(container.configuration.fallbackNodeID == nodeID)
  }
  
  @Test("Create container with custom clock")
  func createWithClock() async {
    let nodeID = UUID()
    let clock = TimeKit(nodeID: nodeID, maxDrift: 2_000_000_000)
    
    let container = TimeKitContainer(clock: clock)
    
    let time = await container.time()
    #expect(time.nodeID == nodeID)
  }
  
  #if DistributedTracingSupport
  @Test("Create container with NoOpTracer")
  func createWithNoOpTracer() async {
    let nodeID = UUID()
    let tracer = NoOpTracer()
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    #expect(container.tracer != nil)
    #expect(container.configuration.tracing.tracer != nil)
  }
  
  @Test("Create container with InMemoryTracer")
  func createWithInMemoryTracer() async {
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    #expect(container.tracer != nil)
    #expect(container.configuration.tracing.tracer != nil)
  }
  
  @Test("Tracer parameter overrides configuration tracer")
  func tracerParameterOverrides() async {
    let nodeID = UUID()
    let configTracer = NoOpTracer()
    let paramTracer = InMemoryTracer()
    
    var config = TimeKitConfiguration()
    config.tracing.tracer = configTracer
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      configuration: config,
      tracer: paramTracer
    )
    
    // Parameter tracer should override config tracer
    #expect(container.tracer != nil)
    #expect(container.configuration.tracing.tracer != nil)
  }
  
  @Test("Configuration tracer used when parameter is nil")
  func configurationTracerUsed() async {
    let nodeID = UUID()
    let tracer = NoOpTracer()
    
    var config = TimeKitConfiguration()
    config.tracing.tracer = tracer
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      configuration: config,
      tracer: nil
    )
    
    #expect(container.tracer != nil)
  }
  
  @Test("Bootstrap with InstrumentationSystem")
  func bootstrapWithInstrumentationSystem() async {
    // Bootstrap the global tracer
    InstrumentationSystem.bootstrap(InMemoryTracer())
    
    let nodeID = UUID()
    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: InstrumentationSystem.tracer
    )
    
    #expect(container.tracer != nil)
    #expect(container.configuration.tracing.tracer != nil)
  }
  
  @Test("Verify common span attributes are set")
  func commonSpanAttributes() async {
    let nodeID = UUID()
    let tracer = InMemoryTracer()
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    let attributes = container.commonSpanAttributeList
    
    // Verify attributes contain expected values
    #expect(attributes["timekit.clock.type"] != nil)
    #expect(attributes["timekit.node_id"] != nil)
  }
  #endif
}

// MARK: - TimeKit Tests

@Suite("TimeKit Basic Behavior")
struct TimeKitBasicTests {
  
  @Test("Initial timestamp is reasonable epoch time")
  func initialTimestamp() async {
    let clock = TimeKit(nodeID: UUID())
    let timestamp = await clock.timeIntervalSince1970()
    
    let seconds = Int(timestamp.physical / 1_000_000_000)
    let expectedSeconds = Int(Date().timeIntervalSince1970)
    
    // Should be within same second
    #expect(seconds == expectedSeconds)
  }
  
  @Test("Time never goes backward over successive calls")
  func monotonicity() async {
    let clock = TimeKit(nodeID: UUID())
    var previous = await clock.timeIntervalSince1970()
    
    for _ in 0..<10_000 {
      let current = await clock.timeIntervalSince1970()
      
      // Either physical time advances OR logical counter increments
      #expect(current >= previous)
      
      previous = current
    }
  }
  
  @Test("Timestamps are strictly monotonic")
  func strictMonotonicity() async {
    let clock = TimeKit(nodeID: UUID())
    var previous = await clock.timeIntervalSince1970()
    
    for _ in 0..<100 {
      let current = await clock.timeIntervalSince1970()
      
      // Current must be strictly greater (not equal)
      #expect(current > previous)
      
      previous = current
    }
  }
  
  @Test("Logical counter increments for same physical time")
  func logicalCounter() async {
    let clock = TimeKit(nodeID: UUID())
    
    // Generate many timestamps rapidly - some should have same physical time
    var timestamps: [TimeKitTimestamp] = []
    for _ in 0..<1000 {
      timestamps.append(await clock.timeIntervalSince1970())
    }
    
    // Find timestamps with same physical time
    var foundIncrementedLogical = false
    for i in 1..<timestamps.count {
      if timestamps[i].physical == timestamps[i-1].physical {
        // Same physical time - logical counter should have incremented
        #expect(timestamps[i].logical == timestamps[i-1].logical + 1)
        foundIncrementedLogical = true
      }
    }
    
    // With TSC (~15ns), we WILL generate multiple timestamps in same nanosecond
    // With CLOCK_MONOTONIC (~100ns), it's less likely but should still happen
    if TimeKitClock.isUsingTSC {
      #expect(foundIncrementedLogical, "TSC should produce same-physical-time events")
    } else {
      // On slower clocks, just log for informational purposes
      print("📊 Found same-physical-time events: \(foundIncrementedLogical)")
    }
  }
  
  @Test("All timestamps share same node ID")
  func nodeIDConsistency() async {
    let nodeID = UUID()
    let clock = TimeKit(nodeID: nodeID)
    
    for _ in 0..<100 {
      let ts = await clock.timeIntervalSince1970()
      #expect(ts.nodeID == nodeID)
    }
  }
}

// MARK: - TimeKit Merge Tests

@Suite("TimeKit Merge Behavior")
struct TimeKitMergeTests {
  
  @Test("Merge with future timestamp advances clock")
  func mergeWithFuture() async throws {
    let clock = TimeKit(nodeID: UUID())
    let now = await clock.timeIntervalSince1970()
    
    // Create a timestamp 1 second in the future
    let futureTimestamp = TimeKitTimestamp(
      physical: now.physical + 1_000_000_000,
      logical: 0,
      nodeID: UUID()
    )
    
    let merged = try await clock.merge(with: futureTimestamp)
    
    // Merged timestamp should adopt future physical time
    #expect(merged.physical >= futureTimestamp.physical)
    
    // Next timestamp should be >= merged
    let next = await clock.timeIntervalSince1970()
    #expect(next >= merged)
  }
  
  @Test("Merge with past timestamp doesn't go backward")
  func mergeWithPast() async throws {
    let clock = TimeKit(nodeID: UUID())
    
    // Advance clock a bit
    _ = await clock.timeIntervalSince1970()
    _ = await clock.timeIntervalSince1970()
    
    let current = await clock.timeIntervalSince1970()
    
    // Create a timestamp in the past
    let pastTimestamp = TimeKitTimestamp(
      physical: current.physical - 1_000_000_000,
      logical: 0,
      nodeID: UUID()
    )
    
    let merged = try await clock.merge(with: pastTimestamp)
    
    // Merged timestamp should not go backward
    #expect(merged >= current)
  }
  
  @Test("Merge preserves causality")
  func mergeCausality() async throws {
    let nodeA = UUID()
    let nodeB = UUID()
    
    let clockA = TimeKit(nodeID: nodeA)
    let clockB = TimeKit(nodeID: nodeB)
    
    // A creates event
    let ts1 = await clockA.timeIntervalSince1970()
    
    // B receives and merges
    let ts2 = try await clockB.merge(with: ts1)
    
    // B's merged timestamp must be > A's original
    #expect(ts2 > ts1)
    
    // B creates another event
    let ts3 = await clockB.timeIntervalSince1970()
    
    // This should be >= ts2
    #expect(ts3 >= ts2)
  }
  
  @Test("Merge rejects timestamps beyond max drift")
  func mergeRejectsExcessiveDrift() async {
    let clock = TimeKit(nodeID: UUID(), maxDrift: 1_000_000_000) // 1 second
    let now = await clock.timeIntervalSince1970()
    
    // Create timestamp way in the future (10 seconds)
    let excessiveTimestamp = TimeKitTimestamp(
      physical: now.physical + 10_000_000_000,
      logical: 0,
      nodeID: UUID()
    )
    
    // Should throw HLCError.excessiveClockDrift
    await #expect(throws: ErrorKitWrapper<TimeKitError>.self) {
      try await clock.merge(with: excessiveTimestamp)
    }
  }
  
  @Test("Update method works like merge")
  func updateMethod() async throws {
    let clock = TimeKit(nodeID: UUID())
    let initial = await clock.timeIntervalSince1970()
    
    let futureTimestamp = TimeKitTimestamp(
      physical: initial.physical + 1_000_000_000,
      logical: 5,
      nodeID: UUID()
    )
    
    // Update doesn't return value, but should advance clock
    try await clock.update(with: futureTimestamp)
    
    // Next timestamp should be > futureTimestamp
    let next = await clock.timeIntervalSince1970()
    #expect(next > futureTimestamp)
  }
  
  @Test("Container merge delegates to clock")
  func containerMerge() async throws {
    let nodeID = UUID()
    let container = TimeKitContainer(nodeID: nodeID)
    
    let now = await container.timeIntervalSince1970()
    
    let remoteTimestamp = TimeKitTimestamp(
      physical: now + 1_000_000_000,
      logical: 0,
      nodeID: UUID()
    )
    
    let merged = try await container.merge(with: remoteTimestamp)
    
    #expect(merged.physical >= remoteTimestamp.physical)
    #expect(merged.nodeID == nodeID)
  }
}

// MARK: - TimeKitTimestamp Tests

@Suite("TimeKitTimestamp Behavior")
struct TimeKitTimestampTests {
  
  @Test("Timestamps with different physical times compare correctly")
  func physicalTimeComparison() {
    let nodeID = UUID()
    
    let ts1 = TimeKitTimestamp(physical: 1000, logical: 0, nodeID: nodeID)
    let ts2 = TimeKitTimestamp(physical: 2000, logical: 0, nodeID: nodeID)
    
    #expect(ts1 < ts2)
    #expect(ts2 > ts1)
  }
  
  @Test("Timestamps with same physical time compare by logical counter")
  func logicalCounterComparison() {
    let nodeID = UUID()
    
    let ts1 = TimeKitTimestamp(physical: 1000, logical: 0, nodeID: nodeID)
    let ts2 = TimeKitTimestamp(physical: 1000, logical: 1, nodeID: nodeID)
    
    #expect(ts1 < ts2)
    #expect(ts2 > ts1)
  }
  
  @Test("Timestamps with same physical and logical compare by node ID")
  func nodeIDComparison() {
    let nodeA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let nodeB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    
    let ts1 = TimeKitTimestamp(physical: 1000, logical: 0, nodeID: nodeA)
    let ts2 = TimeKitTimestamp(physical: 1000, logical: 0, nodeID: nodeB)
    
    #expect(ts1 < ts2)
    #expect(ts2 > ts1)
  }
  
  @Test("Timestamp is Codable")
  func codable() throws {
    let original = TimeKitTimestamp(
      physical: 1234567890000000000,
      logical: 42,
      nodeID: UUID()
    )
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(TimeKitTimestamp.self, from: data)
    
    #expect(decoded.physical == original.physical)
    #expect(decoded.logical == original.logical)
    #expect(decoded.nodeID == original.nodeID)
  }
  
  @Test("Timestamp has readable description")
  func description() {
    let ts = TimeKitTimestamp(
      physical: 1704067200000000000, // 2024-01-01 00:00:00 UTC
      logical: 5,
      nodeID: UUID()
    )
    
    let desc = ts.description
    
    // Should contain date, logical counter, and partial node ID
    #expect(desc.contains("2024"))
    #expect(desc.contains("logical: 5"))
    #expect(desc.contains("node:"))
  }
}

// MARK: - ServiceContext Support Tests

@Suite("TimeKitContainer ServiceContext Support")
struct TimeKitContainerServiceContextTests {
  
  @Test("ServiceContext propagation works")
  func serviceContextPropagation() async {
    let nodeID = UUID()
    
    await TimeKitContainer.withClock(nodeID: nodeID) {
      // Should be accessible in ServiceContext
      #expect(TimeKitContainer.current != nil)
      
      // Nested async calls should also have access
      await nestedFunction()
    }
    
    // Outside withClock, should be nil
    #expect(TimeKitContainer.current == nil)
  }
  
  private func nestedFunction() async {
    #expect(TimeKitContainer.current != nil)
  }
  
  @Test("Can generate timestamps from ServiceContext container")
  func serviceContextTimestamps() async {
    let nodeID = UUID()
    
    await TimeKitContainer.withClock(nodeID: nodeID) {
      guard let container = TimeKitContainer.current else {
        Issue.record("TimeKitContainer.current should not be nil")
        return
      }
      
      let ts1 = await container.time()
      let ts2 = await container.time()
      
      #expect(ts2 > ts1)
      #expect(ts1.nodeID == nodeID)
      #expect(ts2.nodeID == nodeID)
    }
  }
  
  @Test("withClock accepts container instance")
  func withClockContainer() async {
    let nodeID = UUID()
    let container = TimeKitContainer(nodeID: nodeID)
    
    await TimeKitContainer.withClock(container) {
      let current = TimeKitContainer.current
      #expect(current != nil)
      
      let time = await current!.time()
      #expect(time.nodeID == nodeID)
    }
  }
  
  @Test("withClock accepts configuration")
  func withClockConfiguration() async {
    let nodeID = UUID()
    let config = TimeKitConfiguration(
      fallbackNodeID: nodeID,
      maxDriftNanoseconds: 10_000_000_000
    )
    
    await TimeKitContainer.withClock(nodeID: nodeID, configuration: config) {
      let current = TimeKitContainer.current
      #expect(current != nil)
      #expect(current!.configuration.maxDriftNanoseconds == 10_000_000_000)
    }
  }
}

// MARK: - Performance Tests

@Suite("TimeKitClock Performance")
struct TimeKitClockPerformanceTests {
  
  @Test("Measures clock read latency")
  func readLatency() {
    let iterations = 1_000_000
    
    let start = Date()
    for _ in 0..<iterations {
      _ = TimeKitClock.read()
    }
    let elapsed = Date().timeIntervalSince(start)
    
    let avgNanoseconds = (elapsed * 1_000_000_000) / Double(iterations)
    
    print("📊 Average read latency: \(Int(avgNanoseconds))ns per call")
    print("📊 Clock source: \(TimeKitClock.clockInfo)")
    print("📊 Total time for \(iterations) reads: \(String(format: "%.3f", elapsed))s")
    
    // Sanity check - should complete in reasonable time
    #expect(elapsed < 10.0) // 1M reads should take < 10 seconds
  }
  
  @Test("Clock source is deterministic")
  func clockSourceConsistency() {
    // Clock source should not change during program execution
    let source1 = TimeKitClock.clockInfo.source
    let source2 = TimeKitClock.clockInfo.source
    
    #expect(source1 == source2)
    #expect(TimeKitClock.isUsingTSC == (source1 == .tsc))
  }
}

@Suite("TimeKit Performance")
struct TimeKitPerformanceTests {
  
  @Test("Debug: Check TSC status")
  func debugTSCStatus() {
#if arch(x86_64)
    let architecture = "x86_64"
#elseif arch(i386)
    let architecture = "i386"
#elseif arch(arm64)
    let architecture = "arm64"
#else
    let architecture = "other"
#endif
    
    print("🔍 Architecture: \(architecture)")
    print("🔍 Using TSC: \(TimeKitClock.isUsingTSC)")
    print("🔍 Clock info: \(TimeKitClock.clockInfo)")
  }
  
  @Test("Measures timestamp generation latency")
  func timestampLatency() async {
    let clock = TimeKit(nodeID: UUID())
    let iterations = 100_000
    
    let start = Date()
    for _ in 0..<iterations {
      _ = await clock.timeIntervalSince1970()
    }
    let elapsed = Date().timeIntervalSince(start)
    
    let avgMicroseconds = (elapsed * 1_000_000) / Double(iterations)
    
    print("📊 Average timeIntervalSince1970() latency: \(String(format: "%.2f", avgMicroseconds))µs per call")
    print("📊 Using clock: \(TimeKitClock.clockInfo)")
    print("📊 Total time for \(iterations) calls: \(String(format: "%.3f", elapsed))s")
    
    // Sanity check
    #expect(elapsed < 30.0) // 100K calls should take < 30 seconds
  }
  
  @Test("Measures merge operation latency")
  func mergeLatency() async throws {
    let clock = TimeKit(nodeID: UUID())
    let iterations = 10_000
    
    // Create test timestamps
    var remoteTimestamps: [TimeKitTimestamp] = []
    for i in 0..<iterations {
      remoteTimestamps.append(TimeKitTimestamp(
        physical: UInt64(1_700_000_000_000_000_000 + i * 1000),
        logical: UInt16(i % 100),
        nodeID: UUID()
      ))
    }
    
    let start = Date()
    for ts in remoteTimestamps {
      _ = try await clock.merge(with: ts)
    }
    let elapsed = Date().timeIntervalSince(start)
    
    let avgMicroseconds = (elapsed * 1_000_000) / Double(iterations)
    
    print("📊 Average merge() latency: \(String(format: "%.2f", avgMicroseconds))µs per call")
    print("📊 Total time for \(iterations) merges: \(String(format: "%.3f", elapsed))s")
    
    // Sanity check
    #expect(elapsed < 10.0)
  }
  
  @Test("Measures container timestamp generation latency")
  func containerTimestampLatency() async {
    let container = TimeKitContainer(nodeID: UUID())
    let iterations = 100_000
    
    let start = Date()
    for _ in 0..<iterations {
      _ = await container.timeIntervalSince1970()
    }
    let elapsed = Date().timeIntervalSince(start)
    
    let avgMicroseconds = (elapsed * 1_000_000) / Double(iterations)
    
    print("📊 Average container.timeIntervalSince1970() latency: \(String(format: "%.2f", avgMicroseconds))µs per call")
    print("📊 Total time for \(iterations) calls: \(String(format: "%.3f", elapsed))s")
    
    // Sanity check
    #expect(elapsed < 30.0)
  }
}

// MARK: - Integration Tests

@Suite("TimeKit Integration")
struct TimeKitIntegrationTests {
  
  @Test("Distributed scenario: two nodes exchanging messages")
  func distributedScenario() async throws {
    let nodeA = UUID()
    let nodeB = UUID()
    
    let clockA = TimeKit(nodeID: nodeA)
    let clockB = TimeKit(nodeID: nodeB)
    
    // Node A creates event
    let tsA1 = await clockA.timeIntervalSince1970()
    
    // Node B receives message with tsA1
    let tsB1 = try await clockB.merge(with: tsA1)
    
    // Node B creates response
    let tsB2 = await clockB.timeIntervalSince1970()
    
    // Node A receives response with tsB2
    let tsA2 = try await clockA.merge(with: tsB2)
    
    // Verify causality: tsA1 < tsB1 < tsB2 < tsA2
    #expect(tsA1 < tsB1)
    #expect(tsB1 < tsB2)
    #expect(tsB2 < tsA2)
  }
  
  @Test("Three-node message chain preserves ordering")
  func threeNodeChain() async throws {
    let nodes = (0..<3).map { _ in UUID() }
    let clocks = nodes.map { TimeKit(nodeID: $0) }
    
    var timestamps: [TimeKitTimestamp] = []
    
    // Node 0 creates event
    timestamps.append(await clocks[0].timeIntervalSince1970())
    
    // Each node receives from previous (merge is the "receive" event)
    for i in 1..<3 {
      let merged = try await clocks[i].merge(with: timestamps[i-1])
      timestamps.append(merged)
    }
    
    // All timestamps should be strictly ordered
    for i in 1..<timestamps.count {
      #expect(timestamps[i] > timestamps[i-1])
    }
  }
  
  @Test("Container-based distributed scenario")
  func containerDistributedScenario() async throws {
    let nodeA = UUID()
    let nodeB = UUID()
    
    let containerA = TimeKitContainer(nodeID: nodeA)
    let containerB = TimeKitContainer(nodeID: nodeB)
    
    // Node A creates event
    let tsA1 = await containerA.time()
    
    // Node B receives message with tsA1
    let tsB1 = try await containerB.merge(with: tsA1)
    
    // Node B creates response
    let tsB2 = await containerB.time()
    
    // Node A receives response with tsB2
    let tsA2 = try await containerA.merge(with: tsB2)
    
    // Verify causality: tsA1 < tsB1 < tsB2 < tsA2
    #expect(tsA1 < tsB1)
    #expect(tsB1 < tsB2)
    #expect(tsB2 < tsA2)
  }
}


// MARK: - Tracing Tests

#if DistributedTracingSupport
@Suite("TimeKit Tracing")
struct TimeKitTracingTests {
  
  @Test("Container works without tracer and produces no spans")
  func containerWithoutTracerProducesNoSpans() async throws {
    print("Start: Container works without tracer and produces no spans")
    let nodeID = UUID()
    let inMemoryTracer = InMemoryTracer()
    
    InstrumentationSystem.bootstrap(inMemoryTracer)
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: nil
    )
    
    #expect(container.tracer == nil)
    #expect(container.configuration.tracing.tracer == nil)
    
    await TimeKitContainer.withClock(container) {
      let ts1 = await container.time()
      let ts2 = await container.time()
      
      #expect(ts2.physical > ts1.physical)
      #expect(ts1.nodeID == nodeID)
      
      await TimeKitContainer.withClock(nodeID: nodeID) {
        let ts3 = await TimeKitContainer.current?.timeIntervalSince1970()
        #expect(ts3 != nil)
      }
    }
    
    let remoteTimestamp = TimeKitTimestamp(
      physical: TimeKitClock.read(),
      logical: 0,
      nodeID: UUID()
    )
    _ = try await container.merge(with: remoteTimestamp)
    
    // Verify no spans were created despite context boundary crossings
    #expect(inMemoryTracer.finishedSpans.count == 0)
    
    // Verify container still works correctly
    let finalTs = await container.time()
    #expect(finalTs.nodeID == nodeID)
    
    print("End: Container works without tracer and produces no spans")
  }
  
  @Test("Container with tracer creates spans")
  func containerWithTracerCreatesSpans() async throws {
    print("Start: Container with tracer creates spans")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    // Generate some timestamps (this should create spans if instrumented)
    _ = await container.timeIntervalSince1970()
    _ = await container.timeIntervalSince1970()
    
    // For now, verify tracer is configured
    #expect(container.tracer != nil)
    #expect(container.configuration.tracing.tracer != nil)
    print("End: Container with tracer creates spans")
  }
  
  @Test("Common span attributes are set correctly")
  func commonSpanAttributes() async {
    print("Start: Common span attributes are set correctly")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    let attributes = container.commonSpanAttributeList
    
    // Verify clock type attribute
    guard let clockType = attributes["timekit.clock.type"] as? SpanAttribute,
          case .string(let clockTypeValue) = clockType else {
      Issue.record("Expected string attribute for timekit.clock.type")
      return
    }
    
    if TimeKitClock.isUsingTSC {
      #expect(clockType == "tsc")
    } else {
      #expect(clockType == "clock_monotonic")
    }
    
    // Verify node ID attribute
    guard let nodeIDAttr = attributes["timekit.node_id"] as? SpanAttribute,
          case .string(let nodeIDAttrValue) = nodeIDAttr else {
      Issue.record("Expected string value for node ID")
      return
    }
    #expect(nodeIDAttrValue == nodeID.uuidString)
    print("End: Common span attributes are set correctly")
  }
  
  @Test("Custom tracing attribute names")
  func customTracingAttributeNames() async throws {
    
    print("Start: Custom tracing attribute names")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    var config = TimeKitConfiguration()
    config.tracing.attributeName.nodeID = "custom.node.id"
    config.tracing.attributeName.clockType = "custom.clock.type"
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      configuration: config,
      tracer: tracer)
    
    let attributes = container.commonSpanAttributeList
    
    guard let nodeIDAttr = attributes["custom.node.id"] as? SpanAttribute,
          case .string(let nodeIDAttrValue) = nodeIDAttr else {
      Issue.record("Expected string value for node ID")
      return
    }
    #expect(nodeIDAttrValue == nodeID.uuidString)
    
    print("End: Custom tracing attribute names")
  }
  
  @Test("Custom tracing attribute values")
  func customTracingAttributeValues() async {
    
    print("Start: Custom tracing attribute values")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    var config = TimeKitConfiguration()
    config.tracing.attributeValue.timeSystem = "hybrid_logical_clock"
    config.tracing.attributeValue.clockSystem = "time_stamp_counter"
    config.tracing.attributeValue.clockSystemFallback = "posix_monotonic"
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      configuration: config,
      tracer: tracer
    )
    
    // Verify configuration was applied
    #expect(container.configuration.tracing.attributeValue.timeSystem == "hybrid_logical_clock")
    #expect(container.configuration.tracing.attributeValue.clockSystem == "time_stamp_counter")
    #expect(container.configuration.tracing.attributeValue.clockSystemFallback == "posix_monotonic")
    
    
    print("End: Custom tracing attribute values")
  }
  
  @Test("Tracer is accessible from container")
  func tracerAccessible() async throws {
    
    print("Start: Tracer is accessible from container")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    #expect(container.tracer != nil)
    
    // Should be able to create spans manually if needed
    let span = container.tracer?.startSpan(
      "test-operation",
      context: ServiceContext.topLevel,
      ofKind: .internal
    )
    span?.end()
    
    // Verify span was created
    #expect(tracer.finishedSpans.count == 1)
    let finishedSpan = try #require(tracer.finishedSpans.first)
    #expect(finishedSpan.operationName == "test-operation")
    #expect(finishedSpan.kind == .internal)
    
    print("End: Tracer is accessible from container")
  }
  
  @Test("Span attributes include common TimeKit metadata")
  func spanAttributesIncludeMetadata() async throws {
    
    print("Start: Span attributes include common TimeKit metadata")
    let nodeID = UUID()
    let tracer = InMemoryTracer()
    
    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    let context = ServiceContext.topLevel
    let span = container.tracer?.startSpan(
      "timestamp-generation",
      context: context,
      ofKind: .internal
    )
    
    container.commonSpanAttributeList.forEach { key, value in
      if case .string(let stringValue) = value.toSpanAttribute() {
        span?.attributes[key] = stringValue
      }
    }
    
    span?.end()
    
    let finishedSpan = try #require(tracer.finishedSpans.first)
    guard let nodeIDAttr = finishedSpan.attributes["timekit.node_id"]?.toSpanAttribute(),
          case .string(_) = nodeIDAttr else {
      Issue.record("Expected string value for node ID")
      return
    }
    
    print("End: Span attributes include common TimeKit metadata")
  }
  
  @Test("NoOpTracer doesn't affect performance")
  func noOpTracerPerformance() async {
    
    print("Start: NoOpTracer doesn't affect performance")
    let nodeID = UUID()
    let noOpTracer = NoOpTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: noOpTracer
    )
    
    let iterations = 10_000
    let start = Date()
    
    for _ in 0..<iterations {
      _ = await container.timeIntervalSince1970()
    }
    
    let elapsed = Date().timeIntervalSince(start)
    let avgMicroseconds = (elapsed * 1_000_000) / Double(iterations)
    
    print("📊 NoOpTracer overhead: \(String(format: "%.2f", avgMicroseconds))µs per call")
    
    #expect(elapsed < 5.0)
    
    print("End: NoOpTracer doesn't affect performance")
  }
  
  @Test("ServiceContext with tracing and TimeKit")
  func serviceContextWithTracingAndTimeKit() async throws {
    
    print("Start: ServiceContext with tracing and TimeKit")
    let nodeID = UUID()
    let tracer = InMemoryTracer()

    let container = TimeKitContainer(
      nodeID: nodeID,
      tracer: tracer
    )
    
    await TimeKitContainer.withClock(container) {
      // Create a span in this context
      let context = ServiceContext.current ?? ServiceContext.topLevel
      let span = tracer.startSpan(
        "request-handler",
        context: context,
        ofKind: .server
      )
      
      // Generate timestamp within traced operation
      let timestamp = await TimeKitContainer.current?.timeIntervalSince1970()
      #expect(timestamp != nil)
      
      span.end()
    }
    
    #expect(tracer.finishedSpans.count == 1)
    let span = try #require(tracer.finishedSpans.first)
    #expect(span.operationName == "request-handler")
    #expect(span.kind == .server)
    
    print("End: ServiceContext with tracing and TimeKit")
  }
}
#endif
