@testable import GhosttyTerminal
import Testing

/// Regressions for the two host-managed resize decisions a review found could
/// damage otherwise-working behaviour: a rebuild dropped while a pane is
/// hidden, and a throttle timer outliving the surface it was armed for.
@MainActor
struct TerminalSurfaceResizeThrottleTests {
    @Test
    func `a deferred rebuild is redeemed once the view has a size again`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }

        // Stand in for the zero-size guard having deferred a rebuild: the
        // configuration options it carried are consumed only by
        // createSurface, so dropping the request would leave a hidden pane on
        // its old configuration indefinitely.
        coordinator.testHooks_pendingRebuild = true

        coordinator.synchronizeMetrics()

        #expect(!coordinator.testHooks_pendingRebuild)
    }

    @Test
    func `a deferred rebuild is not redeemed while the view is still hidden`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (0, 0) }
        coordinator.isAttached = { true }
        coordinator.testHooks_pendingRebuild = true

        coordinator.synchronizeMetrics()

        // Still owed — redeeming it here would rebuild against a zero size.
        #expect(coordinator.testHooks_pendingRebuild)
    }

    @Test
    func `the throttle is inert by default`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }

        #expect(coordinator.resizeThrottleInterval == 0)
        coordinator.synchronizeMetrics()
        coordinator.synchronizeMetrics()

        // Nothing armed: with the feature off the metrics sync runs inline,
        // exactly as it does upstream.
        #expect(!coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `an enabled throttle arms once and records a trailing edge`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }
        coordinator.resizeThrottleInterval = 5 // long enough not to fire here

        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)

        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleTrailing)
    }

    @Test
    func `teardown retires an armed throttle instead of leaving it to fire`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }
        coordinator.resizeThrottleInterval = 5

        coordinator.synchronizeMetrics()
        coordinator.synchronizeMetrics()
        #expect(coordinator.testHooks_throttleArmed)
        #expect(coordinator.testHooks_throttleTrailing)

        let generationBefore = coordinator.testHooks_throttleGeneration
        coordinator.freeSurface()

        // The replacement surface must not inherit the old surface's armed
        // gate — that would suppress its first sizing — and the in-flight
        // timer must no longer match the current generation, so it cannot
        // size or re-arm against the surface that replaced it.
        #expect(!coordinator.testHooks_throttleArmed)
        #expect(!coordinator.testHooks_throttleTrailing)
        #expect(coordinator.testHooks_throttleGeneration != generationBefore)
    }
}
