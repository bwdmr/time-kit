# TimeKit

High-performance Hybrid Logical Clock (HLC) implementation for distributed systems in Swift, with TSC optimization for x86_64 servers.

## What is TimeKit?

TimeKit provides causally-ordered timestamps for distributed systems by combining:
- **Physical time** (wall-clock) - for human-readable timestamps
- **Logical counters** - for ordering events at the same physical time
- **Node IDs** - for total ordering across servers

This solves the fundamental problem in distributed systems: ordering events across machines with unsynchronized clocks.

**Clock sources:**
- **TSC** (x86_64) - ~15ns latency, primary path for Intel/AMD servers
- **CLOCK_MONOTONIC** (fallback) - ~100ns latency, calibrated once at boot to wall-clock time for cross-server comparability

### Low-Level Clock Access

Raw physical time without HLC overhead. First call calibrates (~100ms), results cached globally. Subsequent calls ~15ns on TSC.
```swift
let nanos1 = TimeKitClock.read()  // First: calibrates TSC, caches result
let nanos2 = TimeKitClock.read()  // Subsequent: ~15ns, reads cache
let nanos3 = TimeKitClock.read()  // No recalibration
print(TimeKitClock.isUsingTSC)    // true on x86_64 with invariant TSC
```

### Instance API
```swift
let clock = TimeKit(nodeID: UUID())
let timestamp = await clock.time()  // TimeKitTimestamp (physical, logical, nodeID)
let nanos = await clock.timeIntervalSince1970()  // UInt64: nanoseconds since epoch
let merged = try await clock.merge(with: remoteTimestamp)  // Preserves causality
```

### Context API with Tracing

Propagate TimeKit through ServiceContext. Tracing creates spans at context boundaries only (not per `time()` call).
```swift
let container = TimeKitContainer(nodeID: UUID(), tracer: InstrumentationSystem.tracer)
await TimeKitContainer.withClock(container) {
    let timestamp = await TimeKitContainer.current?.time()
}
```

### Testing
```bash
# Local
swift test
swift test --skip Performance  # Fast tests only

# Docker
docker build -t timekit:latest .
docker run --rm timekit:latest

# Or with make
make docker-test-fast
make docker-test-perf
```

### Contribute

1. Create an issue describing the problem or change.
   - Add a UTC timestamp at the top of the issue (`date -u +%s`)

2. Fork the repository.

3. Create a branch for each PR you intend to make.
   - Format: `docs_readme_contribute`, max 3 words in snake case
   - First word: category, second: section affected, third: what changes

4. Make your first commit on that branch and include the issue number and timestamp as first two elements in the commit body:
   - Indicate the category of the commit as in type
   - Indicate affected source of the change
   - Follow with a title describing what changed, not why
   - Complete example:
```yaml
docs(readme): Fix Typo

- timestamp: 1768991151
- issue: https://github.com/.../issues/1
```

5. Update the `changelog.json` with the script `generate_changelog.sh`.
   - Add as a separate commit

6. Open a pull request.

7. Wait for the pull request to be reviewed.
