import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case orbwalker, autoaim, combos, detection, extra, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .orbwalker: return "Orbwalker"
        case .autoaim: return "Autoaim"
        case .combos: return "Combos"
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
        case .detection: return "eye.fill"
        case .extra: return "sparkles"
        case .status: return "waveform.path.ecg"
        }
    }
}

struct SettingsPanel: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    let actions: PanelActions

    /** Spell name and range for the overlay row, from the live champion or the last one. */
    private func spellRangeHint(_ slot: String) -> String {
        let champion = state.snapshot.championName.isEmpty ? settings.lastChampion : state.snapshot.championName
        guard let spec = Spells.resolve(abilityID: state.snapshot.abilities[slot]?.id ?? "", champion: champion, slot: slot) else { return "Spell range ring while the activation key is held" }
        guard spec.range > 0, spec.range < 3000, !spec.isGlobal else { return "\(spec.name): no range to draw" }
        return "\(spec.name), range \(spec.rangeText)"
    }

    private var tab: PanelTab { state.tab }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .frame(width: 860, height: 560)
        .background(
            ZStack {
                VisualEffect()
                LinearGradient(colors: [Theme.baseLight, Theme.base], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.94)
                RadialGradient(colors: [Theme.accent.opacity(0.30), .clear], center: .topLeading, startRadius: 0, endRadius: 560)
                RadialGradient(colors: [Theme.accent2.opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 520)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.accent2.opacity(0.22), lineWidth: 1))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Void#").font(.system(size: 21, weight: .black, design: .rounded)).foregroundStyle(Theme.gradient)
                        Text("MAC").font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(1.2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.2)))
                            .overlay(Capsule().stroke(Theme.accent2.opacity(0.75), lineWidth: 1))
                            .foregroundStyle(Theme.accent2)
                    }
                    Text("orbwalker · autoaim · combos").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 14)

            ForEach(PanelTab.allCases) { item in
                Button { state.tab = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).font(.system(size: 13, weight: tab == item ? .semibold : .medium))
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(tab == item ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear))
                            .shadow(color: tab == item ? Theme.accent.opacity(0.45) : .clear, radius: 8, y: 2)
                    )
                    .foregroundStyle(tab == item ? Color.white : Color.white.opacity(0.62))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            statusBadge
            Text("\(KeyNames.name(settings.panelKeyCode)) opens / closes the panel  ·  Esc closes")
                .font(.system(size: 9.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 210)
        .background(Theme.sidebarFill)
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(state.snapshot.connected ? Theme.ok : Theme.danger).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.snapshot.connected ? "In game" : "Out of game").font(.system(size: 12, weight: .semibold))
                Text(state.capturing ? "capture \(Int(state.fps)) fps" : "game window not found").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
        .padding(.bottom, 8)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(tab.title).font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Button { actions.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                            .background(Circle().fill(Theme.control))
                            .overlay(Circle().stroke(Theme.cardStroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                switch tab {
                case .orbwalker: orbwalkerTab
                case .autoaim: AimTab(settings: settings, state: state)
                case .combos: ComboTab(settings: settings, state: state)
                case .detection: detectionTab
                case .extra: extraTab
                case .status: statusTab
                }
            }
            .padding(22)
        }
    }

    private func intSlider(_ value: Binding<Int>, _ range: ClosedRange<Double>, step: Double = 1) -> some View {
        Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: range, step: step).frame(width: 220)
    }

    private var orbwalkerTab: some View {
        Group {
            Card(title: "Attack method", icon: "scope") {
                SettingRow(label: "Mode", hint: settings.attackMode == "attackmove" ? "Presses the attack-move key and left-clicks at the cursor; the cursor stays put and the game attacks the nearest enemy (a champion with Target Champions Only)" : "The cursor jumps to the target for ~14 ms, right-clicks and returns to where your hand is") {
                    Picker("", selection: $settings.attackMode) {
                        Text("Click on target").tag("click")
                        Text("Attack Move").tag("attackmove")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                if settings.attackMode == "attackmove" {
                    SettingRow(label: "Attack-move key", hint: "Default A = Player Attack Move in LoL") { KeyBindButton(keyCode: $settings.attackMoveKeyCode) }
                    SettingRow(label: "Left-click after the key", hint: settings.attackMoveClick ? "For the default LoL bind A (Player Attack Move waits for a click); the click goes to the cursor outside the HUD and minimap" : "Turn off only with a one-key Player Attack Move Click bound") {
                        Toggle("", isOn: $settings.attackMoveClick).toggleStyle(.switch).labelsHidden()
                    }
                } else {
                    SettingRow(label: "Click hold on target", hint: "\(settings.clickHoldMs) ms between press and release") { intSlider($settings.clickHoldMs, 1...30) }
                    SettingRow(label: "Delay before return", hint: "\(settings.clickSettleMs) ms; the cursor always stays on the target at least one game frame + 2 ms (the game reads the cursor once per frame), \(state.fps > 0 ? "now \(Int(1000 / state.fps + 2)) ms" : "by fps")") { intSlider($settings.clickSettleMs, 0...40) }
                }
                SettingRow(label: "Target selection", hint: settings.targetMode == "center" ? "Enemy nearest the screen centre (fastest)" : (settings.targetMode == "lowest" ? "Enemy with the lowest HP share" : "Enemy nearest the cursor")) {
                    Picker("", selection: $settings.targetMode) {
                        Text("Centre").tag("center")
                        Text("Lowest HP").tag("lowest")
                        Text("Near cursor").tag("cursor")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
            }
            Card(title: "Behaviour", icon: "bolt.fill") {
                SettingRow(label: "Show Range", hint: "Holds the range key (C) while orbwalking; the game ring calibrates the scale and feet, having it on now and then is enough, the values are saved") {
                    Toggle("", isOn: $settings.showAttackRange).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Draw range", hint: "While the activation key is held, draws the exact auto-attack reach over the game: solid line = target centre still in reach, dashed = the gate with tolerance") {
                    Toggle("", isOn: $settings.drawRange).toggleStyle(.switch).labelsHidden()
                }
                if settings.drawRange {
                    SettingRow(label: "Range colour", hint: "Solid line = target centre still in reach, dashed = the gate with tolerance; click a colour, the rainbow dot (animated) or type #RRGGBB and press Enter") {
                        ColorSwatchRow(hex: $settings.rangeColorHex, rainbow: $settings.rangeRainbow)
                    }
                    ForEach(["Q", "W", "E", "R"], id: \.self) { slot in
                        let style = settings.spellRanges[slot] ?? SpellRangeStyle.defaults[slot] ?? SpellRangeStyle(colorHex: "#40D9FF")
                        SettingRow(label: "\(slot) range", hint: spellRangeHint(slot)) {
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { style.enabled }, set: { value in settings.spellRanges[slot] = SpellRangeStyle(enabled: value, colorHex: style.colorHex) })).toggleStyle(.switch).labelsHidden()
                                if style.enabled {
                                    ColorSwatchRow(hex: Binding(get: { style.colorHex }, set: { value in settings.spellRanges[slot] = SpellRangeStyle(enabled: true, colorHex: value) }), rainbow: nil)
                                }
                            }
                        }
                    }
                }
                SettingRow(label: "Attack Champion Only", hint: "Holds the Target Champions Only bind, so a move-click on a minion is a move, not an attack") {
                    Toggle("", isOn: $settings.attackChampionOnly).toggleStyle(.switch).labelsHidden()
                }
                if settings.attackChampionOnly {
                    SettingRow(label: "Target Champions Only held via", hint: settings.championOnlyMiddleMouse ? "In LoL bind Target Champions Only to the middle button and move Camera Drag Scroll elsewhere, otherwise mouse movement drags the camera" : "In LoL: Settings → Hotkeys → bind Target Champions Only to the key below") {
                        Picker("", selection: $settings.championOnlyMiddleMouse) {
                            Text("Key").tag(false)
                            Text("Middle mouse").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    if !settings.championOnlyMiddleMouse {
                        SettingRow(label: "Target Champions Only key", hint: "The same key as in LoL") { KeyBindButton(keyCode: $settings.championOnlyKeyCode) }
                    }
                }
            }
            Card(title: "Smart targeting", icon: "target") {
                SettingRow(label: "Attack only targets in reach", hint: settings.attackOnlyInRange ? "A click on an enemy out of reach would be a walk toward it; reach comes from the Autoaim scale and your position (green bar)" : "Any enemy in view can be the target") {
                    Toggle("", isOn: $settings.attackOnlyInRange).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Attack latency", hint: "\(settings.attackLatencyMs) ms from the click to the windup start when the champion already stands (ping); when it was walking, the start is read from it stopping") {
                    intSlider($settings.attackLatencyMs, 0...300, step: 10)
                }
                SettingRow(label: "Delay after activation", hint: "\(settings.activationDelayMs) ms after pressing \(KeyNames.name(settings.activationKeyCode)) nothing is detected or clicked: LoL centres the camera and older frames show targets elsewhere") {
                    intSlider($settings.activationDelayMs, 0...300, step: 10)
                }
                SettingRow(label: "Reach tolerance", hint: "\(Int(settings.attackRangeTolerance)) % on top of attack range + both radii") {
                    Slider(value: $settings.attackRangeTolerance, in: 0...30, step: 1).frame(width: 220)
                }
                SettingRow(label: "Sticky target", hint: "Keeps the last target while it is visible and in reach; no hopping between enemies") {
                    Toggle("", isOn: $settings.stickyTarget).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Hold zone around the champion", hint: settings.holdRadius > 0 ? "No move-click while the cursor is within \(Int(settings.holdRadius)) px of the champion (no twitching in place)" : "Off") {
                    Slider(value: $settings.holdRadius, in: 0...200, step: 5).frame(width: 220)
                }
                SettingRow(label: "Auto-attack reset after an ability", hint: "After abilities that reset the auto-attack (\(resetText)) the next attack goes out at once") {
                    Toggle("", isOn: $settings.attackResets).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Click humanisation", hint: "±\(Int(settings.clickJitter)) px randomly around the click point") {
                    Slider(value: $settings.clickJitter, in: 0...10, step: 1).frame(width: 220)
                }
                SettingRow(label: "Flee key", hint: "Hold = only move toward the cursor, no attacks and no windup wait") { KeyBindButton(keyCode: $settings.fleeKeyCode, clearable: true) }
            }
            Card(title: "Kiting", icon: "timer") {
                Text("Attack → no movement during the windup → move-clicks at the cursor → next attack exactly after 1/AS. Windup: \(windupText).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Move-click minimum", hint: "\(settings.moveClickMinMs) ms between clicks while kiting") { intSlider($settings.moveClickMinMs, 10...200, step: 5) }
                SettingRow(label: "Move-click maximum", hint: "\(settings.moveClickMaxMs) ms, random between min and max") { intSlider($settings.moveClickMaxMs, 10...300, step: 5) }
                SettingRow(label: "Extra windup", hint: "Margin after the windup before moving is allowed (\(settings.extraWindupMs) ms)") { intSlider($settings.extraWindupMs, 0...200, step: 5) }
                SettingRow(label: "Windup for champions not in the table", hint: String(format: "%.1f %% of the attack delay; the table covers %d champions", settings.defaultWindupPercent, ChampionWindups.table.count)) {
                    Slider(value: $settings.defaultWindupPercent, in: 5...50, step: 0.5).frame(width: 220)
                }
            }
            Card(title: "Keys", icon: "keyboard") {
                SettingRow(label: "Orbwalker activation", hint: "Hold in game") { KeyBindButton(keyCode: $settings.activationKeyCode) }
                SettingRow(label: "Range key", hint: "The key the game shows the attack range with") { KeyBindButton(keyCode: $settings.attackRangeKeyCode) }
                SettingRow(label: "Settings panel", hint: "Opens this panel over the game; F-keys on a MacBook need Fn") { KeyBindButton(keyCode: $settings.panelKeyCode) }
            }
        }
    }


    private var resetText: String {
        let champion = state.snapshot.championName
        guard !champion.isEmpty else { return "table of \(ChampionResets.table.filter { !$0.value.isEmpty }.count) champions" }
        let slots = ChampionResets.table[Settings.normalize(champion)] ?? []
        return slots.isEmpty ? "\(champion): none" : "\(champion): \(slots.sorted().joined(separator: ", "))"
    }

    private var extraTab: some View {
        Group {
            Card(title: "Helicopter", icon: "fan.fill") {
                Text("The champion walks a small circle around itself and keeps turning. Toggled by a key; holding the activation key turns it off.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Key (toggle)") { KeyBindButton(keyCode: $settings.helicopterKeyCode, clearable: true) }
                SettingRow(label: "Speed", hint: "\(settings.helicopterIntervalMs) ms between steps") { intSlider($settings.helicopterIntervalMs, 20...200, step: 5) }
                SettingRow(label: "Radius", hint: "\(Int(settings.helicopterRadius)) px at 1920×1080") {
                    Slider(value: $settings.helicopterRadius, in: 20...200, step: 5).frame(width: 220)
                }
            }
            Card(title: "Emote after a kill", icon: "face.smiling") {
                Text("0.4 s after each of your champion kills (from Live Client API events) an emote key is pressed. In LoL emotes are on Ctrl+1 to Ctrl+4.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Enabled") { Toggle("", isOn: $settings.emoteOnKill).toggleStyle(.switch).labelsHidden() }
                SettingRow(label: "Key") { KeyBindButton(keyCode: $settings.emoteKeyCode) }
                SettingRow(label: "With Ctrl") { Toggle("", isOn: $settings.emoteCtrl).toggleStyle(.switch).labelsHidden() }
            }
        }
    }

    private var windupText: String {
        guard !state.snapshot.championName.isEmpty else { return "official wiki data" }
        let spec = settings.engine.windupSpec(for: state.snapshot.championName)
        return String(format: "%@ %.2f %% → %.0f ms including the margin at AS %.3f", state.snapshot.championName, spec.percent, state.windupMs, state.snapshot.attackSpeed)
    }

    private var detectionTab: some View {
        Group {
            Card(title: "How a target is found", icon: "viewfinder") {
                Text("An enemy champion (or a target dummy) is recognised by the structure of its health bar: red fill, a dark level box with a digit on the left and a bar frame of the right width. Minions, monsters and turrets fail this; a champion with a low or empty bar passes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title: "Image source", icon: "display") {
                SettingRow(label: "Capture mode", hint: "Automatic = the game window, and when it yields no frame within 2 s (Full Screen), a display crop") {
                    Picker("", selection: $settings.captureMode) {
                        Text("Automatic").tag("window")
                        Text("Display").tag("display")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                SettingRow(label: "Frames per second in a match", hint: "Capture cap during a match (always 12 outside one); 120 = the real game fps, the minimum time on target is derived from it") {
                    Picker("", selection: $settings.captureFps) {
                        ForEach([24, 30, 48, 60, 80, 120], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                }
                SettingRow(label: "Capture in points (1×, experimental)", hint: settings.capturePoints ? "4× fewer pixels, but ScreenCaptureKit scales on the GPU and reading a frame is up to 7× slower" : "Native display resolution: frames read fastest") {
                    Toggle("", isOn: $settings.capturePoints).toggleStyle(.switch).labelsHidden()
                }
                Text("Now: \(state.capturing ? "capturing \(Int(state.pixelSize.width))×\(Int(state.pixelSize.height)) px @ \(Int(state.fps)) fps" + (state.fps == 0 ? " (no frame yet)" : "") : "game window not found")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Card(title: "Where to click", icon: "cursorarrow.click") {
                Text("The name above an enemy bar (or its level) tells which champion it is; the champion's model height then gives its feet and the click point, so big and small champions are hit alike. Target dummies are known without a name.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Recognise champions by name", hint: "Reads the name plate and level box above enemy bars with the system text recogniser; off = every enemy uses the Y offset below") {
                    Toggle("", isOn: $settings.identifyChampions).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Click height on the model", hint: "Recognised champions and dummies: \(Int(settings.clickHeight)) % of the model height above the feet (40 = waist, 55 = chest, 80 = head)") {
                    Slider(value: $settings.clickHeight, in: 30...95, step: 1).frame(width: 220)
                }
                SettingRow(label: "X offset from the bar centre", hint: "Left/right at 1920×1080 (\(Int(settings.clickOffsetX)) px)") {
                    Slider(value: $settings.clickOffsetX, in: -120...120, step: 1).frame(width: 220)
                }
                SettingRow(label: "Y offset for unrecognised units", hint: "From the bar top down, \(Int(settings.clickOffsetY)) pt, when no name could be read: ~74 = head and neck, 95 = waist, 140 = feet") {
                    Slider(value: $settings.clickOffsetY, in: 30...160, step: 1).frame(width: 220)
                }
            }
            Card(title: "Detection preview", icon: "photo.on.rectangle.angled") {
                HStack(spacing: 10) {
                    Button { actions.refreshPreview() } label: { Label("Grab a frame", systemImage: "camera.fill") }
                    Button { actions.savePNG() } label: { Label("Save PNG to Desktop", systemImage: "square.and.arrow.down") }
                    Spacer()
                }
                if let preview = state.preview {
                    Image(nsImage: preview.image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.cardStroke))
                    Text(preview.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !state.previewMessage.isEmpty {
                    Text(state.previewMessage).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Yellow circles = all enemy bars, red circle = the bar nearest the champion, green circle = own bar, yellow cross = the click point.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var statusTab: some View {
        Group {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(title: "Live Client API", value: state.snapshot.connected ? "connected" : "out of game", color: state.snapshot.connected ? Theme.ok : Theme.danger, icon: "network")
                StatTile(title: "Champion", value: state.snapshot.championName.isEmpty ? "–" : state.snapshot.championName + (state.snapshot.isDead ? " (dead)" : ""), color: Theme.gold, icon: "person.fill")
                StatTile(title: "Windup", value: String(format: "%.2f %% · %.0f ms", state.windup, state.windupMs), icon: "timer")
                StatTile(title: "Attack speed", value: String(format: "%.3f", state.snapshot.attackSpeed), icon: "hare.fill")
                StatTile(title: "Attack range", value: String(format: "%.0f", state.snapshot.attackRange), icon: "scope")
                StatTile(title: "\(KeyNames.name(settings.activationKeyCode)) held", value: state.activationHeld ? "yes" : "no", color: state.activationHeld ? Theme.ok : .secondary, icon: "keyboard")
                StatTile(title: "Game window", value: state.capturing ? "\(Int(state.windowFrame.width))×\(Int(state.windowFrame.height)) pt" : "not found", color: state.capturing ? Theme.ok : Theme.danger, icon: "macwindow")
                StatTile(title: "Capture", value: state.capturing ? "\(Int(state.pixelSize.width))×\(Int(state.pixelSize.height)) @ \(Int(state.fps)) fps" : "–", icon: "video.fill")
                StatTile(title: "Pixel scan · attacks", value: (state.scanMicros > 0 ? "\(Int(state.scanMicros)) µs" : "–") + " · \(state.attacks)", icon: "speedometer")
            }
            Card(title: "Orbwalker", icon: "bolt.fill") {
                HStack(spacing: 10) {
                    Circle().fill(state.engineStatus == "ACTIVE" ? Theme.ok : (state.engineStatus.hasPrefix("ready") ? Theme.accent2 : Theme.gold)).frame(width: 10, height: 10)
                    Text(state.engineStatus).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(state.focused ? "game in front" : "game not in front").font(.system(size: 11)).foregroundStyle(state.focused ? Theme.ok : Theme.danger)
                }
            }
            Card(title: "Permissions", icon: "lock.shield") {
                permissionRow("Accessibility", state.permissions.accessibility, pane: "Privacy_Accessibility")
                permissionRow("Screen Recording", state.permissions.screenRecording, pane: "Privacy_ScreenCapture")
                permissionRow("Input Monitoring", state.permissions.inputMonitoring, pane: "Privacy_ListenEvent")
                HStack {
                    Button { actions.recheckPermissions() } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    Button { actions.relaunch() } label: { Label("Relaunch the app", systemImage: "arrow.triangle.2.circlepath") }
                }
            }
            Card(title: "Configuration", icon: "doc.text") {
                SettingRow(label: "Game bundle ID", hint: "Which window is looked for; the default is the League game client") {
                    HStack(spacing: 6) {
                        TextField("", text: $settings.gameBundleID).textFieldStyle(.roundedBorder).frame(width: 300).font(.system(size: 11, design: .monospaced))
                        if settings.gameBundleID != "com.riotgames.LeagueofLegends.GameClient" {
                            Button { settings.gameBundleID = "com.riotgames.LeagueofLegends.GameClient" } label: { Text("League") }
                        }
                    }
                }
                Text(Settings.fileURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Log: \(Log.fileURL.path)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button { actions.revealConfig() } label: { Label("Show in Finder", systemImage: "folder") }
                    Button(role: .destructive) { actions.resetSettings() } label: { Label("Restore defaults", systemImage: "arrow.counterclockwise") }
                }
            }
        }
    }

    private func permissionRow(_ name: String, _ granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(granted ? Theme.ok : Theme.danger)
            Text(name).font(.system(size: 12.5))
            Spacer()
            Text(granted ? "granted" : "missing").font(.system(size: 11, weight: .semibold)).foregroundStyle(granted ? Theme.ok : Theme.danger)
            if !granted {
                Button { actions.openPrivacySettings(pane) } label: { Label("Allow", systemImage: "arrow.up.forward.square") }
            }
        }
    }
}
