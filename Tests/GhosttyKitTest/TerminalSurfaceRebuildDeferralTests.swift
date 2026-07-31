@testable import GhosttyTerminal
import Testing

/// A pane that is merely hidden reports a zero size, and rebuilding against
/// that would destroy the surface. Deferring the rebuild is only safe if the
/// debt is later redeemed: configuration options are consumed by
/// `createSurface` alone, and no caller re-runs a rebuild once the view
/// regains a size — every other path takes the `surface != nil` branch and
/// merely syncs metrics. Dropping the request outright would leave a hidden
/// pane on its old configuration indefinitely.
@MainActor
struct TerminalSurfaceRebuildDeferralTests {
    @Test
    func `a deferred rebuild is redeemed once the view has a size again`() {
        let coordinator = TerminalSurfaceCoordinator()
        coordinator.viewSize = { (100, 50) }
        coordinator.isAttached = { true }
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
}
