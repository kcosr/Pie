import SwiftUI

/// The viewport in transcript coordinates, measured alongside the content size.
struct TranscriptGeometry: Equatable {
    var viewport: CGRect
    var contentHeight: CGFloat

    var topGap: CGFloat { max(0, viewport.minY) }
    private var bottomGap: CGFloat { contentHeight - viewport.maxY }
    // Layout can settle fractionally short of the anchor. Navigation uses
    // the exact end so even a one-point scroll away releases the pin.
    var isAtBottom: Bool { bottomGap <= 2 }
    var isAtScrollEnd: Bool { bottomGap <= 0 }

    func hasSameSize(as other: Self) -> Bool {
        contentHeight == other.contentHeight && viewport.size == other.viewport.size
    }

    func movedUpWithoutResizing(from previous: Self) -> Bool {
        hasSameSize(as: previous) && topGap < previous.topGap
    }
}

struct TranscriptGeometryKey: PreferenceKey {
    static let defaultValue: TranscriptGeometry? = nil

    static func reduce(value: inout TranscriptGeometry?, nextValue: () -> TranscriptGeometry?) {
        if let next = nextValue() { value = next }
    }
}
