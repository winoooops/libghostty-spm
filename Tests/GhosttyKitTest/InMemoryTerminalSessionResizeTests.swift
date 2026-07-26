import Foundation
@testable import GhosttyTerminal
import Testing

/// Collects dispatches from the session's `@Sendable` resize closure.
private final class ResizeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InMemoryTerminalViewport] = []

    var dispatches: [InMemoryTerminalViewport] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ viewport: InMemoryTerminalViewport) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(viewport)
    }
}

@MainActor
struct InMemoryTerminalSessionResizeTests {
    private func metrics(
        columns: UInt16,
        rows: UInt16,
        widthPixels: UInt32,
        heightPixels: UInt32
    ) -> TerminalGridMetrics {
        TerminalGridMetrics(
            columns: columns,
            rows: rows,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            cellWidthPixels: 17,
            cellHeightPixels: 37
        )
    }

    /// A terminal app redraws for its grid size, so a size whose columns and
    /// rows are unchanged asks it to repaint for a result it cannot render
    /// differently. During a drag that is nearly every frame, and each repaint
    /// re-wraps the app's content — the dispatch MUST be suppressed.
    @Test
    func `sub-cell size change does not dispatch a host resize`() {
        let recorder = ResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { recorder.record($0) }
        )

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(recorder.dispatches.count == 1)

        // Same grid, a few pixels wider: nothing the app can draw differently.
        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1712, heightPixels: 1480))
        #expect(recorder.dispatches.count == 1)
    }

    /// The counterpart: once the grid itself changes the app has to be told,
    /// and the dispatch MUST carry the current pixel metrics rather than the
    /// ones from the last dispatched size.
    @Test
    func `grid change dispatches and carries the latest pixel metrics`() {
        let recorder = ResizeRecorder()
        let session = InMemoryTerminalSession(
            write: { _ in },
            resize: { recorder.record($0) }
        )

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1712, heightPixels: 1480))
        session.updateViewport(metrics(columns: 101, rows: 40, widthPixels: 1717, heightPixels: 1480))

        #expect(recorder.dispatches.count == 2)
        #expect(recorder.dispatches.last?.columns == 101)
        #expect(recorder.dispatches.last?.widthPixels == 1717)
    }

    /// After a dispatch the grid has reflowed but still holds content laid out
    /// for the previous size, so the surface MUST keep presenting its last good
    /// frame until the app's redraw lands.
    @Test
    func `dispatching a resize arms the frame hold`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        #expect(session.shouldHoldFrame == false)

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)
    }

    /// A resize arriving while a hold is active means the redraw in flight is
    /// already for a stale size, so the wait starts over. Releasing instead
    /// (the old latch) exposed the reflowed-but-not-repainted grid for every
    /// drag step after the first — the composer visibly folding and springing
    /// back. Ghostty's IOSurface layer anchors content top-left, so the
    /// extended hold clips instead of stretching.
    @Test
    func `a further grid change extends the frame hold`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)

        session.updateViewport(metrics(columns: 101, rows: 40, widthPixels: 1717, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)
    }

    /// The release happens in `receive` — the app's bytes are in the grid, so
    /// the next draw presents the app's frame, not the stale reflow.
    @Test
    func `received output releases the frame hold`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)

        // No surface attached: bytes are dropped before reaching the grid,
        // so the hold must survive.
        session.receive("redraw")
        #expect(session.shouldHoldFrame == true)
    }

    /// An animating agent (pulsing banner, spinner) has chunks in flight at
    /// the moment of every dispatch, laid out for the PREVIOUS width.
    /// Presenting them is exactly the artifact the hold exists to cover, so
    /// output inside the window must not release it — while the answering
    /// repaint, which cannot arrive sooner than a signal delivery plus a
    /// render pass, must.
    @Test
    func `only output past the in-flight window releases the hold`() {
        let dispatched = Date()

        #expect(InMemoryTerminalSession.isWithinInFlightWindow(
            dispatchedAt: dispatched,
            now: dispatched.addingTimeInterval(0.002)
        ))
        #expect(!InMemoryTerminalSession.isWithinInFlightWindow(
            dispatchedAt: dispatched,
            now: dispatched.addingTimeInterval(0.008)
        ))
        #expect(!InMemoryTerminalSession.isWithinInFlightWindow(
            dispatchedAt: nil,
            now: dispatched
        ))
    }

    /// The hold exists to bridge one redraw round-trip, not to gate the surface
    /// on it: a size whose grid is unchanged is never dispatched, so it must not
    /// touch the hold either.
    @Test
    func `sub-cell size change leaves the frame hold untouched`() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1700, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)

        session.updateViewport(metrics(columns: 100, rows: 40, widthPixels: 1712, heightPixels: 1480))
        #expect(session.shouldHoldFrame == true)
    }
}
