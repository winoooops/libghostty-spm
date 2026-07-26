//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Wall-clock deadline until which the surface should keep presenting its
    /// last good frame instead of the freshly-reflowed one. See `shouldHoldFrame`.
    private var frameHoldDeadline: Date?

    /// When the last grid change was dispatched to the host — the reference
    /// point for telling in-flight output apart from the answering repaint.
    private var lastDispatchAt: Date?

    /// Whether any output has been fed to the grid since the last dispatch.
    private var receivedSinceDispatch = false

    /// How long the geometry must sit still before the hold may release.
    ///
    /// "First output after the resize" is NOT a repaint signal: an animating
    /// agent (pulsing banner, spinner) emits continuously — measured on a
    /// live session, output follows a dispatch within 0–3ms at median and
    /// keeps arriving laid out for the OLD width for up to ~264ms. Any
    /// chunk-triggered release therefore re-exposes the stale reflow, once
    /// per key-repeat during a held-down resize. The only trustworthy signal
    /// is quiet: no further grid change for this long, plus at least one
    /// chunk landed, means whatever is on the grid is the agent's current
    /// frame. During a held key (repeats every ~33ms) this never elapses, so
    /// the surface stays frozen — clipped top-left, exactly how stock
    /// terminals ride out a drag — and settles one beat after release.
    private static let quietWindow: TimeInterval = 0.05

    /// Upper bound on a frame hold. A host-managed app that never answers the
    /// resize must not be able to freeze the surface indefinitely.
    /// Tunable for experiments: VIMEFLOW_GHOSTTY_HOLD_MS overrides the timeout,
    /// and 0 disables the hold entirely so its cost can be measured directly.
    private static let frameHoldTimeout: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["VIMEFLOW_GHOSTTY_HOLD_MS"],
           let ms = Double(raw) {
            return ms / 1000
        }
        return 0.5
    }()

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }
        self.surface = surface
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func clearSurface(ifMatches expectedSurface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }

        guard surface == expectedSurface else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surface == nil ? "nil" : "set")"
            )
            return
        }

        surface = nil
        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    // MARK: - Resize Frame Hold

    /// True while a dispatched resize is still waiting for the app's redraw.
    ///
    /// When a resize is dispatched, ghostty's grid has *already* reflowed to the
    /// new size but still holds the OLD content: the host must deliver the new
    /// winsize, the app must redraw, and those bytes must travel back over the
    /// PTY. Drawing inside that window presents content laid out for the previous
    /// size — the dislocated-frame flash seen during a live resize. The caller
    /// keeps presenting the last good frame while this is true.
    ///
    /// Cleared by `receive` (the redraw landed) or by the timeout above.
    var shouldHoldFrame: Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let deadline = frameHoldDeadline else { return false }

        let now = Date()
        guard now < deadline else {
            // The hold ran to its timeout; that counts as completed.
            frameHoldDeadline = nil
            return false
        }

        if Self.isReadyToRelease(
            dispatchedAt: lastDispatchAt,
            receivedSinceDispatch: receivedSinceDispatch,
            now: now
        ) {
            frameHoldDeadline = nil
            return false
        }

        return true
    }

    // MARK: - Viewport Read

    /// Returns the active viewport as a UTF-8 string, or `nil` if no surface
    /// is attached. Lines are separated by `\n`. The `ghostty_text_s`
    /// lifecycle (allocate via `ghostty_surface_read_text`, free via
    /// `ghostty_surface_free_text`) is fully encapsulated — callers never
    /// touch the C buffer.
    ///
    /// Selection grammar: `(VIEWPORT, TOP_LEFT)` to `(VIEWPORT, BOTTOM_RIGHT)`
    /// with `rectangle: false` (linear flow). This reads exactly the visible
    /// rows and ignores scrollback. Empty viewports return an empty string.
    ///
    /// Thread-safe: acquires the same `NSLock` as `receive(_:)` and
    /// `setSurface(_:)`, preventing reads against a surface mid-replacement.
    public func readViewportText() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else { return nil }

        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &out) }

        guard let textPtr = out.text, out.text_len > 0 else {
            return ""
        }
        let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            TerminalDebugLog.log(
                .output,
                "terminal <- host dropped \(TerminalDebugLog.describe(data))"
            )
            return
        }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }

        // Receiving bytes no longer releases by itself — see `quietWindow`.
        // It only records that the grid holds post-dispatch content; the
        // release happens in `shouldHoldFrame` once the geometry has been
        // quiet long enough.
        receivedSinceDispatch = true
    }

    /// Whether the hold may release: the geometry sat still for the quiet
    /// window and at least one chunk landed in the meantime. Static and pure
    /// so the boundary is testable without a live ghostty surface.
    static func isReadyToRelease(
        dispatchedAt: Date?,
        receivedSinceDispatch: Bool,
        now: Date
    ) -> Bool {
        guard receivedSinceDispatch, let dispatchedAt else { return false }
        return now.timeIntervalSince(dispatchedAt) >= quietWindow
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        // Only a change in grid size changes what a terminal app has to draw; a
        // sub-cell pixel delta does not. Dispatching those too asks the app for a
        // full repaint on nearly every frame of a drag — measured at 5566 host
        // resizes across one session's drags, ~78% of all metric updates — and
        // each repaint re-wraps its content, which is what makes a fast drag jump
        // vertically. Keep tracking the latest pixel metrics (so the next real
        // dispatch carries them) but only tell the app when its grid changes.
        let gridChanged = lastResize.map {
            $0.columns != mergedResize.columns || $0.rows != mergedResize.rows
        } ?? true
        lastResize = mergedResize
        guard gridChanged else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize sub-cell skipped cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels)"
            )

            return
        }

        // The grid reflows now, but the app's redraw for this size is still a
        // PTY round-trip away — keep presenting the last good frame until it
        // lands. A further grid change during the hold means the redraw in
        // flight is already for a stale size, so the wait starts over:
        // arm-or-extend on EVERY dispatch. Ghostty's IOSurface layer anchors
        // its contents top-left, so a held frame clips on shrink and exposes
        // background on grow rather than stretching — which is why extending
        // no longer letterboxes the way the pre-anchor implementation did.
        // Measured agent response to a winsize: median 15ms, p90 133ms,
        // max 419ms; the timeout must outlast that tail or the stale reflow
        // pops in just before the real frame.
        if Self.frameHoldTimeout > 0 {
            frameHoldDeadline = Date().addingTimeInterval(Self.frameHoldTimeout)
        }
        lastDispatchAt = Date()
        receivedSinceDispatch = false
        lock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}
