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





}
