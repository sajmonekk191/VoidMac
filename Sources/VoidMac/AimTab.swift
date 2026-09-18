import SwiftUI

struct AimTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    @ObservedObject private var icons = IconStore.shared

    private let slots = ["Q", "W", "E", "R"]

    private var championName: String {
        state.snapshot.championName.isEmpty ? settings.lastChampion : state.snapshot.championName
    }

    var body: some View {
        Group {
            Card(title: "Autoaim", icon: "scope") {
                Text("Press Q/W/E/R: the program holds the key back, moves the cursor onto the enemy (for skillshots onto the predicted position), waits for two new game frames and sends the key. While you hold the key the cursor follows the target; after release and two more frames it returns to where your hand is. With no target in range the key passes to the game normally.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Autoaim enabled") { Toggle("", isOn: $settings.aim.enabled).toggleStyle(.switch).labelsHidden() }
                SettingRow(label: "Cast mode", hint: settings.aim.castMode == "quick" ? "Quick cast (with indicator too): the spell fires on key press or release" : "Normal cast: the key, then a left click on the target") {
                    Picker("", selection: $settings.aim.castMode) {
                        Text("Quick cast").tag("quick")
                        Text("Key + click").tag("normal")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                SettingRow(label: "Target selection", hint: targetHint) {
                    Picker("", selection: $settings.aim.targetMode) {
                        Text("Near cursor").tag("cursor")
                        Text("Nearest").tag("nearest")
                        Text("Lowest HP").tag("lowest")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                if settings.aim.targetMode == "cursor" {
                    SettingRow(label: "Radius around the cursor", hint: "\(Int(settings.aim.cursorRadius)) px at 1920×1080; farther from the cursor the nearest enemy is taken") {
                        Slider(value: $settings.aim.cursorRadius, in: 100...900, step: 10).frame(width: 220)
                    }
                }
                SettingRow(label: "Movement prediction", hint: "Target speed in the world = bar motion minus ground motion (a locked camera moves with you), times the flight time (cast time + distance / missile speed)") { Toggle("", isOn: $settings.aim.prediction).toggleStyle(.switch).labelsHidden() }
                SettingRow(label: "Prediction strength", hint: String(format: "%.0f %% of the predicted shift", settings.aim.predictionFactor * 100)) {
                    Slider(value: $settings.aim.predictionFactor, in: 0.3...1.6, step: 0.05).frame(width: 220)
                }
                SettingRow(label: "Only targets in spell range", hint: settings.aim.requireInRange ? "Out of range (+\(Int(settings.aim.rangeTolerance)) %) the key passes to the game without aiming" : "Aims even out of range") { Toggle("", isOn: $settings.aim.requireInRange).toggleStyle(.switch).labelsHidden() }
                SettingRow(label: "Range tolerance", hint: "\(Int(settings.aim.rangeTolerance)) %") {
                    Slider(value: $settings.aim.rangeTolerance, in: 0...40, step: 1).frame(width: 220)
                }
                SettingRow(label: "Only while activation is held", hint: "Autoaim works only while you hold \(KeyNames.name(settings.activationKeyCode))") { Toggle("", isOn: $settings.aim.onlyWhileActivation).toggleStyle(.switch).labelsHidden() }
            }
            Card(title: "Spell keys", icon: "keyboard") {
                Text("The same keys as in game. The switch turns aiming off for that slot (R, say).").font(.system(size: 10.5)).foregroundStyle(.secondary)
                slotRow("Q", $settings.aim.slotQ, $settings.aim.keyQ)
                slotRow("W", $settings.aim.slotW, $settings.aim.keyW)
                slotRow("E", $settings.aim.slotE, $settings.aim.keyE)
                slotRow("R", $settings.aim.slotR, $settings.aim.keyR)
                slotRow("D", $settings.aim.slotD, $settings.aim.keyD)
                slotRow("F", $settings.aim.slotF, $settings.aim.keyF)
                Text("D and F aim only Ignite and Exhaust (targeted summoners); Flash, Heal and the rest pass to the game.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Vector spell length", hint: "\(Int(settings.aim.vectorLength)) units between the first and second point (Viktor E, Rumble R)") {
                    Slider(value: $settings.aim.vectorLength, in: 200...900, step: 25).frame(width: 220)
                }
            }
            Card(title: "Timing", icon: "timer") {
                SettingRow(label: "Delay after moving the cursor", hint: "\(settings.aim.settleMs) ms and then 2 new game frames so the game reads the new position") { intSlider($settings.aim.settleMs, 4...60) }
                SettingRow(label: "Minimum key hold", hint: "\(settings.aim.holdMs) ms; otherwise held as long as your finger") { intSlider($settings.aim.holdMs, 1...30) }
                SettingRow(label: "Delay before return", hint: "\(settings.aim.restoreMs) ms after the key release plus 2 new game frames") { intSlider($settings.aim.restoreMs, 0...60) }
            }
            Card(title: "Scale and my position", icon: "ruler") {
                Text("Reach, dashes and prediction convert pixels to game units through the camera perspective (56° pitch: a unit is longer at the bottom of the screen than at the top). With Show Range on, the scale, perspective and my feet are measured continuously from the range ring (ring = attack range + 65, the champion radius; a target is in reach when its centre is no farther than its own radius beyond the ring), on high ground too. The values below are the fallback without a ring and get overwritten by measured ones.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Calibration from the range ring", hint: settings.aim.ringCalibration ? "Every 200 ms the ring is searched around the champion (72 rays, RANSAC ellipse) for the scale, perspective and feet" : "Off: only the values below apply") {
                    Toggle("", isOn: $settings.aim.ringCalibration).toggleStyle(.switch).labelsHidden()
                }
                if !state.vision.rangeText.isEmpty {
                    Text(state.vision.rangeText).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SettingRow(label: "Scale without a ring", hint: String(format: "%.3f px / unit at the screen centre at 1920 wide; vertical scale and perspective follow from the camera pitch", settings.aim.pxPerUnitX)) {
                    Slider(value: $settings.aim.pxPerUnitX, in: 0.3...1.3, step: 0.005).frame(width: 220)
                }
                SettingRow(label: "From my bar to my feet", hint: "\(Int(settings.aim.selfFeetOffsetY)) px down") {
                    Slider(value: $settings.aim.selfFeetOffsetY, in: 40...200, step: 1).frame(width: 220)
                }
                SettingRow(label: "Use the screen centre without a bar", hint: "For a locked camera when the green bar is momentarily hidden") { Toggle("", isOn: $settings.aim.assumeCenter).toggleStyle(.switch).labelsHidden() }
                Text(visionStatus).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            spellsCard
            Card(title: "Status", icon: "waveform.path.ecg") {
                HStack(spacing: 10) {
                    StatTile(title: "Last spell", value: state.aimStatus.lastSlot.isEmpty ? "–" : "\(state.aimStatus.lastSlot) · \(state.aimStatus.lastText)", color: Theme.accent2, icon: "scope")
                    StatTile(title: "Aimed", value: "\(state.aimStatus.casts)", icon: "checkmark.circle")
                    StatTile(title: "Passed without aiming", value: "\(state.aimStatus.passThroughs)", color: Theme.gold, icon: "arrow.right.circle")
                }
                if !state.aimStatus.lastPassThrough.isEmpty {
                    Text("Last pass-through: \(state.aimStatus.lastPassThrough)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var visionStatus: String {
        let vision = state.vision
        guard vision.frameWidth > 0 else { return "Vision runs only in game with autoaim enabled." }
        let selfText = vision.selfBar.map { "own bar (\($0.x), \($0.y)) px" } ?? "own bar not found"
        return String(format: "Now: %@, enemies %d, ground motion %.2f / %.2f px/ms from %d patches, scan %d µs", selfText, vision.enemies.count, vision.groundVx, vision.groundVy, vision.flowPatches, Int(vision.scanMicros))
    }

    private var targetHint: String {
        switch settings.aim.targetMode {
        case "nearest": return "Enemy nearest to you"
        case "lowest": return "Enemy with the lowest HP share"
        default: return "Enemy nearest the cursor, else nearest to you"
        }
    }

    private func slotRow(_ slot: String, _ enabled: Binding<Bool>, _ key: Binding<UInt16>) -> some View {
        SettingRow(label: "Spell \(slot)") {
            HStack(spacing: 10) {
                KeyBindButton(keyCode: key)
                Toggle("", isOn: enabled).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private func intSlider(_ value: Binding<Int>, _ range: ClosedRange<Double>) -> some View {
        Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }), in: range, step: 1).frame(width: 220)
    }

    private var championID: String {
        Spells.byChampion[Settings.normalize(championName)]?.first?.champion ?? championName
    }

    private var spellsCard: some View {
        Card(title: championName.isEmpty ? "Champion spells" : "Spells: \(championName)", icon: "sparkles") {
            HStack(spacing: 10) {
                if let image = icons.champion(championID) {
                    Image(nsImage: image).resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if state.snapshot.championName.isEmpty {
                    Picker("Champion", selection: $settings.lastChampion) {
                        Text("–").tag("")
                        ForEach(Spells.champions, id: \.id) { champion in Text(champion.name).tag(champion.id) }
                    }
                    .frame(width: 260)
                    Text("Out of game you can preset the spells; in game the champion loads by itself.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    Text("In game: \(state.snapshot.championName), level \(state.snapshot.level)").font(.system(size: 12, weight: .semibold))
                }
                Spacer()
            }
            ForEach(slots, id: \.self) { slot in
                if let spec = Spells.resolve(abilityID: state.snapshot.abilities[slot]?.id ?? "", champion: championName, slot: slot) {
                    spellRow(slot: slot, spec: spec)
                } else if !championName.isEmpty {
                    Text("\(slot): spell not in the table").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if state.snapshot.summoners.count == 2 {
                ForEach(["D", "F"], id: \.self) { slot in
                    if let spec = Autoaim.summonerSpec(state.snapshot.summoners[slot == "D" ? 0 : 1], slot: slot) {
                        spellRow(slot: slot, spec: spec)
                    }
                }
            }
            Text("Aiming type and geometry come from CommunityDragon (Data Dragon \(SpellData.version)). When the table is wrong, switch the type by hand.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func spellRow(slot: String, spec: SpellSpec) -> some View {
        let override = overrideBinding(spec)
        let targeting = settings.engine.aimTargeting(for: spec) ?? .unknown
        let level = state.snapshot.abilities[slot]?.level ?? 0
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)).frame(width: 44, height: 44)
                if let image = icons.spell(spec.image) {
                    Image(nsImage: image).resizable().frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(slot).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if level > 0 {
                    Text("\(level)").font(.system(size: 9, weight: .bold)).padding(3).background(Circle().fill(Theme.accent)).offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(slot) · \(spec.name)").font(.system(size: 12.5, weight: .semibold))
                Text(details(spec, targeting: targeting)).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Picker("", selection: override.targeting) {
                    Text("auto: \(spec.targetingType.label)").tag("auto")
                    ForEach(SpellTargeting.allCases.filter { $0 != .unknown }, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 190)
                HStack(spacing: 12) {
                    Toggle("Aim", isOn: override.enabled).toggleStyle(.switch).controlSize(.small).disabled(!(targeting.aimable || targeting == .vector))
                    Toggle("Predict", isOn: override.prediction).toggleStyle(.switch).controlSize(.small).disabled(targeting == .unit || !(targeting.aimable || targeting == .vector))
                }
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(targeting.aimable || targeting == .vector ? 0.05 : 0.02)))
    }

    private func details(_ spec: SpellSpec, targeting: SpellTargeting) -> String {
        var parts = [targeting.label, "range \(spec.rangeText)"]
        if spec.speed > 0 { parts.append("missile \(Int(spec.speed))") }
        if spec.width > 0 { parts.append("width \(Int(spec.width))") }
        if spec.radius > 100 { parts.append("radius \(Int(spec.radius))") }
        if spec.coneAngle > 0 { parts.append("cone \(Int(spec.coneAngle))°") }
        parts.append(String(format: "cast %.2f s", spec.castTime))
        parts.append("CD \(spec.cooldownText)")
        return parts.joined(separator: " · ")
    }

    private func overrideBinding(_ spec: SpellSpec) -> Binding<SpellOverride> {
        let key = spec.id.lowercased()
        return Binding(get: { settings.aim.overrides[key] ?? SpellOverride() },
                       set: { value in
                           if value == SpellOverride() { settings.aim.overrides.removeValue(forKey: key) } else { settings.aim.overrides[key] = value }
                       })
    }
}
