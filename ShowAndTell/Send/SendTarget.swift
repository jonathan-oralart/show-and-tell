import SwiftUI

/// The app Copy & Open switches to, chosen in Settings.
enum SendTarget: String, CaseIterable, Identifiable {
    case claude
    case codex

    static let defaultsKey = "sendTarget"

    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var bundleID: String {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .codex: "com.openai.codex"
        }
    }

    /// The Copy & Open button's fill: Claude's terracotta, or the system accent for Codex.
    var tint: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: .accentColor
        }
    }

    /// The Copy & Open button's icon.
    @ViewBuilder var icon: some View {
        switch self {
        case .claude: ClaudeSpark().frame(width: 15, height: 15)
        case .codex: Image(systemName: "arrow.up.forward.app")
        }
    }

    static var current: SendTarget {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SendTarget.init) ?? .claude
    }
}

/// Claude's spark: rounded rays of slightly different lengths around the centre.
nonisolated struct ClaudeSpark: Shape {
    private static let lengths: [CGFloat] = [1, 0.84, 0.96, 0.8, 0.98, 0.88, 0.82, 1, 0.86, 0.94, 0.8, 0.92]

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let lineWidth = radius * 0.2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var rays = Path()
        for (i, length) in Self.lengths.enumerated() {
            let angle = (Double(i) / Double(Self.lengths.count) + 0.02) * 2 * .pi
            let reach = (radius - lineWidth / 2) * length
            rays.move(to: center)
            rays.addLine(to: CGPoint(x: center.x + reach * cos(angle), y: center.y + reach * sin(angle)))
        }
        return rays.strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
