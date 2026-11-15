import AppKit
import SwiftUI

/// A blur whose radius eases from `maximumRadius` at the top edge to none at the bottom.
///
/// AppKit has no public variable blur, so this draws Core Animation's private backdrop layer with its
/// `variableBlur` filter, both found by name at runtime: nothing private is linked, and when a later
/// macOS drops either class, `isAvailable` turns false and callers fall back to a material.
final class VariableBlurNSView: NSView {
    static var isAvailable: Bool {
        NSClassFromString("CABackdropLayer") != nil && NSClassFromString("CAFilter") != nil
    }

    var maximumRadius: CGFloat = 12 {
        didSet { if maximumRadius != oldValue { rebuild() } }
    }

    private let backdrop: CALayer = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() ?? CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The default capture scale of 0.125 makes small radii blocky and about eight times too strong.
        backdrop.setValue(0.75, forKey: "scale")
        layer?.addSublayer(backdrop)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        rebuild()
    }

    /// An installed filter ignores later changes, so every change installs a new one.
    private func rebuild() {
        guard bounds.width >= 1, bounds.height >= 1,
            let filter = (NSClassFromString("CAFilter") as AnyObject)
                .perform(NSSelectorFromString("filterWithType:"), with: "variableBlur")?
                .takeUnretainedValue() as? NSObject,
            let mask = Self.mask(height: Int(bounds.height.rounded()))
        else { return }
        filter.setValue(mask, forKey: "inputMaskImage")
        filter.setValue(maximumRadius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.filters = [filter]
    }

    /// A one-pixel-wide strip whose alpha is the blur strength: full at the top row, easing out to none.
    private static func mask(height: Int) -> CGImage? {
        let height = max(height, 1)
        guard
            let context = CGContext(
                data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 2,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data
        else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let position = height > 1 ? CGFloat(row) / CGFloat(height - 1) : 0
            let strength = (1 + cos(.pi * position)) / 2
            pixels[row * 2] = 0
            pixels[row * 2 + 1] = UInt8((strength * 255).rounded())
        }
        return context.makeImage()
    }
}

struct VariableBlur: NSViewRepresentable {
    var maximumRadius: CGFloat = 12

    func makeNSView(context: Context) -> VariableBlurNSView {
        let view = VariableBlurNSView()
        view.maximumRadius = maximumRadius
        return view
    }

    func updateNSView(_ view: VariableBlurNSView, context: Context) {
        view.maximumRadius = maximumRadius
    }
}
