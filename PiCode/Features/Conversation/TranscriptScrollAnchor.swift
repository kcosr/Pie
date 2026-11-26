//
//  TranscriptScrollAnchor.swift
//  PiCode
//
//  Keeps the text under the reader still while earlier history is prepended.
//
//  History is loaded a page at a time above the viewport (`prefetchEarlierTranscript`
//  and `startIdleHistoryFill`). Every page makes the document taller *above* what
//  the user is reading, and an `NSScrollView` keeps its origin measured from the
//  top — so without help the rows under the reader slide down by the height of the
//  page, and the user loses their place. SwiftUI's `scrollPosition(id:)` did not
//  hold it either: it needs the rows to be scroll targets it can track, and the
//  transcript's custom stack layout is not one.
//
//  So while a prepend is settling, the anchor holds the distance from the
//  viewport's top to the document's *bottom*. Content added above changes the
//  document's height and nothing below the viewport, so restoring that distance
//  puts every visible row back exactly where it was. The hold is a short window
//  per prepend, not a standing rule: outside it the bottom of the document is
//  where a streaming answer grows, and anchoring to it would push the text the
//  user is reading upward instead.
//

import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class TranscriptScrollAnchor {
    private weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    var onUserScroll: ((Bool) -> Void)?
    private var clipTop: CGFloat = 0
    private var clipMovedUp = false
    private var pendingFollow: DispatchWorkItem?
    private var geometryBeforeFollow: TranscriptGeometry?
    var isFollowScheduled: Bool { pendingFollow != nil }
    /// Document height minus the clip's top, while a hold is active.
    private var distanceFromBottom: CGFloat?
    private var holdUntil: CFTimeInterval = 0
    /// Set while the anchor moves the clip itself, so its own scroll is not
    /// mistaken for the user's.
    private var isCorrecting = false

    /// How long after a prepend the anchor keeps holding. Long enough for the
    /// page's rows to lay out and their Markdown to finish sizing.
    private static let holdDuration: CFTimeInterval = 0.8

    var currentGeometry: TranscriptGeometry? {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return nil }
        return TranscriptGeometry(viewport: scrollView.documentVisibleRect, contentHeight: document.bounds.height)
    }

    func scheduleFollow(_ action: @escaping (_ movedUp: Bool) -> Void) {
        guard pendingFollow == nil else { return }
        geometryBeforeFollow = currentGeometry
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let movedUp: Bool
            if let before = self.geometryBeforeFollow, let now = self.currentGeometry {
                movedUp = !now.isAtScrollEnd && now.movedUpWithoutResizing(from: before)
            } else {
                movedUp = false
            }
            self.pendingFollow = nil
            self.geometryBeforeFollow = nil
            action(movedUp)
        }
        pendingFollow = work
        DispatchQueue.main.async(execute: work)
    }

    fileprivate func didLayout() {
        guard let work = pendingFollow, let before = geometryBeforeFollow,
              let now = currentGeometry, !now.hasSameSize(as: before) else { return }
        // Finish following the resize here. A later Page Up may start an animation
        // before its first offset arrives, so no queued jump should outlive this layout.
        work.perform()
        work.cancel()
    }

    func cancelPendingFollow() {
        pendingFollow?.cancel()
        pendingFollow = nil
        geometryBeforeFollow = nil
    }

    func scrollToEnd(preservingScrollAnimation: Bool = false) -> Bool {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return false }
        let clip = scrollView.contentView
        var target = clip.bounds
        target.origin.y = document.bounds.maxY - target.height
        let origin = clip.constrainBoundsRect(target).origin
        if preservingScrollAnimation {
            guard origin != clip.bounds.origin else { return true }
            // Adjust for content growth without cancelling a Page Up animation
            // whose first frame may still be pending.
            clip.setBoundsOrigin(origin)
        } else {
            clip.scroll(to: origin)
        }
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    func attach(_ scrollView: NSScrollView?) {
        guard let scrollView, scrollView !== self.scrollView else { return }
        detach()
        self.scrollView = scrollView
        clipTop = scrollView.contentView.bounds.minY
        clipMovedUp = false
        let center = NotificationCenter.default
        // Inserting the sent prompt, clearing the composer, and rendering a
        // reply all move the clip. Only a user's scroll should pause following.
        observers.append(center.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                            object: scrollView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScroll() }
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                            object: scrollView.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipDidScroll() }
        })
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                object: document, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.documentDidResize() }
            })
        }
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollView = nil
        cancelPendingFollow()
        distanceFromBottom = nil
    }

    /// Call right before prepending earlier rows.
    func holdReadingPosition() {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return }
        if distanceFromBottom == nil || CACurrentMediaTime() > holdUntil {
            distanceFromBottom = document.frame.height - scrollView.contentView.bounds.origin.y
        }
        holdUntil = CACurrentMediaTime() + Self.holdDuration
    }

    /// Scrolls by a height change that happened above the viewport, so the
    /// visible rows stay where they are. A prepend's hold already restores the
    /// position from the document's height, so this stands aside during one.
    func compensate(heightChangeAbove delta: CGFloat) {
        guard !isHolding, let scrollView, let document = scrollView.documentView,
              document.isFlipped else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(0, clip.bounds.origin.y + delta), maxY)
        guard abs(target - clip.bounds.origin.y) > 0.5 else { return }
        isCorrecting = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isCorrecting = false
    }

    private var isHolding: Bool {
        distanceFromBottom != nil && CACurrentMediaTime() <= holdUntil
    }

    private func recordClipOrigin(_ y: CGFloat) {
        // Bounds and live-scroll notifications can report the same movement.
        guard y != clipTop else { return }
        clipMovedUp = !isCorrecting && y < clipTop
        clipTop = y
    }

    private func liveScroll() {
        guard let scrollView, let geometry = currentGeometry else { return }
        recordClipOrigin(scrollView.contentView.bounds.minY)
        if geometry.isAtScrollEnd { onUserScroll?(true) }
        else if clipMovedUp { onUserScroll?(false) }
        clipMovedUp = false
    }

    private func clipDidScroll() {
        guard let scrollView else { return }
        recordClipOrigin(scrollView.contentView.bounds.minY)
        guard !isCorrecting, isHolding, let document = scrollView.documentView else { return }
        distanceFromBottom = document.frame.height - scrollView.contentView.bounds.origin.y
    }

    private func documentDidResize() {
        guard isHolding, let distanceFromBottom,
              let scrollView, let document = scrollView.documentView else {
            self.distanceFromBottom = nil
            return
        }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(0, document.frame.height - distanceFromBottom), maxY)
        guard abs(target - clip.bounds.origin.y) > 0.5 else { return }
        isCorrecting = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isCorrecting = false
    }
}

/// Hands the transcript's backing `NSScrollView` to the anchor once it exists.
struct TranscriptScrollViewFinder: NSViewRepresentable {
    var anchor: TranscriptScrollAnchor

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.anchor = anchor
        return view
    }

    func updateNSView(_ nsView: FinderView, context: Context) {
        nsView.anchor = anchor
    }

    final class FinderView: NSView {
        weak var anchor: TranscriptScrollAnchor?

        override func layout() {
            super.layout()
            anchor?.didLayout()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // The scroll view finishes assembling after this view joins it.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                anchor?.attach(enclosingScrollView)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
