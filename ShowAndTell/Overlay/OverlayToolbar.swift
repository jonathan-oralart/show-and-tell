import KeyboardShortcuts
import SwiftUI

/// A capture's place in Recent, newest first. `index` is nil for a capture that hasn't been saved yet.
struct HistoryPosition {
    let index: Int?
    let count: Int
    /// An unsaved new capture is waiting before the newest saved one.
    let hasDraft: Bool

    var hasOlder: Bool { (index ?? -1) + 1 < count }
    var hasNewer: Bool { index.map { $0 > 0 || hasDraft } ?? false }

    /// Every capture you can step to, oldest first, counting the unsaved one.
    var slots: Int { count + (index == nil || hasDraft ? 1 : 0) }
    /// This capture's slot, oldest first.
    var slot: Int { slots - 1 - (index.map { $0 + (hasDraft ? 1 : 0) } ?? 0) }
}

/// History arrows, marker colour and size, Copy and Copy & Open, under the screenshot. Closing is done by clicking the background.
struct OverlayToolbar: View {
    @Binding var style: MarkerStyle
    @AppStorage(SendTarget.defaultsKey) private var sendTarget = SendTarget.claude
    let history: HistoryPosition
    let onNavigate: (Int) -> Void
    let onCopy: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if history.count > 0 {
                HistoryControls(position: history, onNavigate: onNavigate)
                Divider().frame(height: 22)
            }
            StyleControls(style: $style)
            Divider().frame(height: 22)
            // The shortcuts for these live on the overlay, which stays put while the toolbar redraws.
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(CapsuleButtonStyle())
            .tooltip("Copy the annotated image", shortcut: KeyboardShortcuts.Name.copy.symbols)
            Button(action: onSend) {
                Label { Text("Copy & Open \(sendTarget.title)") } icon: { sendTarget.icon }
            }
            .buttonStyle(CapsuleButtonStyle(isProminent: true, tint: sendTarget.tint))
            .tooltip("Copy the annotated image and switch to \(sendTarget.title) to paste it (⌘V)", shortcut: KeyboardShortcuts.Name.send.symbols)
            #if DEBUG
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { DemoTake.sendButton = $0 }
            #endif
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Older and newer arrows around page dots for Recent, newest on the right.
private struct HistoryControls: View {
    let position: HistoryPosition
    let onNavigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", step: 1, enabled: position.hasOlder, help: "Older capture", shortcut: ",")
            PageDots(count: position.slots, current: position.slot)
                .tooltip(position.index.map { "Capture \($0 + 1) of \(position.count)" } ?? "New capture")
            arrow("chevron.right", step: -1, enabled: position.hasNewer, help: "Newer capture", shortcut: ".")
        }
    }

    private func arrow(_ symbol: String, step: Int, enabled: Bool, help: String, shortcut: String) -> some View {
        Button { onNavigate(step) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
                .hoverHighlight(in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .tooltip(help, shortcut: shortcut)
    }
}

/// A row of dots with the current one drawn longer. Long histories show a window of dots around the
/// current one, with the end dots shrunk where more continue past them.
private struct PageDots: View {
    let count: Int
    let current: Int

    private static let maxVisible = 7
    private static let dot: CGFloat = 5
    private static let currentWidth: CGFloat = 14
    private static let spacing: CGFloat = 4

    var body: some View {
        let visible = min(count, Self.maxVisible)
        let start = min(max(current - visible / 2, 0), count - visible)
        HStack(spacing: Self.spacing) {
            ForEach(start..<start + visible, id: \.self) { slot in
                let isEdge = (slot == start && start > 0) || (slot == start + visible - 1 && start + visible < count)
                Capsule()
                    .fill(slot == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.5)))
                    .frame(width: slot == current ? Self.currentWidth : Self.dot, height: Self.dot)
                    .scaleEffect(isEdge ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        // Hovering between the dots still counts.
        .contentShape(Rectangle())
    }
}

/// A dot showing the current marker colour and size; clicking it opens the swatches and size dots beside it.
private struct StyleControls: View {
    @Binding var style: MarkerStyle
    @AppStorage(SendTarget.defaultsKey) private var sendTarget = SendTarget.claude
    @State private var isExpanded = false

    var body: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: style.color))
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: 14 * style.size.factor, height: 14 * style.size.factor)
                        .frame(width: 18, height: 18)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Capsule())
                .hoverHighlight(in: Capsule())
            }
            .buttonStyle(.plain)
            .tooltip("Marker colour and size")

            if isExpanded {
                options
                    // Grows out of the dot while the toolbar widens, instead of sliding in from behind it.
                    .transition(.blurReplace.combined(with: .scale(0.6, anchor: .leading)))
            }
        }
        .padding(.leading, 2)
    }

    private var options: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(MarkerStyle.Tint.allCases, id: \.self) { tint in
                    Button { style.tint = tint } label: {
                        Circle().fill(Color(nsColor: tint.color))
                            .frame(width: 18, height: 18)
                            .padding(3)
                            .overlay(Circle().strokeBorder(.foreground.opacity(style.tint == tint ? 0.7 : 0), lineWidth: 2))
                            .contentShape(Circle())
                            .hoverHighlight(in: Circle())
                    }
                    .buttonStyle(.plain)
                    .tooltip(tint.name)
                }
            }
            HStack(spacing: 0) {
                ForEach(MarkerStyle.Size.allCases, id: \.self) { size in
                    Button { style.size = size } label: {
                        Circle()
                            .fill(style.size == size ? Color(nsColor: style.color) : Color.secondary.opacity(0.45))
                            .frame(width: 14 * size.factor, height: 14 * size.factor)
                            .frame(width: 22, height: 26)
                            .contentShape(Rectangle())
                            .hoverHighlight(in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .tooltip("Marker size", shortcut: "− +")
        }
    }
}

/// A capsule button that lightens on hover and darkens when pressed. The prominent one is filled with `tint`.
struct CapsuleButtonStyle: ButtonStyle {
    var isProminent = false
    var tint = Color.accentColor

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, isProminent: isProminent, tint: tint)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(isProminent ? .semibold : .regular))
                .foregroundStyle(isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(fill))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { isHovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fill: AnyShapeStyle {
            if isProminent {
                let lift = configuration.isPressed ? -0.08 : (isHovering ? 0.1 : 0)
                return AnyShapeStyle(tint.mix(with: lift >= 0 ? .white : .black, by: abs(lift)))
            }
            return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.13 : 0.07)))
        }
    }
}

extension View {
    /// A faint backdrop in `shape` while the pointer is over the view.
    func hoverHighlight(in shape: some Shape) -> some View {
        modifier(HoverHighlight(shape: AnyShape(shape)))
    }
}

private struct HoverHighlight: ViewModifier {
    let shape: AnyShape
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
