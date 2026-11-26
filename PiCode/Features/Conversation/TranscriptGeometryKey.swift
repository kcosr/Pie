import SwiftUI

/// The viewport in transcript coordinates, measured alongside the content size.
struct TranscriptGeometry: Equatable {
    var viewport: CGRect
    var contentHeight: CGFloat

    var topGap: CGFloat { max(0, viewport.minY) }
    var isAtBottom: Bool { contentHeight - viewport.maxY <= 2 }

    func hasSameHeight(as other: Self) -> Bool {
        contentHeight == other.contentHeight && viewport.height == other.viewport.height
    }
}

struct TranscriptGeometryKey: PreferenceKey {
    static let defaultValue: TranscriptGeometry? = nil

    static func reduce(value: inout TranscriptGeometry?, nextValue: () -> TranscriptGeometry?) {
        if let next = nextValue() { value = next }
    }
}
