import SwiftUI

enum MenuSection: String, CaseIterable, Identifiable {
    case orbwalker, autoaim, combos, drawings, detection, extra, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .orbwalker: return "Orbwalker"
        case .autoaim: return "Autoaim"
        case .combos: return "Combos"
        case .drawings: return "Drawings"
        case .detection: return "Detection"
        case .extra: return "Extra"
        case .status: return "Status"
        }
    }

    var icon: String {
        switch self {
        case .orbwalker: return "bolt.fill"
        case .autoaim: return "scope"
        case .combos: return "list.number"
        case .drawings: return "paintbrush.pointed.fill"
        case .detection: return "eye.fill"
        case .extra: return "sparkles"
        case .status: return "waveform.path.ecg"
        }
    }
}

/** Which sections of the in-game menu live in their own window and which are folded. */
@MainActor
final class GameUIState: ObservableObject {
    @Published var popped: Set<String> = []
    @Published var collapsed: Set<String> = []
}

struct GameMenuActions {
    let pop: (MenuSection) -> Void
    let dock: (MenuSection) -> Void
    let close: () -> Void
}

/** Chrome shared by the in-game windows: dark glass, thin blue edge, a light line along the top. */
struct MenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Color(red: 0.03, green: 0.045, blue: 0.09).opacity(0.94)
                    LinearGradient(colors: [Theme.accent.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.accent2.opacity(0.35), lineWidth: 1))
            .overlay(alignment: .top) { Rectangle().fill(Theme.gradient).frame(height: 1.5).padding(.horizontal, 10).opacity(0.9) }
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }
}

/** The in-game menu: one scrolling tree of collapsible sections; a section can be popped out into its own window. */
struct GameMenuView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    @ObservedObject var ui: GameUIState
    let actions: GameMenuActions

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(MenuSection.allCases.filter { !ui.popped.contains($0.rawValue) }) { section in
                        sectionBlock(section)
                    }
                    if ui.popped.count == MenuSection.allCases.count {
                        Text("Every section is in its own window. Use the dock button on a window to bring it back.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(12)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 600)
            footer
        }
        .frame(width: 340)
        .modifier(MenuChrome())
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Void#").font(.system(size: 15, weight: .black, design: .rounded)).foregroundStyle(Theme.gradient)
            Text("MAC").font(.system(size: 7.5, weight: .heavy, design: .rounded)).tracking(1)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent.opacity(0.2)))
                .overlay(Capsule().stroke(Theme.accent2.opacity(0.7), lineWidth: 1))
                .foregroundStyle(Theme.accent2)
            Circle().fill(state.engineStatus == "ACTIVE" ? Theme.ok : (state.engineStatus.hasPrefix("ready") ? Theme.accent2 : Theme.gold)).frame(width: 7, height: 7)
            Text(state.engineStatus).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            ChromeButton(icon: "xmark", help: "Close (\(KeyNames.name(settings.panelKeyCode)) or Esc)") { actions.close() }
        }
        .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 7)
        .background(Color.white.opacity(0.04))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw").font(.system(size: 9))
            Text("Drag a window by its header · ⧉ pops a section out · \(KeyNames.name(settings.panelKeyCode)) toggles the menu")
                .font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white.opacity(0.03))
    }

    private func sectionBlock(_ section: MenuSection) -> some View {
        let folded = ui.collapsed.contains(section.rawValue)
        return VStack(spacing: 0) {
            Button {
                if folded { ui.collapsed.remove(section.rawValue) } else { ui.collapsed.insert(section.rawValue) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: section.icon).font(.system(size: 11)).foregroundStyle(Theme.gradient).frame(width: 16)
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    SectionBadge(section: section, settings: settings, state: state)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) {
                ChromeButton(icon: "arrow.up.forward.square", help: "Open in its own window") { actions.pop(section) }.padding(.trailing, 6)
            }
            if !folded {
                SectionRows(section: section, settings: settings, state: state)
                    .padding(.horizontal, 8).padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(folded ? 0.035 : 0.055)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/** One popped-out section in its own window. */
struct GameWidgetView: View {
    let section: MenuSection
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    let actions: GameMenuActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: section.icon).font(.system(size: 11)).foregroundStyle(Theme.gradient).frame(width: 16)
                Text(section.title).font(.system(size: 12, weight: .semibold))
                Spacer()
                SectionBadge(section: section, settings: settings, state: state)
                ChromeButton(icon: "arrow.down.backward.square", help: "Back into the menu") { actions.dock(section) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(0.05))
            SectionRows(section: section, settings: settings, state: state)
                .padding(10)
        }
        .frame(width: 320)
        .modifier(MenuChrome())
    }
}

/** Small on/off word on a section header: the master switch of that section. */
struct SectionBadge: View {
    let section: MenuSection
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        if let on = flag {
            Text(on ? "ON" : "OFF").font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.5)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(on ? Theme.ok.opacity(0.22) : Color.white.opacity(0.08)))
                .foregroundStyle(on ? Theme.ok : Color.secondary)
                .padding(.trailing, 22)
        } else {
            Color.clear.frame(width: 22, height: 1)
        }
    }

    private var flag: Bool? {
        switch section {
        case .autoaim: return settings.aim.enabled
        case .combos: return settings.combos.enabled
        case .drawings: return settings.drawRange
        case .detection: return settings.identifyChampions
        case .orbwalker: return state.engineStatus == "ACTIVE" || state.engineStatus.hasPrefix("ready")
        default: return nil
        }
    }
}

struct ChromeButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).help(help)
    }
}

/** A compact setting row: label left, control right, the explanation as a tooltip. */
struct MRow<Content: View>: View {
    let label: String
    var hint = ""
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 6)
            content
        }
        .frame(minHeight: 24)
        .help(hint)
    }
}

/** A row whose control needs the full width below the label (colour swatches, combo steps). */
struct MBlock<Content: View>: View {
    let label: String
    var hint = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
            content
        }
        .padding(.vertical, 3)
        .help(hint)
    }
}

struct MInfo: View {
    let label: String
    let value: String
    var color: Color = .white

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(minHeight: 20)
    }
}

/** A switch drawn in SwiftUI, so it shows its state in a window that is not key and animates by itself. */
struct MToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.14)))
                .overlay(Capsule().stroke(Color.white.opacity(isOn ? 0.25 : 0.18), lineWidth: 1))
            Circle().fill(Color.white).frame(width: 12, height: 12).padding(2)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
        }
        .frame(width: 30, height: 16)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.12)) { isOn.toggle() } }
        .accessibilityAddTraits(.isButton)
    }
}

struct MSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var unit = ""
    var decimals = 0

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: $value, in: range, step: step).controlSize(.mini).frame(width: 100)
            Text(String(format: "%.\(decimals)f%@", value, unit)).font(.system(size: 10.5, weight: .medium, design: .monospaced)).frame(width: 46, alignment: .trailing)
        }
    }
}

struct MPicker: View {
    @Binding var selection: String
    let options: [(String, String)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.menu).controlSize(.mini).labelsHidden().frame(width: 118)
    }
}

/** Double binding over an Int setting for the sliders. */
func intBinding(_ value: Binding<Int>) -> Binding<Double> {
    Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
}

/** The rows of one section, shared by the tree and the popped-out windows. */
struct SectionRows: View {
    let section: MenuSection
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 1) {
            switch section {
            case .orbwalker: OrbwalkerRows(settings: settings, state: state)
            case .autoaim: AutoaimRows(settings: settings, state: state)
            case .combos: ComboRows(settings: settings, state: state)
            case .drawings: DrawingRows(settings: settings, state: state)
            case .detection: DetectionRows(settings: settings, state: state)
            case .extra: ExtraRows(settings: settings)
            case .status: StatusRows(settings: settings, state: state)
            }
        }
    }
}

struct OrbwalkerRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            MRow(label: "Activation key", hint: "Hold in game to orbwalk") { KeyBindButton(keyCode: $settings.activationKeyCode, compact: true) }
            MRow(label: "Attack", hint: "Click = the cursor jumps to the target and back; Attack Move = the attack-move key plus a click at the cursor") {
                MPicker(selection: $settings.attackMode, options: [("click", "Click on target"), ("attackmove", "Attack Move")])
            }
            if settings.attackMode == "attackmove" {
                MRow(label: "Attack-move key") { KeyBindButton(keyCode: $settings.attackMoveKeyCode, compact: true) }
                MRow(label: "Left-click after the key", hint: "For the default LoL bind A (waits for a click)") { MToggle(isOn: $settings.attackMoveClick) }
            }
            MRow(label: "Target", hint: "Which enemy in reach is attacked") {
                MPicker(selection: $settings.targetMode, options: [("center", "Nearest to me"), ("lowest", "Lowest HP"), ("cursor", "Near cursor")])
            }
            MRow(label: "Sticky target", hint: "Keeps the last target while it stays in reach") { MToggle(isOn: $settings.stickyTarget) }
            MRow(label: "Only targets in reach", hint: "A click on an enemy out of reach would be a walk toward it") { MToggle(isOn: $settings.attackOnlyInRange) }
            MRow(label: "Reach tolerance", hint: "Percent on top of attack range + both radii") { MSlider(value: $settings.attackRangeTolerance, range: 0...30, unit: " %") }
            MRow(label: "Champion only", hint: "Holds the Target Champions Only bind while orbwalking") { MToggle(isOn: $settings.attackChampionOnly) }
            if settings.attackChampionOnly {
                MRow(label: "Held via", hint: "Middle mouse needs Target Champions Only bound to it in LoL") {
                    MPicker(selection: Binding(get: { settings.championOnlyMiddleMouse ? "mouse" : "key" }, set: { settings.championOnlyMiddleMouse = $0 == "mouse" }), options: [("key", "Key"), ("mouse", "Middle mouse")])
                }
                if !settings.championOnlyMiddleMouse {
                    MRow(label: "Champion-only key") { KeyBindButton(keyCode: $settings.championOnlyKeyCode, compact: true) }
                }
            }
            MRow(label: "Show Range (C) while active", hint: "The game ring calibrates the scale and feet; on now and then is enough") { MToggle(isOn: $settings.showAttackRange) }
            MRow(label: "Hold zone", hint: "No move-click while the cursor is this close to the champion (px)") { MSlider(value: $settings.holdRadius, range: 0...200, step: 5, unit: " px") }
            MRow(label: "Move-click min", hint: "ms between move clicks while kiting") { MSlider(value: intBinding($settings.moveClickMinMs), range: 10...200, step: 5, unit: " ms") }
            MRow(label: "Move-click max") { MSlider(value: intBinding($settings.moveClickMaxMs), range: 10...300, step: 5, unit: " ms") }
            MRow(label: "Attack latency", hint: "ms from the click to the windup start (ping)") { MSlider(value: intBinding($settings.attackLatencyMs), range: 0...300, step: 10, unit: " ms") }
            MRow(label: "Delay after activation", hint: "Nothing is clicked this long after the activation press (camera centring)") { MSlider(value: intBinding($settings.activationDelayMs), range: 0...300, step: 10, unit: " ms") }
            MRow(label: "Extra windup", hint: "Margin after the windup before moving") { MSlider(value: intBinding($settings.extraWindupMs), range: 0...200, step: 5, unit: " ms") }
            MRow(label: "Click humanisation", hint: "Random px around the click point") { MSlider(value: $settings.clickJitter, range: 0...10, unit: " px") }
            MRow(label: "AA reset after abilities", hint: "Abilities that reset the attack timer let the next attack go at once") { MToggle(isOn: $settings.attackResets) }
            MRow(label: "Flee key", hint: "Hold = move only, no attacks") { KeyBindButton(keyCode: $settings.fleeKeyCode, clearable: true, compact: true) }
        }
    }
}

struct AutoaimRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            MRow(label: "Autoaim", hint: "Q/W/E/R are held back, the cursor moves onto the enemy, then the key is sent") { MToggle(isOn: $settings.aim.enabled) }
            MRow(label: "Cast mode") { MPicker(selection: $settings.aim.castMode, options: [("quick", "Quick cast"), ("normal", "Key + click")]) }
            MRow(label: "Target") { MPicker(selection: $settings.aim.targetMode, options: [("cursor", "Near cursor"), ("nearest", "Nearest"), ("lowest", "Lowest HP")]) }
            if settings.aim.targetMode == "cursor" {
                MRow(label: "Cursor radius", hint: "px at 1920×1080 around the cursor") { MSlider(value: $settings.aim.cursorRadius, range: 100...900, step: 10, unit: " px") }
            }
            MRow(label: "Prediction", hint: "Leads skillshots by the target's world velocity × flight time") { MToggle(isOn: $settings.aim.prediction) }
            if settings.aim.prediction {
                MRow(label: "Prediction strength") { MSlider(value: $settings.aim.predictionFactor, range: 0.3...1.6, step: 0.05, unit: "×", decimals: 2) }
            }
            MRow(label: "Only in spell range", hint: "Out of range the key passes to the game") { MToggle(isOn: $settings.aim.requireInRange) }
            MRow(label: "Range tolerance") { MSlider(value: $settings.aim.rangeTolerance, range: 0...40, unit: " %") }
            MRow(label: "Only while activation held") { MToggle(isOn: $settings.aim.onlyWhileActivation) }
            slot("Q", $settings.aim.slotQ, $settings.aim.keyQ)
            slot("W", $settings.aim.slotW, $settings.aim.keyW)
            slot("E", $settings.aim.slotE, $settings.aim.keyE)
            slot("R", $settings.aim.slotR, $settings.aim.keyR)
            slot("D", $settings.aim.slotD, $settings.aim.keyD)
            slot("F", $settings.aim.slotF, $settings.aim.keyF)
            MRow(label: "Vector spell length", hint: "Units between the two points (Viktor E, Rumble R)") { MSlider(value: $settings.aim.vectorLength, range: 200...900, step: 25, unit: " u") }
            MRow(label: "Settle after cursor move") { MSlider(value: intBinding($settings.aim.settleMs), range: 4...60, unit: " ms") }
            MRow(label: "Minimum key hold") { MSlider(value: intBinding($settings.aim.holdMs), range: 1...30, unit: " ms") }
            MRow(label: "Delay before return") { MSlider(value: intBinding($settings.aim.restoreMs), range: 0...60, unit: " ms") }
            MInfo(label: "Last spell", value: state.aimStatus.lastSlot.isEmpty ? "–" : "\(state.aimStatus.lastSlot) · \(state.aimStatus.lastText)", color: Theme.accent2)
            MInfo(label: "Aimed · passed", value: "\(state.aimStatus.casts) · \(state.aimStatus.passThroughs)")
        }
    }

    private func slot(_ name: String, _ enabled: Binding<Bool>, _ key: Binding<UInt16>) -> some View {
        MRow(label: "Spell \(name)", hint: name == "D" || name == "F" ? "Aims only Ignite and Exhaust" : "The same key as in game; the switch turns aiming off for this slot") {
            HStack(spacing: 8) {
                KeyBindButton(keyCode: key, compact: true)
                MToggle(isOn: enabled)
            }
        }
    }
}

struct ComboRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    private var championName: String { state.snapshot.championName.isEmpty ? settings.lastChampion : state.snapshot.championName }
    private var championKey: String { Settings.normalize(championName) }
    private var combo: ChampionCombo { settings.combos.champions[championKey] ?? ChampionCombos.combo(for: championName) }

    var body: some View {
        Group {
            MRow(label: "Combos", hint: "Weaves the enabled abilities between auto-attacks while the activation key is held") { MToggle(isOn: $settings.combos.enabled) }
            MRow(label: "Ability just before the attack", hint: "The cast ends when the next attack is due; resets go right after the attack") { MToggle(isOn: $settings.combos.castBeforeAttack) }
            MRow(label: "Combo must not delay the attack", hint: "Casts only an ability whose cast lock fits in the gap between attacks") { MToggle(isOn: $settings.combos.neverDelayAttack) }
            MRow(label: "One ability per attack") { MToggle(isOn: $settings.combos.oneAbilityPerAttack) }
            MRow(label: "Ignore cooldowns", hint: "Practice Tool with cooldowns off") { MToggle(isOn: $settings.combos.ignoreCooldowns) }
            MBlock(label: championName.isEmpty ? "Combo: pick a champion out of game" : "Combo: \(championName)", hint: "Order = casting order across attacks; the picker says how each ability is aimed") {
                if championName.isEmpty {
                    Picker("", selection: $settings.lastChampion) {
                        Text("–").tag("")
                        ForEach(Spells.champions, id: \.id) { champion in Text(champion.name).tag(champion.id) }
                    }
                    .pickerStyle(.menu).controlSize(.mini).labelsHidden().frame(width: 200)
                } else {
                    ForEach(Array(combo.steps.enumerated()), id: \.element.id) { index, step in stepRow(index: index, step: step) }
                    if settings.combos.champions[championKey] != nil {
                        Button("Default combo") { settings.combos.champions.removeValue(forKey: championKey) }.controlSize(.mini)
                    }
                }
            }
            MInfo(label: "Ready", value: state.comboStatus.readiness.isEmpty ? "no ability enabled" : ["Q", "W", "E", "R"].compactMap { slot in state.comboStatus.readiness[slot].map { "\(slot) \($0)" } }.joined(separator: "  "))
            MInfo(label: "Last cast", value: state.comboStatus.lastText.isEmpty ? "–" : state.comboStatus.lastText, color: Theme.accent2)
        }
    }

    private func update(_ change: (inout ChampionCombo) -> Void) {
        var edited = combo
        change(&edited)
        settings.combos.champions[championKey] = edited
    }

    private func stepRow(index: Int, step: ComboStep) -> some View {
        let spec = Spells.resolve(abilityID: state.snapshot.abilities[step.slot]?.id ?? "", champion: championName, slot: step.slot)
        let targeting = settings.engine.aimTargeting(for: spec) ?? .unknown
        let aimable = targeting.aimable || targeting == .vector
        var options: [(String, String)] = [("cursor", "Cursor"), ("self", "No aim")]
        if aimable { options.insert(("target", "At target"), at: 0) }
        return HStack(spacing: 6) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary).frame(width: 12)
            Text(step.slot).font(.system(size: 11, weight: .heavy, design: .rounded)).frame(width: 16)
            Text(spec?.name ?? "?").font(.system(size: 10.5)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            MPicker(selection: Binding(get: { step.aim }, set: { value in update { $0.steps[index].aim = value } }), options: options).frame(width: 92)
            MToggle(isOn: Binding(get: { step.enabled }, set: { value in update { $0.steps[index].enabled = value } }))
            VStack(spacing: 0) {
                Button { update { $0.steps.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
                Button { update { $0.steps.swapAt(index, index + 1) } } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index >= combo.steps.count - 1)
            }
            .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}


struct DrawingRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            MRow(label: "Draw attack reach", hint: "Solid = target centre still in reach, dashed = the gate with tolerance, while the activation key is held") { MToggle(isOn: $settings.drawRange) }
            if settings.drawRange {
                MBlock(label: "Reach colour") { ColorSwatchRow(hex: $settings.rangeColorHex, rainbow: $settings.rangeRainbow) }
                ForEach(["Q", "W", "E", "R"], id: \.self) { slot in
                    let style = settings.spellRanges[slot] ?? SpellRangeStyle.defaults[slot] ?? SpellRangeStyle(colorHex: "#40D9FF")
                    MRow(label: "\(slot) range ring", hint: spellHint(slot)) {
                        MToggle(isOn: Binding(get: { style.enabled }, set: { value in settings.spellRanges[slot] = SpellRangeStyle(enabled: value, colorHex: style.colorHex) }))
                    }
                    if style.enabled {
                        ColorSwatchRow(hex: Binding(get: { style.colorHex }, set: { value in settings.spellRanges[slot] = SpellRangeStyle(enabled: true, colorHex: value) }), rainbow: nil)
                            .padding(.bottom, 4)
                    }
                }
            }
            MRow(label: "Status strip", hint: "Orbwalker, autoaim and combo state at the top of the game") { MToggle(isOn: $settings.layout.hudStrip) }
            MRow(label: "Attack timer under the champion", hint: "Windup in amber, the wait for the next attack in blue, ready in green") { MToggle(isOn: $settings.layout.hudTimer) }
            MRow(label: "Target name", hint: "The recognised champion above the attacked bar") { MToggle(isOn: $settings.layout.hudTarget) }
            MRow(label: "Menu button in the corner", hint: "The V# button at the top-left of the game; \(KeyNames.name(settings.panelKeyCode)) works too") { MToggle(isOn: $settings.layout.badge) }
        }
    }

    private func spellHint(_ slot: String) -> String {
        let champion = state.snapshot.championName.isEmpty ? settings.lastChampion : state.snapshot.championName
        guard let spec = Spells.resolve(abilityID: state.snapshot.abilities[slot]?.id ?? "", champion: champion, slot: slot) else { return "Spell range ring while the activation key is held" }
        return "\(spec.name), range \(spec.rangeText)"
    }
}

struct DetectionRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            MRow(label: "Recognise champions by name", hint: "Reads the name plate and level above enemy bars; the champion's model then gives feet and click point") { MToggle(isOn: $settings.identifyChampions) }
            MRow(label: "Click height on the model", hint: "Percent of the model height above the feet: 40 waist, 55 chest, 80 head") { MSlider(value: $settings.clickHeight, range: 30...95, unit: " %") }
            MRow(label: "X offset", hint: "Left/right from the bar centre at 1920×1080") { MSlider(value: $settings.clickOffsetX, range: -120...120, unit: " px") }
            MRow(label: "Y offset (unrecognised)", hint: "Below the bar top when no name could be read") { MSlider(value: $settings.clickOffsetY, range: 30...160, unit: " pt") }
            MRow(label: "Capture fps", hint: "Capture cap during a match") {
                MPicker(selection: Binding(get: { String(settings.captureFps) }, set: { settings.captureFps = Int($0) ?? 120 }), options: ["24", "30", "48", "60", "80", "120"].map { ($0, $0) })
            }
            MRow(label: "Capture mode") { MPicker(selection: $settings.captureMode, options: [("window", "Automatic"), ("display", "Display")]) }
            MInfo(label: "Capture", value: state.capturing ? "\(Int(state.pixelSize.width))×\(Int(state.pixelSize.height)) @ \(Int(state.fps)) fps" : "no window", color: state.capturing ? Theme.ok : Theme.danger)
            MInfo(label: "Scan", value: state.scanMicros > 0 ? "\(Int(state.scanMicros)) µs" : "–")
        }
    }
}

struct ExtraRows: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Group {
            MRow(label: "Helicopter key", hint: "Toggle: walks a small circle so the champion keeps turning") { KeyBindButton(keyCode: $settings.helicopterKeyCode, clearable: true, compact: true) }
            MRow(label: "Helicopter speed") { MSlider(value: intBinding($settings.helicopterIntervalMs), range: 20...200, step: 5, unit: " ms") }
            MRow(label: "Helicopter radius") { MSlider(value: $settings.helicopterRadius, range: 20...200, step: 5, unit: " px") }
            MRow(label: "Emote after a kill", hint: "0.4 s after each of your champion kills") { MToggle(isOn: $settings.emoteOnKill) }
            MRow(label: "Emote key") { KeyBindButton(keyCode: $settings.emoteKeyCode, compact: true) }
            MRow(label: "Emote with Ctrl") { MToggle(isOn: $settings.emoteCtrl) }
            MRow(label: "Menu key", hint: "Opens this menu in game and the settings window outside it") { KeyBindButton(keyCode: $settings.panelKeyCode, compact: true) }
        }
    }
}

struct StatusRows: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            MInfo(label: "Orbwalker", value: state.engineStatus, color: state.engineStatus == "ACTIVE" ? Theme.ok : (state.engineStatus.hasPrefix("ready") ? Theme.accent2 : Theme.gold))
            MInfo(label: "Live Client", value: state.snapshot.connected ? "connected" : "out of game", color: state.snapshot.connected ? Theme.ok : Theme.danger)
            MInfo(label: "Champion", value: state.snapshot.championName.isEmpty ? "–" : "\(state.snapshot.championName) lvl \(state.snapshot.level)" + (state.snapshot.isDead ? " (dead)" : ""), color: Theme.gold)
            MInfo(label: "Attack speed · range", value: String(format: "%.3f · %.0f", state.snapshot.attackSpeed, state.snapshot.attackRange))
            MInfo(label: "Windup", value: String(format: "%.2f %% · %.0f ms", state.windup, state.windupMs))
            MInfo(label: "Attacks", value: "\(state.attacks)")
            MInfo(label: "Game window", value: state.capturing ? "\(Int(state.windowFrame.width))×\(Int(state.windowFrame.height)) pt" : "not found", color: state.capturing ? Theme.ok : Theme.danger)
            MInfo(label: "Enemies seen", value: "\(state.vision.enemies.count)" + (state.vision.enemies.first { !$0.identity.isEmpty && $0.identity != "dummy" }.map { " · \($0.identity)" } ?? ""))
            MInfo(label: "Range", value: state.vision.rangeText.isEmpty ? "–" : String(state.vision.rangeText.prefix(60)))
            MInfo(label: "Enemy players", value: state.snapshot.enemies.isEmpty ? "none (practice tool)" : state.snapshot.enemies.map { $0.championName }.joined(separator: ", "))
        }
    }
}

/** The small button at the corner of the game that opens the menu. */
struct BadgeView: View {
    @ObservedObject var state: AppState
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("V#").font(.system(size: 11, weight: .black, design: .rounded)).foregroundStyle(Theme.gradient)
                Circle().fill(state.engineStatus == "ACTIVE" ? Theme.ok : (state.engineStatus.hasPrefix("ready") ? Theme.accent2 : Theme.gold)).frame(width: 6, height: 6)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color(red: 0.03, green: 0.045, blue: 0.09).opacity(0.9)))
            .overlay(Capsule().stroke(Theme.accent2.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .preferredColorScheme(.dark)
    }
}
