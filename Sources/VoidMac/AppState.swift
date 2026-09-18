import AppKit
import Combine

/** Main-thread mirror of the live engine state for SwiftUI views, refreshed 20x per second. */
@MainActor
final class AppState: ObservableObject {
    @Published var snapshot = PlayerSnapshot()
    @Published var vision = VisionSnapshot()
    @Published var aimStatus = AimStatus()
    @Published var comboStatus = ComboStatus()
    @Published var fps = 0.0
    @Published var scanMicros = 0.0
    @Published var activationHeld = false
    @Published var capturing = false
    @Published var focused = false
    @Published var windowFrame = CGRect.zero
    @Published var windowLayer = 0
    @Published var engineStatus = ""
    @Published var pixelSize = CGSize.zero
    @Published var windup = 0.0
    @Published var windupMs = 0.0
    @Published var attacks = 0
    @Published var panelVisible = false
    @Published var tab: PanelTab = .orbwalker
    @Published var preview: FramePreview?
    @Published var previewMessage = ""
    @Published var permissions = PermissionStatus()
    private var slowTick = 0

    func refresh(live: LiveClient, game: GameSession, orbwalker: Orbwalker, vision current: Vision, settings: Settings, menuVisible: Bool = false) {
        guard panelVisible || menuVisible else { return }
        let snap = live.snapshot
        if snapshot != snap { snapshot = snap }
        let capture = game.capture
        slowTick += 1
        if slowTick % 5 == 0 {
            set(\.fps, capture.fps.rounded())
            set(\.scanMicros, (current.latest.scanMicros / 10).rounded() * 10)
        }
        set(\.activationHeld, orbwalker.activationHeld)
        set(\.capturing, capture.isRunning)
        set(\.focused, game.isFocused)
        set(\.windowFrame, capture.windowFrame)
        set(\.windowLayer, capture.windowLayer)
        set(\.engineStatus, orbwalker.statusText)
        set(\.pixelSize, capture.pixelSize)
        set(\.windup, orbwalker.currentWindup)
        set(\.windupMs, orbwalker.currentWindupMs.rounded())
        set(\.attacks, orbwalker.attacks)
        set(\.aimStatus, orbwalker.aim.status)
        let comboSlots = settings.engine.combo(for: snap.championName).steps.filter { $0.enabled }.map { $0.slot }
        set(\.comboStatus, orbwalker.combo.status(snap: snap, hud: current.latest.abilityReady, ignoreCooldowns: settings.combos.ignoreCooldowns, slots: comboSlots))
        let latest = current.latest
        if vision != latest { vision = latest }
        if !snap.championName.isEmpty, settings.lastChampion != snap.championName { settings.lastChampion = snap.championName }
    }

    /** Writes only on change: an inout access of a @Published property would publish even when the value is equal. */
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

struct PermissionStatus: Equatable {
    var accessibility = false
    var screenRecording = false
    var inputMonitoring = false
}
