import SwiftUI

/** This match's enemy champions in attack order, rearranged with the arrows; the order is stored per champion and reused in later games, and champions never ordered follow by class. */
struct PriorityList: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: AppState
    var compact = false

    private var enemies: [EnemyPlayer] { state.snapshot.enemies }

    private var ordered: [EnemyPlayer] {
        TargetPriority.ordered(enemies.map(\.champion), order: settings.targetPriority).compactMap { key in enemies.first { $0.champion == key } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if enemies.isEmpty {
                Text("In a match the enemy champions are listed here to put in order. Champions never ordered follow by class: marksmen, then mages and assassins, fighters, supports, tanks.")
                    .font(.system(size: compact ? 10 : 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(ordered.enumerated()), id: \.element.champion) { index, enemy in row(index, enemy) }
                Button("Order by class") {
                    let keys = Set(enemies.map(\.champion))
                    settings.targetPriority = settings.targetPriority.filter { !keys.contains($0) }
                }
                .controlSize(.mini)
            }
        }
    }

    private func row(_ index: Int, _ enemy: EnemyPlayer) -> some View {
        HStack(spacing: 6) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary).frame(width: 14)
            Text(enemy.championName).font(.system(size: compact ? 11 : 12, weight: .semibold)).lineLimit(1)
            Text(ChampionCombat.traits(for: enemy.champion)?.role ?? "").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            VStack(spacing: 0) {
                Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
                Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index >= enemies.count - 1)
            }
            .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func move(_ index: Int, by offset: Int) {
        var keys = ordered.map(\.champion)
        guard keys.indices.contains(index), keys.indices.contains(index + offset) else { return }
        keys.swapAt(index, index + offset)
        settings.targetPriority = TargetPriority.reorder(keys, stored: settings.targetPriority)
    }
}
