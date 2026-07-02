import Foundation

// MARK: - Seam (ungated — exists on every OS/toolchain)

/// Turns a `FleetInsightInput` into a portable `FleetInsight`. The single async
/// throwing method mirrors the `CLIExecutor` seam idiom. Conformers: the gated
/// `FoundationModelsInsightGenerator` (real model) and `StubInsightGenerator`
/// (deterministic, no model).
protocol FleetInsightGenerator: Sendable {
    func generate(_ input: FleetInsightInput) async throws -> FleetInsight
    /// Warm the underlying model before the first request. Default no-op.
    func prepare() async
    /// Stream progressively richer partial insights. Default wraps `generate`:
    /// one yield, then finish — the stub and sub-27 paths stream by construction.
    func generateStream(_ input: FleetInsightInput) -> AsyncThrowingStream<FleetInsight, Error>
}

extension FleetInsightGenerator {
    func prepare() async {}

    func generateStream(_ input: FleetInsightInput) -> AsyncThrowingStream<FleetInsight, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(try await generate(input))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Errors the seam surfaces to the card. `unavailable` carries the resolved
/// availability so the UI can render the same messaging as the idle state.
enum FleetInsightError: Error, Equatable {
    case unavailable(ModelAvailability)
    case generationFailed(String)
}

// MARK: - Stub (ungated — no model, deterministic)

/// Backs the seam when AI is disabled/unavailable or on a toolchain without
/// FoundationModels. Deterministic canned output — no model, no I/O — so tests
/// and the macOS-26 UI both exercise the seam without macOS-27 hardware.
struct StubInsightGenerator: FleetInsightGenerator {
    /// When set, explains WHY the stub is in play (rendered by the card). nil =
    /// the neutral "not enabled" placeholder.
    let availability: ModelAvailability?

    init(availability: ModelAvailability? = nil) {
        self.availability = availability
    }

    func generate(_ input: FleetInsightInput) async throws -> FleetInsight {
        let headline = availability?.message ?? "AI insights are not enabled for this profile."
        return FleetInsight(headline: headline, bullets: [])
    }
}

// MARK: - Generator selection (pure — this is the lock_on_device guarantee)

/// Which kind of generator a config resolves to, independent of any model
/// construction. Pure and UNGATED so the `lock_on_device` guarantee is provable
/// on the default toolchain without importing FoundationModels or constructing
/// any PCC/external type.
enum GeneratorKind: Sendable, Equatable {
    /// Use the on-device system model (also the resolved kind whenever
    /// `lock_on_device` is set, regardless of the requested tier).
    case onDevice
    /// Use Private Cloud Compute — only reachable when `tier == pcc` AND
    /// `lock_on_device` is false.
    case privateCloudCompute
    /// Reserved external provider (built in a later phase) — only reachable when
    /// `tier == external` AND `lock_on_device` is false.
    case external

    /// Resolve the generator kind from config. `lock_on_device` wins over `tier`
    /// unconditionally: a locked config can NEVER select `.privateCloudCompute`
    /// or `.external`, so no non-on-device model type is ever constructed.
    static func select(config: AIConfig) -> GeneratorKind {
        if config.isLockedOnDevice { return .onDevice }
        switch config.resolvedTier {
        case .onDevice: return .onDevice
        case .pcc: return .privateCloudCompute
        case .external: return .external
        }
    }
}

// MARK: - Factory (ungated signature; FM branch is gated)

/// Picks the conformer for a config + resolved availability. Returns a
/// `StubInsightGenerator` when AI is disabled, when the model isn't available,
/// on the default toolchain (no FoundationModels), or for the not-yet-built
/// `external` tier. On macOS 27 with an available model it returns the real
/// `FoundationModelsInsightGenerator`, pinned to on-device whenever the config
/// is locked (enforced both here and inside the generator, defense in depth).
@MainActor
func makeInsightGenerator(
    config: AIConfig,
    availability: ModelAvailability
) -> any FleetInsightGenerator {
    guard config.isUsable else { return StubInsightGenerator(availability: .disabledByConfig) }
    guard availability.isReady else { return StubInsightGenerator(availability: availability) }

    // `external` tier is specced but not built; fall back to the stub until P5.
    // (A locked config never resolves to `.external`, so this only fires for an
    // explicit unlocked external selection.)
    if GeneratorKind.select(config: config) == .external {
        return StubInsightGenerator(availability: .requiresMacOS27)
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
    if #available(macOS 27, *) {
        return FoundationModelsInsightGenerator(config: config)
    }
    #endif
    return StubInsightGenerator(availability: .requiresMacOS27)
}
