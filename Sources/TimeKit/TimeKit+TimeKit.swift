import Foundation

import ServiceContextModule
import ErrorKit
import Tracing



/// Context carrying TimeKit clock and configuration through async boundaries
public struct TimeKitContainer: Sendable {
  
  /// The HLC instance for this context
  public let clock: TimeKit
  
  /// Configuration for this context
  public let configuration: TimeKitConfiguration
  
#if DistributedTracingSupport
  /// The tracer for application-level tracing
  public let tracer: (any Tracer)?
  
  /// Common span attributes for operations using this clock
  public let commonSpanAttributeList: SpanAttributes
#endif
  
  /// Create a new TimeKit container with a specific node ID
  public static let shared: TimeKitContainer = .init(clock: .init(nodeID: TimeKitConfiguration.init().fallbackNodeID))
  
  /// Create a new TimeKit context
  public init(
    clock: TimeKit,
    configuration: TimeKitConfiguration? = nil,
    tracer: (any Tracer)? = nil
  ) {
    
    var configuration = configuration ?? .init()
#if DistributedTracingSupport
    if let tracer = tracer { configuration.tracing.tracer = tracer }
    self.commonSpanAttributeList = Self.createcommonAttributeList(configuration.fallbackNodeID, configuration: configuration)
#endif
    
    self.tracer = tracer
    self.clock = clock
    self.configuration = configuration
  }
  
  /// Create a new TimeKit context with a specific node ID
  public init(
    nodeID: UUID,
    configuration: TimeKitConfiguration? = nil,
    tracer: (any Tracer)? = nil
  ) {
    
    var configuration = configuration ?? .init()
#if DistributedTracingSupport
    if let tracer = tracer { configuration.tracing.tracer = tracer }
    self.commonSpanAttributeList = Self.createcommonAttributeList(nodeID, configuration: configuration)
#endif
    
    self.tracer = configuration.tracing.tracer ?? nil
    self.clock = TimeKit(nodeID: nodeID, maxDrift: configuration.maxDriftNanoseconds)
    self.configuration = configuration
  }
  
  /// Generate common attribute list.
  private static func createcommonAttributeList(_ nodeID: UUID? = nil, configuration: TimeKitConfiguration) -> SpanAttributes {
    var commonAttributeList: SpanAttributes = [
      configuration.tracing.attributeName.clockType:
          .string(configuration.tracing.attributeValue.timeSystem)
    ]
    
    if let nodeID = nodeID {
      commonAttributeList[configuration.tracing.attributeName.nodeID] = nodeID.uuidString
    }
    
    commonAttributeList[configuration.tracing.attributeName.clockType] = TimeKitClock.isUsingTSC
    ? configuration.tracing.attributeValue.clockSystem : configuration.tracing.attributeValue.clockSystemFallback
    
    return commonAttributeList
  }
  
  /// Merge a remote timestamp with the current container's clock
  public func merge(with remote: TimeKitTimestamp) async throws -> TimeKitTimestamp {
    try await self.clock.merge(with: remote)
  }
  
  /// Generate a timestamp from the current container's clock
  public func time() async -> TimeKitTimestamp {
    return await self.clock.timeIntervalSince1970()
  }
  
  /// The current Time in relation to the prospects.
  public func timeIntervalSince1970() async -> UInt64 {
    return await self.clock.timeIntervalSince1970().physical
  }
}


///
public struct TimeKitConfiguration: Sendable {
  
  /// Global fallback node ID when no context is available
  public var fallbackNodeID: UUID
  
  /// Maximum allowed clock drift (default: 5 seconds)
  public var maxDriftNanoseconds: UInt64
  
  #if DistributedTracingSupport
  /// The distributed tracing configuration to use for this connection.
  /// Defaults to using the globally bootstrapped tracer with OpenTelemetry semantic conventions.
  public var tracing: TimeKitTracingConfiguration
  #endif
  
  public init(
    fallbackNodeID: UUID = UUID(),
    maxDriftNanoseconds: UInt64 = 5_000_000_000,
    tracing: TimeKitTracingConfiguration? = nil
  ) {
    self.fallbackNodeID = fallbackNodeID
    self.maxDriftNanoseconds = maxDriftNanoseconds
    self.tracing = tracing ?? .init()
  }
}

/// Tracing configuration for TimeKit
#if DistributedTracingSupport
public struct TimeKitTracingConfiguration: Sendable {
  /// The tracer to use or `nil` to disable tracing.
  /// Defaults to the globally bootstrapped tracer.
  public var tracer: (any Tracer)? = nil
  
  /// The attribute names used in spans created by Stripe. Defaults to OpenTelemetry semantics.
  public var attributeName: AttributeName = .init()
  
  /// The attribute values used in spans created by Stripe.
  public var attributeValue: AttributeValue = .init()
  
  ///
  public init(tracer: (any Tracer)? = nil) {
    self.tracer = tracer
  }
  
  /// Attribute names used in spans created by Stripe.
  public struct AttributeName: Sendable {
    public var nodeID: String = "timekit.node_id"
    public var clockType: String = "timekit.clock.type"
  }
  
  /// Static attribute values used in spans created by Stripe.
  public struct AttributeValue: Sendable {
    public var timeSystem: String = "hlc"
    public var clockSystem: String = "tsc"
    public var clockSystemFallback: String = "clock_monotonic"
  }
}
#endif



// MARK: - Hybrid Logical Clock

/// Hybrid Logical Clock combining physical time with logical counters for distributed ordering
///
/// HLC provides:
/// - **Causality:** Preserves happened-before relationships across network
/// - **Wall-clock semantics:** Timestamps close to actual wall time
/// - **Monotonicity:** Timestamps never go backwards
///
/// **Usage:**
/// ```swift
/// // Initialize with unique node ID
/// let time = TimeKit(nodeID: serverID)
///
/// // Generate local event timestamp
/// let ts1 = await time.now()
///
/// // Receive remote timestamp and merge
/// let ts2 = try await time.merge(with: remoteTimestamp)
/// // Guarantees: ts2 > remoteTimestamp (causality preserved)
/// ```
public actor TimeKit: Sendable {
  
  // MARK: - Configuration
  
  /// Unique identifier for this node/server
  private let nodeID: UUID
  
  /// Maximum allowed clock drift (default: 5 seconds)
  private let maxDriftNanoseconds: UInt64
  
  // MARK: - State
  
  /// Last physical time observed
  private var lastPhysical: UInt64 = 0
  
  /// Logical counter for events at same physical time
  private var lastLogical: UInt16 = 0
  
  // MARK: - Initialization
  
  /// Creates a new Hybrid Logical Clock
  ///
  /// - Parameters:
  ///   - nodeID: Unique identifier for this server/node (typically UUID)
  ///   - maxDrift: Maximum allowed clock drift in nanoseconds (default: 5s)
  public init(nodeID: UUID, maxDrift: UInt64 = 5_000_000_000) {
    self.nodeID = nodeID
    self.maxDriftNanoseconds = maxDrift
  }
  
  // MARK: - Public API
  
  /// Generate a new timestamp for a local event
  ///
  /// This should be called when creating events on this node.
  ///
  /// - Returns: HLC timestamp with physical time + logical counter
  public func timeIntervalSince1970() -> TimeKitTimestamp {
    let currentPhysical = TimeKitClock.read()
    
    if currentPhysical > lastPhysical {
      // Physical time advanced - reset logical counter
      lastPhysical = currentPhysical
      lastLogical = 0
    } else {
      // Same physical time - increment logical counter
      lastLogical += 1
    }
    
    return TimeKitTimestamp(
      physical: lastPhysical,
      logical: lastLogical,
      nodeID: nodeID
    )
  }
  
  /// Merge with a remote timestamp (call when receiving messages from other nodes)
  ///
  /// This updates the local HLC based on the remote timestamp and returns
  /// a new timestamp that preserves causality.
  ///
  /// **Guarantees:**
  /// - Returned timestamp > remote timestamp (happened-after)
  /// - Local clock advances if remote is ahead
  /// - Causality preserved across network boundaries
  ///
  /// - Parameter remote: Timestamp received from another node
  /// - Returns: New timestamp that happened-after the remote event
  /// - Throws: HLCError.excessiveClockDrift if drift exceeds maximum
  public func merge(with remote: TimeKitTimestamp) throws -> TimeKitTimestamp {
    let currentPhysical = TimeKitClock.read()
    
    // Detect excessive clock drift (possible attack or misconfiguration)
    if remote.physical > currentPhysical {
      let drift = remote.physical - currentPhysical
      if drift > maxDriftNanoseconds {
        throw TimeKitError.excessiveClockDrift(
          drift: drift, maximum: maxDriftNanoseconds, remoteNode: remote.nodeID
        )
      }
    }
    
    // HLC merge algorithm: take max of local, remote, and current physical time
    let maxPhysical = max(currentPhysical, remote.physical, lastPhysical)
    
    // Calculate logical counter
    let newLogical: UInt16
    if remote.physical == lastPhysical && remote.physical == currentPhysical {
      // All at same physical time - increment past both counters
      newLogical = max(lastLogical, remote.logical) + 1
    }
    
    else if maxPhysical == remote.physical {
      // Remote physical time is newest - use its logical + 1
      newLogical = remote.logical + 1
    }
    
    else {
      // Our physical time moved forward - reset logical
      newLogical = 0
    }
    
    // Update state
    lastPhysical = maxPhysical
    lastLogical = newLogical
    
    return TimeKitTimestamp(
      physical: maxPhysical,
      logical: newLogical,
      nodeID: nodeID
    )
  }
  
  /// Update internal state without returning a timestamp
  ///
  /// Useful for processing received timestamps without generating a new event.
  ///
  /// - Parameter remote: Timestamp to update from
  /// - Throws: HLCError.excessiveClockDrift if drift exceeds maximum
  public func update(with remote: TimeKitTimestamp) throws {
    _ = try merge(with: remote)
  }
}

// MARK: - HLC Timestamp

/// A Hybrid Logical Clock timestamp
///
/// Combines physical time (nanoseconds), logical counter, and node ID
/// to provide both wall-clock semantics and causal ordering.
///
/// **Ordering:**
/// 1. Compare physical time first
/// 2. Then logical counter
/// 3. Finally node ID (for total ordering)
public struct TimeKitTimestamp: Sendable, Codable, Hashable {
  
  /// Physical time component (nanoseconds since Unix epoch)
  public let physical: UInt64
  
  /// Logical counter (for events at same physical time)
  public let logical: UInt16
  
  /// Node that generated this timestamp
  public let nodeID: UUID
  
  public init(physical: UInt64, logical: UInt16, nodeID: UUID) {
    self.physical = physical
    self.logical = logical
    self.nodeID = nodeID
  }
}


// MARK: - Comparable

extension TimeKitTimestamp: Comparable {
  public static func < (lhs: TimeKitTimestamp, rhs: TimeKitTimestamp) -> Bool {
    // Compare physical time first
    if lhs.physical != rhs.physical {
      return lhs.physical < rhs.physical
    }
    
    // Then logical counter
    if lhs.logical != rhs.logical {
      return lhs.logical < rhs.logical
    }
    
    // Finally node ID as tie-breaker (for total ordering)
    return lhs.nodeID.uuidString < rhs.nodeID.uuidString
  }
}

// MARK: - CustomStringConvertible

extension TimeKitTimestamp: CustomStringConvertible {
  public var description: String {
    let date = Date(timeIntervalSince1970: TimeInterval(physical) / 1_000_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    
    return "\(formatter.string(from: date)) (logical: \(logical), node: \(nodeID.uuidString.prefix(8))...)"
  }
}



// MARK: - TaskLocal Support


/// Make TimeKitContainer work with ServiceContext
extension TimeKitContainer: ServiceContextKey {
  public typealias Value = TimeKitContainer
  
  public static var defaultValue: TimeKitContainer? { nil }
}


///
extension TimeKitContainer {
  
  ///
  public static var current: TimeKitContainer? {
    ServiceContext.current?[TimeKitContainer.self]
  }
  
  /// Execute operation with HLC available in task-local context
  ///
  /// - Parameters:
  ///   - time: The HLC instance to use
  ///   - operation: The async operation to execute
  /// - Returns: Result of the operation
  public static func withClock<R>(
    _ container: TimeKitContainer,
    operation: () async throws -> R
  ) async rethrows -> R {
    var context = ServiceContext.current ?? ServiceContext.topLevel
    context[TimeKitContainer.self] = container
    return try await ServiceContext.$current.withValue(context, operation: operation)
  }
  
  /// Execute operation with a new HLC instance
  ///
  /// - Parameters:
  ///   - nodeID: Unique identifier for this node
  ///   - operation: The async operation to execute
  /// - Returns: Result of the operation
  public static func withClock<R>(
    nodeID: UUID,
    configuration: TimeKitConfiguration = .init(),
    operation: () async throws -> R
  ) async rethrows -> R {
    let container = TimeKitContainer(nodeID: nodeID, configuration: configuration)
    var context = ServiceContext.current ?? ServiceContext.topLevel
    context[TimeKitContainer.self] = container
    return try await ServiceContext.$current.withValue(context, operation: operation)
  }
}

///
public struct TimeKitErrorSource: ErrorKitSource {
  public enum Base: String, Codable, Sendable {
    case drift
  }
  
  public let base: Base
  
  public init(_ base: Base) {
    self.base = base
  }
  
  public static let drift = Self(.drift)
  
  public var description: String {
    base.rawValue
  }
}

///
public struct TimeKitError: ErrorKitError {
  public static let name = "TimeKitError"
  public typealias Source = TimeKitErrorSource
}

extension TimeKitError {
  public static func excessiveClockDrift(drift: UInt64, maximum: UInt64, remoteNode: UUID) -> ErrorKitWrapper<Self> {
    let timestamp = Int64(TimeKitClock.read())
    let driftMS = Double(drift) / 1_000_000
    let maxMS = Double(maximum) / 1_000_000
    let reason = "drift=\(String(format: "%.2f", driftMS))ms max=\(String(format: "%.2f", maxMS))ms node=\(remoteNode.uuidString.prefix(8))"
    return .init(backing: .init(type: "clock_drift_violation", source: .drift, timestamp: timestamp, reason: reason))
  }
}


///
public enum HLCError: Error, CustomStringConvertible {
  case excessiveClockDrift(drift: UInt64, maximum: UInt64, remoteNode: UUID)
  
  public var description: String {
    switch self {
    case .excessiveClockDrift(let drift, let maximum, let remoteNode):
      let driftMS = Double(drift) / 1_000_000
      let maxMS = Double(maximum) / 1_000_000
      return "Clock drift of \(String(format: "%.1f", driftMS))ms exceeds maximum \(String(format: "%.1f", maxMS))ms (remote node: \(remoteNode))"
    }
  }
}
