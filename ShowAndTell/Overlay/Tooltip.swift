import SwiftUI

extension View {
    /// A tooltip above this view after a short hover, with its shortcut dimmed after the text.
    /// `.help` doesn't work here: AppKit's tooltips never appear over the overlay panel.
    func tooltip(_ text: String, shortcut: String? = nil) -> some View {
        modifier(TooltipModifier(tip: Tip(text: text, shortcut: shortcut)))
    }

    /// Draws the hovered view's tooltip on top of everything. Applied once, to the whole overlay.
    func tooltipLayer() -> some View {
        overlayPreferenceValue(TooltipKey.self) { shown in
            GeometryReader { proxy in
                if let shown = shown.last {
                    let rect = proxy[shown.anchor]
                    TooltipBubble(tip: shown.tip)
                        // A zero-height frame with the bubble's bottom on it, centred over the view.
                        .frame(width: rect.width, height: 0, alignment: .bottom)
                        .position(x: rect.midX, y: rect.minY - 8)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct Tip: Equatable {
    let text: String
    let shortcut: String?
}

private struct ShownTip {
    let tip: Tip
    let anchor: Anchor<CGRect>
}

private struct TooltipKey: PreferenceKey {
    static var defaultValue: [ShownTip] { [] }
    static func reduce(value: inout [ShownTip], nextValue: () -> [ShownTip]) { value += nextValue() }
}

/// When a tooltip last went away. Like macOS, moving straight on to another control shows its tooltip without waiting.
@MainActor private var lastHidden = Date.distantPast

private struct TooltipModifier: ViewModifier {
    let tip: Tip
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    private static let delay: Duration = .seconds(0.6)

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: TooltipKey.self, value: .bounds) { isShown ? [ShownTip(tip: tip, anchor: $0)] : [] }
            .onHover { inside in
                pending?.cancel()
                if inside {
                    let isWarm = Date.now.timeIntervalSince(lastHidden) < 0.5
                    pending = Task {
                        if !isWarm { try? await Task.sleep(for: Self.delay) }
                        guard !Task.isCancelled else { return }
                        isShown = true
                    }
                } else if isShown {
                    isShown = false
                    lastHidden = .now
                }
            }
            .onDisappear { pending?.cancel() }
            .accessibilityHint(tip.text)
    }
}

private struct TooltipBubble: View {
    let tip: Tip

    var body: some View {
        HStack(spacing: 6) {
            Text(tip.text)
            if let shortcut = tip.shortcut {
                Text(shortcut).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // Not glass: glass fades in when it appears, so the tooltip would shift colour after showing.
        .background(.regularMaterial, in: .capsule)
    }
}
