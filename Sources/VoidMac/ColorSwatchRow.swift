import SwiftUI

/** Preset colour dots, an optional rainbow dot, and a "#RRGGBB" box that turns into a text field only after a click. */
struct ColorSwatchRow: View {
    @Binding var hex: String
    var rainbow: Binding<Bool>?
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var rainbowOn: Bool { rainbow?.wrappedValue ?? false }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HexColor.presets, id: \.self) { preset in
                let chosen = !rainbowOn && hex.uppercased() == preset
                Button {
                    hex = preset
                    rainbow?.wrappedValue = false
                } label: {
                    Circle().fill(HexColor.color(preset)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white.opacity(chosen ? 0.95 : 0.25), lineWidth: chosen ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
            if let rainbow {
                Button { rainbow.wrappedValue = true } label: {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.white.opacity(rainbowOn ? 0.95 : 0.25), lineWidth: rainbowOn ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
            if editing {
                TextField("#RRGGBB", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).frame(width: 66)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.8), lineWidth: 1))
                    .focused($focused)
                    .onAppear {
                        draft = hex
                        focused = true
                    }
                    .onSubmit {
                        if let value = HexColor.normalized(draft) {
                            hex = value
                            rainbow?.wrappedValue = false
                        }
                        editing = false
                    }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, value in if !value { editing = false } }
            } else {
                Button { editing = true } label: {
                    Text(rainbowOn ? "duha" : hex).font(.system(size: 11, design: .monospaced)).fixedSize()
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
