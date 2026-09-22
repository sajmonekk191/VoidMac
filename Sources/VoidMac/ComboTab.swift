import SwiftUI

struct ComboTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    @ObservedObject private var icons = IconStore.shared

    private var championName: String {
        state.snapshot.championName.isEmpty ? settings.lastChampion : state.snapshot.championName
    }

    private var championKey: String { Settings.normalize(championName) }
    private var combo: ChampionCombo { settings.combos.champions[championKey] ?? ChampionCombos.combo(for: championName) }
    private var isCustom: Bool { settings.combos.champions[championKey] != nil }

    private var championID: String {
        Spells.byChampion[championKey]?.first?.champion ?? championName
    }

    var body: some View {
        Group {
            Card(title: "Combos", icon: "list.number") {
                Text("While \(KeyNames.name(settings.activationKeyCode)) is held the orbwalker weaves the enabled abilities between auto-attacks in order: learned, off cooldown and affordable. An ability that resets the attack timer (Lucian E) goes right after a confirmed attack and the next attack right after it. The others do not reset it (Lucian Q, W): the next attack is allowed only 1/attack speed after the previous one whenever they are cast, so they go just before it (ability → attack with no gap, kiting before), optionally right after the attack (attack → ability, kiting after).")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                SettingRow(label: "Combos enabled") { Toggle("", isOn: $settings.combos.enabled).toggleStyle(.switch).labelsHidden() }
                SettingRow(label: "Ignore cooldowns", hint: "Only when the HUD is not read: for Practice Tool with cooldowns off; otherwise the cooldown is estimated from own casts, spell level and ability haste") {
                    Toggle("", isOn: $settings.combos.ignoreCooldowns).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "One ability per attack", hint: settings.combos.oneAbilityPerAttack ? "AA → Q → AA → W → AA → E …, one ability between attacks (Lucian passive)" : "After an attack all ready abilities are cast in a row") {
                    Toggle("", isOn: $settings.combos.oneAbilityPerAttack).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Ability just before the attack", hint: settings.combos.castBeforeAttack ? "The cast ends exactly when the next attack is due: kiting → W → AA → kiting → Q → AA; resets (E) go right after the attack and the AA right after them" : "Right after the attack lands: AA → W → kiting until the next attack; an ability ready between attacks goes at once if its cast fits") {
                    Toggle("", isOn: $settings.combos.castBeforeAttack).toggleStyle(.switch).labelsHidden()
                }
                SettingRow(label: "Combo must not delay the attack", hint: "An ability is cast only when its whole cast lock fits in the gap between attacks; off, a cast may push the next attack by up to 100 ms (measured +103 ms on Ashe Q)") {
                    Toggle("", isOn: $settings.combos.neverDelayAttack).toggleStyle(.switch).labelsHidden()
                }
            }
            Card(title: championName.isEmpty ? "Champion combo" : "Combo: \(championName)", icon: "sparkles") {
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
                        Text("Out of game you can preset the combo; in game the champion loads by itself.").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    } else {
                        Text("In game: \(state.snapshot.championName), level \(state.snapshot.level)").font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    if isCustom {
                        Button("Default combo") { settings.combos.champions.removeValue(forKey: championKey) }.controlSize(.small)
                    }
                }
                if championName.isEmpty {
                    Text("Pick a champion.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(combo.steps.enumerated()), id: \.element.id) { index, step in
                        stepRow(index: index, step: step)
                    }
                    Text("Order = casting order across attacks. “Cursor direction” is for dashes (Lucian E): the cursor stays where you kite. Keep channelled ults (Lucian R) off, the next attack would cancel them.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Card(title: "Status", icon: "waveform.path.ecg") {
                HStack(spacing: 10) {
                    StatTile(title: "Last", value: state.comboStatus.lastText.isEmpty ? "–" : state.comboStatus.lastText, color: Theme.accent2, icon: "sparkles")
                    StatTile(title: "Cast", value: "\(state.comboStatus.casts)", icon: "checkmark.circle")
                    StatTile(title: state.snapshot.resourceType.isEmpty ? "Resource" : state.snapshot.resourceType.capitalized, value: "\(Int(state.snapshot.resourceValue)) / \(Int(state.snapshot.resourceMax))", color: Theme.gold, icon: "drop.fill")
                }
                Text(state.comboStatus.readiness.isEmpty ? "No ability is enabled." : ["Q", "W", "E", "R"].compactMap { slot in state.comboStatus.readiness[slot].map { "\(slot): \($0)" } }.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Cast lock: " + ["Q", "W", "E", "R"].compactMap { slot in state.comboStatus.castLocks[slot].map { "\(slot) \($0)" } }.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(state.vision.hudText.isEmpty ? "HUD: icon reading runs only in game with combos enabled" : state.vision.hudText)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
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
        let level = state.snapshot.abilities[step.slot]?.level ?? 0
        return HStack(spacing: 12) {
            Text("\(index + 1).").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.secondary).frame(width: 20)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)).frame(width: 40, height: 40)
                if let spec, let image = icons.spell(spec.image) {
                    Image(nsImage: image).resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(step.slot).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if level > 0 {
                    Text("\(level)").font(.system(size: 9, weight: .bold)).padding(3).background(Circle().fill(Theme.accent)).offset(x: 4, y: 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(step.slot) · \(spec?.name ?? "?")").font(.system(size: 12.5, weight: .semibold))
                Text(details(spec, targeting: targeting)).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { step.aim }, set: { value in update { $0.steps[index].aim = value } })) {
                if aimable { Text("At target").tag(ComboAim.target) }
                Text("Cursor direction").tag(ComboAim.cursor)
                Text("No aiming").tag(ComboAim.untargeted)
            }
            .labelsHidden().frame(width: 150)
            Toggle("", isOn: Binding(get: { step.enabled }, set: { value in update { $0.steps[index].enabled = value } })).toggleStyle(.switch).labelsHidden()
            VStack(spacing: 2) {
                Button { update { $0.steps.swapAt(index, index - 1) } } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
                Button { update { $0.steps.swapAt(index, index + 1) } } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index >= combo.steps.count - 1)
            }
            .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(step.enabled ? 0.05 : 0.02)))
    }

    private func details(_ spec: SpellSpec?, targeting: SpellTargeting) -> String {
        guard let spec else { return "spell not in the table" }
        var parts = [targeting.label, "range \(spec.rangeText)", String(format: "cast %.2f s", spec.castLock), "CD \(spec.cooldownText)", "cost \(spec.costText)"]
        if ChampionResets.resets(champion: championName, slot: spec.slot) { parts.append("resets AA") }
        return parts.joined(separator: " · ")
    }
}
