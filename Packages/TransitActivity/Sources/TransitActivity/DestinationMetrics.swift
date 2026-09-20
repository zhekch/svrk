import CoreGraphics
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum DestinationMetrics {
    static func capHeight(compact: Bool) -> CGFloat {
        #if canImport(UIKit)
        let style: UIFont.TextStyle = compact ? .subheadline : .headline
        return UIFont.preferredFont(forTextStyle: style).capHeight
        #elseif canImport(AppKit)
        let size: CGFloat = compact ? 15 : 17
        return NSFont.systemFont(ofSize: size, weight: .semibold).capHeight
        #else
        return compact ? 11 : 13
        #endif
    }

    static func plateHeight(compact: Bool) -> CGFloat {
        capHeight(compact: compact) + 6
    }
}
