import SwiftUI

/** Void# look: deep navy surfaces, royal blue to cyan accents. */
enum Theme {
    static let accent = Color(red: 0.24, green: 0.50, blue: 1.0)
    static let accent2 = Color(red: 0.31, green: 0.82, blue: 1.0)
    static let gold = Color(red: 0.55, green: 0.72, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.48)
    static let ok = Color(red: 0.24, green: 0.86, blue: 0.68)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let base = Color(red: 0.027, green: 0.043, blue: 0.086)
    static let baseLight = Color(red: 0.05, green: 0.085, blue: 0.18)
    static let sidebarFill = Color(red: 0.015, green: 0.025, blue: 0.06).opacity(0.7)
    static let cardFill = Color(red: 0.55, green: 0.70, blue: 1.0).opacity(0.06)
    static let cardStroke = Color(red: 0.6, green: 0.75, blue: 1.0).opacity(0.14)
    static let control = Color(red: 0.55, green: 0.70, blue: 1.0).opacity(0.1)
}

/** "#RRGGBB" ↔ colours for the range overlay setting. */
enum HexColor {
    static func components(_ hex: String) -> (Double, Double, Double) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else { return (1, 0.6, 0.15) }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    static func cg(_ hex: String, alpha: Double) -> CGColor {
        let c = components(hex)
        return CGColor(red: c.0, green: c.1, blue: c.2, alpha: alpha)
    }

    static func color(_ hex: String) -> Color {
        let c = components(hex)
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    static let presets = ["#FF9926", "#F2C744", "#FF5C6C", "#59EB99", "#40D9FF", "#9E7BFF", "#FF7BE0", "#FFFFFF"]

    /** Hue cycling once every six seconds, as "#RRGGBB". */
    static func rainbow(ms: Double) -> String {
        let hue = (ms / 6000).truncatingRemainder(dividingBy: 1)
        guard let c = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1).usingColorSpace(.sRGB) else { return presets[0] }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    /** "#RRGGBB" upper-cased, nil when the text is not six hex digits. */
    static func normalized(_ text: String) -> String? {
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + digits
    }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.gradient)
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(LinearGradient(colors: [Theme.accent2.opacity(0.35), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
        }
    }
}

struct SettingRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12.5, weight: .medium))
                if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            content
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var color: Color = Theme.accent2
    var icon: String = "circle.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.control.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct KeyBindButton: View {
    @Binding var keyCode: UInt16
    var clearable = false
    var compact = false
    @State private var listening = false
    @State private var poll: Timer?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                toggle()
            } label: {
                Text(listening ? "Press a key…" : KeyNames.name(keyCode))
                    .font(.system(size: compact ? 10.5 : 12, weight: .semibold, design: .rounded))
                    .frame(minWidth: compact ? 58 : 96)
                    .padding(.vertical, compact ? 3 : 5).padding(.horizontal, compact ? 7 : 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(listening ? Theme.accent.opacity(0.4) : Theme.control))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(listening ? Theme.accent2 : Theme.cardStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            if clearable && keyCode != KeyNames.none {
                Button { keyCode = KeyNames.none } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .onDisappear { stopPolling() }
    }

    /** Polls the keyboard only while a binding is being recorded. */
    private func toggle() {
        listening.toggle()
        stopPolling()
        guard listening else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let key = KeyNames.pressedKey() else { return }
                if key != 53 { keyCode = key }
                listening = false
                stopPolling()
            }
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
