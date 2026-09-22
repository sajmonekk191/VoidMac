import AppKit
import Combine
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
atexit { Log.flush() }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let settings = Settings.load()
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--analyze"), index + 1 < arguments.count,
   let hud = arguments.firstIndex(of: "--hud"), hud + 1 < arguments.count {
    let readIndex = arguments.firstIndex(of: "--hud-read")
    Analyze.hud(path: arguments[index + 1], champion: arguments[hud + 1], readPath: readIndex.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil })
    exit(0)
}
if let index = arguments.firstIndex(of: "--ui-shot"), index + 1 < arguments.count {
    MainActor.assumeIsolated { UIPreview.render(to: arguments[index + 1], settings: settings) }
    exit(0)
}
if arguments.contains("--windows") {
    GameSession.printWindowList()
    exit(0)
}

Log.info("Void# for macOS, config: \(Settings.fileURL.path)")
let realtimeActivity = ProcessInfo.processInfo.beginActivity(options: [.latencyCritical, .userInitiated], reason: "Realtime input timing")
let initialPermissions = Permissions.request()

let live = LiveClient()
let game = GameSession(settings: settings)
let vision = Vision(game: game, settings: settings)
let autoaim = Autoaim(settings: settings, live: live, game: game, vision: vision)
let orbwalker = Orbwalker(settings: settings, live: live, game: game, vision: vision, aim: autoaim)
vision.isWanted = { live.snapshot.connected && game.isFocused }
vision.attackRange = { live.snapshot.attackRange }
vision.enemyPlayers = { live.snapshot.enemies }
vision.ownChampion = { live.snapshot.championName }
vision.gameTime = { live.snapshot.gameTime }
vision.names.enemies = { live.snapshot.enemies }
vision.learned = { kx, feet, centreY in DispatchQueue.main.async { settings.learnCalibration(kxRef: kx, barToFeetRef: feet, feetFromCentreYRef: centreY) } }
orbwalker.heightLearned = { champion, factor in DispatchQueue.main.async { settings.learnHeight(champion: champion, factor: factor) } }
vision.abilityIcons = {
    let snap = live.snapshot
    var files: [String: String] = [:]
    for slot in ["Q", "W", "E", "R"] {
        if let spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot), !spec.image.isEmpty { files[slot] = spec.image }
    }
    return (snap.championName, files)
}
InputMonitor.shared.interceptor = { code, down, isRepeat in autoaim.intercept(keyCode: code, down: down, isRepeat: isRepeat) }
InputMonitor.shared.onKeyDown = { code in orbwalker.keyPressed(code) }
game.isMatchActive = { live.snapshot.connected }

func shutdown() {
    orbwalker.releaseHeldKeys()
    settings.save()
    game.capture.stop()
    exit(0)
}
AppLifecycle.shutdown = shutdown

if arguments.contains("--dump") {
    game.start()
    let deadline = nowMs() + 8000
    while nowMs() < deadline && game.capture.fps == 0 { sleepMs(100) }
    print(FrameDump.save(from: game.capture, settings: settings))
    print("Capture FPS: \(Int(game.capture.fps)), window: \(game.capture.windowFrame)")
    shutdown()
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown() }
sigint.resume()

InputMonitor.shared.start()
live.start()
game.start()
vision.start()
orbwalker.start()

let autosave = settings.objectWillChange
    .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
    .sink { settings.save() }
let windows: WindowController = MainActor.assumeIsolated {
    let state = AppState()
    state.permissions = initialPermissions
    let controller = WindowController(settings: settings, state: state, live: live, game: game, orbwalker: orbwalker, vision: vision)
    controller.startTimers()
    controller.showPanelAfterLaunch()
    return controller
}
app.run()
