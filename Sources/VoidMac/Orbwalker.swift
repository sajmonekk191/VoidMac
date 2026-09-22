import AppKit
import CoreGraphics
import Foundation
import os

/** Hand movement measured from the OS cursor between our own position posts; queries happen only where a stall cannot show. */
struct HandTracker {
    private(set) var anchor: CGPoint
    private(set) var hand = CGPoint.zero

    init(origin: CGPoint) {
        anchor = origin
    }

    /** Adds whatever the hand moved the cursor since the last post or accumulate (one position query). */
    mutating func accumulate() {
        let p = Input.mousePosition()
        hand.x += p.x - anchor.x
        hand.y += p.y - anchor.y
        anchor = p
    }

    /** Moves the cursor without querying anything: the deltas come from the last known anchor. */
    mutating func move(to point: CGPoint) {
        Input.moveCursor(to: point, from: anchor)
        anchor = point
    }

    /** Call right after posting a click that put the cursor at `point`. */
    mutating func posted(_ point: CGPoint) {
        anchor = point
    }

    /** Where the hand would be now, capped so a glitch can never fling the cursor. */
    func restoredPoint(from origin: CGPoint) -> CGPoint {
        let delta = hypot(hand.x, hand.y) > 400 ? CGPoint.zero : hand
        return CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
    }
}

/** The enemy chosen for one attack: its vision track, the click point in screen points, the lead applied for its motion, the click's distance below the bar (frame px), the body height used and the click depth below the head (units), probe = a deeper click that measures the body. */
struct AttackTarget {
    let track: EnemyTrack
    var point: CGPoint
    let lead: CGPoint
    var offsetY: Double
    var height = 0.0
    var depth = 0.0
    var probe = false
}

/** Attack/move state machine over the vision tracks: attacks the chosen enemy whenever the attack timer allows, move-clicks on the kiting cadence otherwise. */
final class Orbwalker: @unchecked Sendable {
    let settings: Settings
    let live: LiveClient
    let game: GameSession
    let vision: Vision
    let aim: Autoaim
    let combo = ComboEngine()

    private var nextMoveMs = 0.0
    private var lastSnapshotMs = 0.0
    private var lastNoTargetLogMs = -1e9
    private var lastStaleLogMs = -1e9
    private var lastOutOfRangeLogMs = -1e9
    private var lastRecordMs = -1e9
    private var lastNoTargetRecordMs = -1e9
    private var lastMissRecordMs = -1e9
    private var lastSuspectMs = -1e9
    private var lastTimerCheckMs = -1e9
    private var recordedChampions: Set<String> = []
    private var castLockUntilMs = 0.0
    private var castWatch: (slot: String, pressedMs: Double, learnable: Bool)?
    private var activationStartMs = 0.0
    private var activationPressedMs = -1e9
    private var lastPanLogMs = -1e9
    private var lastPhantomLogMs = -1e9
    private let heldKeys = NSLock()
    private var rangeKeyHeld = false
    private var championKeyHeld = false
    private var championHeldViaMouse = false
    private var targetID = 0
    private var pendingClickMs = 0.0
    private var lastClickMs = 0.0
    private var lastRefusedRecordMs = -1e9
    private var previousClickMs = 0.0
    private var pendingTargetID = 0
    private var pendingFillAtClick = 0
    private var attackConfirmText = ""
    private var attackConfirmedMs = 0.0
    private var moveLogPendingMs = 0.0
    /** One armed click waiting for its target's bar to drop; `bestFill` is the lowest fill seen from `fromMs` (this click's own windup) on, so neither a one-pixel hit nor the previous attack's damage can decide it. */
    private struct MissCheck {
        let id: Int, fillAtClick: Int, clickedMs: Double, fromMs: Double, text: String, champion: String, depth: Double
        var bestFill: Int
        var seen = false
    }
    private var missChecks: [MissCheck] = []
    private let bodies = BodyLearner()
    /** Write-back of a learned in-game height factor for a champion. */
    var heightLearned: (String, Double) -> Void = { _, _ in }
    private var lastSkipLogMs: [String: Double] = [:]
    private var comboArmed = false
    private var comboFresh = false
    private var comboTargetID = 0
    private var comboIndex = -1
    private let resetLock = NSLock()
    private var resetPending = false
    private var manualCastPending: (slot: String, pressedMs: Double)?
    private var helicopterKeyWasDown = false
    private var helicopterAngle = 0.0
    private var lastSpinMs = 0.0
    private var lastKills = -1
    private var emoteDueMs = 0.0

    private var waveclearHeld = false
    private var spinning = false

    /** Everything other threads read or set, under one lock: the loop publishes, the UI and the vision read, the UI pauses. */
    private struct Shared {
        var status = "starting"
        var aimAllowed = false
        var paused = false
        var activationHeld = false
        var windup = 0.0
        var windupMs = 0.0
        var attacks = 0
        var lastAttackMs = -1e9
        var target: (point: CGPoint, text: String, atMs: Double)?
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    /** Set by the UI while the panel is open or the pointer rests on a menu window: the loop clicks nothing and lets the held keys go. */
    var paused: Bool {
        get { shared.withLock { $0.paused } }
        set { shared.withLock { $0.paused = newValue } }
    }

    private(set) var activationHeld: Bool {
        get { shared.withLock { $0.activationHeld } }
        set { shared.withLock { $0.activationHeld = newValue } }
    }

    private(set) var currentWindup: Double {
        get { shared.withLock { $0.windup } }
        set { shared.withLock { $0.windup = newValue } }
    }

    private(set) var currentWindupMs: Double {
        get { shared.withLock { $0.windupMs } }
        set { shared.withLock { $0.windupMs = newValue } }
    }

    private(set) var attacks: Int {
        get { shared.withLock { $0.attacks } }
        set { shared.withLock { $0.attacks = newValue } }
    }

    private var lastAttackMs: Double {
        get { shared.withLock { $0.lastAttackMs } }
        set { shared.withLock { $0.lastAttackMs = newValue } }
    }

    /** Click point of the enemy chosen in the last 400 ms, in screen points, for the overlay marker. */
    var currentTarget: CGPoint? {
        currentTargetInfo?.point
    }

    /** The chosen enemy's click point and identity text ("Cho'Gath lvl 6 via name") while fresh. */
    var currentTargetInfo: (point: CGPoint, text: String)? {
        shared.withLock { $0.target.flatMap { nowMs() - $0.atMs < 400 ? ($0.point, $0.text) : nil } }
    }

    /** Attack cycle for the HUD: ms since the last attack, the period 1/AS and the windup length. */
    var attackTimer: (elapsedMs: Double, periodMs: Double, windupMs: Double)? {
        let speed = live.snapshot.attackSpeed
        guard speed > 0, lastAttackMs > 0 else { return nil }
        return (nowMs() - lastAttackMs, 1000 / speed, currentWindupMs)
    }

    var statusText: String {
        get { shared.withLock { $0.status } }
        set {
            let changed: Bool = shared.withLock { state in
                let changed = state.status != newValue
                state.status = newValue
                return changed
            }
            if changed { Log.info("orbwalker: \(newValue)") }
        }
    }

    init(settings: Settings, live: LiveClient, game: GameSession, vision: Vision, aim: Autoaim) {
        self.settings = settings
        self.live = live
        self.game = game
        self.vision = vision
        self.aim = aim
        aim.canAim = { [weak self] in self?.shared.withLock { $0.aimAllowed } ?? false }
        vision.motionWanted = { [weak self] in self?.activationHeld ?? false }
    }

    /** Tap-thread hook: the activation press is stamped exactly; a manual ability press feeds the cooldown estimate and the cast lockout, and an attack-resetting one lets the next attack go out immediately. */
    func keyPressed(_ code: UInt16) {
        let cfg = settings.engine
        if code == cfg.activationKeyCode {
            resetLock.withLock { activationPressedMs = nowMs() }
            return
        }
        guard let slot = cfg.abilitySlot(for: code) else { return }
        let snap = live.snapshot
        let spec = Spells.resolve(abilityID: snap.abilities[slot]?.id ?? "", champion: snap.championName, slot: slot)
        guard combo.blocker(slot: slot, spec: spec, snap: snap, hud: vision.latest.abilityReady) == nil else { return }
        combo.notePress(slot: slot, spec: spec, snap: snap)
        let resets = cfg.attackResets && ChampionResets.resets(champion: snap.championName, slot: slot)
        resetLock.withLock {
            manualCastPending = (slot, nowMs())
            if resets { resetPending = true }
        }
    }

    /** From the key press until the cast lockout ends nothing is clicked; the attack timer keeps running through it, so an attack that falls due during a cast goes out the moment the lockout ends. */
    private func beginCastLock(slot: String, spec: SpellSpec?, pressedAt: Double) {
        let lockMs = combo.castLockMs(slot: slot, spec: spec) + onTargetFloorMs(settings.engine)
        castLockUntilMs = max(castLockUntilMs, pressedAt + lockMs)
        castWatch = (slot, pressedAt, spec?.cooldown.contains(where: { $0 > 0 }) == true)
        pendingClickMs = 0
        nextMoveMs = castLockUntilMs + 20
    }

    /** Learns the real cast lockout from the HUD icon going dark, and reports a press the icon never answered. */
    private func observeCast(_ vis: VisionSnapshot) {
        guard let watch = castWatch else { return }
        if vis.atMs - watch.pressedMs > 1600 {
            castWatch = nil
            if vis.abilityReady[watch.slot] == true {
                Log.info("cast \(watch.slot) did nothing: the icon stayed ready, so the game refused it")
                if nowMs() - lastRefusedRecordMs > 60000 {
                    lastRefusedRecordMs = nowMs()
                    vision.requestRecord("refused-\(Self.stamp())-\(watch.slot)")
                }
            }
            return
        }
        guard vis.frameMs > watch.pressedMs + 60, vis.abilityReady[watch.slot] == false else { return }
        let observed = vis.frameMs - watch.pressedMs
        if watch.learnable { combo.recordObservedLock(slot: watch.slot, ms: observed) }
        Log.info("cast \(watch.slot): HUD went on cooldown \(Int(observed)) ms after the key press" + (watch.learnable ? "" : "; not learned, the spell has no cooldown so the icon tracks charges, not the cast"))
        castWatch = nil
    }

    func start() {
        let thread = Thread {
            Log.info("orbwalker thread realtime policy: \(makeCurrentThreadRealtime(periodMs: 4, computationMs: 1) ? "on" : "off")")
            self.loop()
        }
        thread.name = "orbwalker"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /** Lets go of the Show Range and champion-only binds this process holds; safe from any thread. */
    func releaseHeldKeys() {
        let cfg = settings.engine
        heldKeys.withLock {
            if rangeKeyHeld {
                Input.key(cfg.attackRangeKeyCode, down: false)
                rangeKeyHeld = false
            }
            if championKeyHeld {
                if championHeldViaMouse { Input.middleMouse(down: false) } else { Input.key(cfg.championOnlyKeyCode, down: false) }
                championKeyHeld = false
            }
        }
    }

    /** Holds the Show Range and champion-only binds while the orbwalker is active. */
    private func holdKeys(_ cfg: EngineSettings) {
        heldKeys.withLock {
            if cfg.showAttackRange && !rangeKeyHeld {
                Input.key(cfg.attackRangeKeyCode, down: true)
                rangeKeyHeld = true
            }
            if cfg.attackChampionOnly && !championKeyHeld {
                championHeldViaMouse = cfg.championOnlyMiddleMouse
                if championHeldViaMouse { Input.middleMouse(down: true) } else { Input.key(cfg.championOnlyKeyCode, down: true) }
                championKeyHeld = true
            }
        }
    }

    private func loop() {
        while true {
            let snap = live.snapshot
            let cfg = settings.engine
            let held = Input.isKeyDown(cfg.activationKeyCode)
            if held && !activationHeld {
                let pressed = resetLock.withLock { activationPressedMs }
                activationStartMs = nowMs() - pressed < 300 ? pressed : nowMs()
                vision.suspendTracking(until: activationStartMs + Double(cfg.activationDelayMs))
            }
            activationHeld = held
            if let blocker = blocker(for: snap) {
                statusText = blocker
                shared.withLock { $0.aimAllowed = false }
                releaseHeldKeys()
                sleepMs(20)
                continue
            }
            shared.withLock { $0.aimAllowed = true }
            game.capture.setRate(cfg.captureFps)
            currentWindup = cfg.windup(for: snap.championName)
            currentWindupMs = cfg.windupMs(for: snap.championName, attackSpeed: snap.attackSpeed)
            if let plan = aim.takePending() {
                performAim(plan, cfg)
                continue
            }
            handleEmote(snap, cfg)
            waveclearHeld = cfg.waveclearKeyCode != KeyNames.none && Input.isKeyDown(cfg.waveclearKeyCode)
            if waveclearHeld {
                statusText = "WAVECLEAR (attack-move)"
                releaseHeldKeys()
                spinning = false
                comboArmed = false
                waveClear(snap, cfg)
                continue
            }
            if toggleHelicopter(cfg) {
                statusText = "HELICOPTER"
                releaseHeldKeys()
                spin(cfg)
                continue
            }
            guard activationHeld else {
                statusText = "ready, hold \(KeyNames.name(cfg.activationKeyCode))"
                releaseHeldKeys()
                comboArmed = false
                pendingClickMs = 0
                nextMoveMs = 0
                sleepMs(4)
                continue
            }
            statusText = "ACTIVE"
            checkTimers()
            holdKeys(cfg)
            step(snap, cfg)
        }
    }

    /** Every 30 s of activity a helper thread measures how much the system stretches a 3 ms timer wait (hot paths never use timers). */
    private func checkTimers() {
        guard nowMs() - lastTimerCheckMs > 30000 else { return }
        lastTimerCheckMs = nowMs()
        Thread {
            var worst = 0.0
            for _ in 0..<5 {
                let started = nowMs()
                sleepMs(3)
                worst = max(worst, nowMs() - started)
            }
            Log.info("timer check: worst 3 ms timer wait \(Int(worst)) ms (hot paths spin, so this is informational)")
        }.start()
    }

    private func blocker(for snap: PlayerSnapshot) -> String? {
        if paused { return "paused (menu open)" }
        if !snap.connected { return "waiting for the Live Client API (not in a match)" }
        let dataAge = min(live.ageMs, 99999)
        if dataAge > 1000 { return "Live Client API stale (\(Int(dataAge)) ms), not attacking" }
        if snap.isDead { return "champion is dead" }
        if snap.attackSpeed <= 0 { return "API reports no attack speed" }
        if !game.capture.isRunning { return "game window not found / capture not running" }
        if !game.isFocused { return "game is not in front" }
        return nil
    }

    /** One tick: nothing during the activation delay (LoL centres the camera); when the attack timer allows, attack the target seen in the newest frame; once the attack is confirmed done, cast the combo step and move-click on the kiting cadence. */
    private func step(_ snap: PlayerSnapshot, _ cfg: EngineSettings) {
        let now = nowMs()
        let (reset, manual) = resetLock.withLock { () -> (Bool, (slot: String, pressedMs: Double)?) in
            let pair = (resetPending, manualCastPending)
            resetPending = false
            manualCastPending = nil
            return pair
        }
        if let manual, now - manual.pressedMs < 500 {
            let spec = Spells.resolve(abilityID: snap.abilities[manual.slot]?.id ?? "", champion: snap.championName, slot: manual.slot)
            beginCastLock(slot: manual.slot, spec: spec, pressedAt: manual.pressedMs)
            Log.info("manual \(manual.slot): \(spec?.name ?? manual.slot) pressed by hand, cast lock \(Int(combo.castLockMs(slot: manual.slot, spec: spec))) ms")
        }
        if reset {
            lastAttackMs = -1e9
            pendingClickMs = 0
            nextMoveMs = now
        }
        if now < activationStartMs + Double(cfg.activationDelayMs) {
            lastSnapshotMs = vision.waitForFresh(after: lastSnapshotMs, maxMs: 6).atMs
            return
        }
        if pendingClickMs > 0 { confirmAttack(now, cfg) }
        if !missChecks.isEmpty {
            let vis = vision.latest
            for index in missChecks.indices {
                guard now >= missChecks[index].fromMs, let track = vis.enemies.first(where: { $0.id == missChecks[index].id }), track.fill > 0, vis.atMs - track.lastSeenMs < 300 else { continue }
                missChecks[index].bestFill = min(missChecks[index].bestFill, track.fill)
                missChecks[index].seen = true
            }
            while let index = missChecks.firstIndex(where: { now >= $0.clickedMs + 800 }) {
                resolveMissCheck(missChecks.remove(at: index), now: now)
            }
        }
        if castWatch != nil { observeCast(vision.latest) }
        if now < castLockUntilMs {
            lastSnapshotMs = vision.waitForFresh(after: lastSnapshotMs, maxMs: min(6, max(1, Int(castLockUntilMs - now)))).atMs
            return
        }
        let attackDue = lastAttackMs + 1000.0 / snap.attackSpeed
        if now >= attackDue {
            let vis = vision.waitForFresh(after: lastSnapshotMs, maxMs: Int(max(0, min(12, nextMoveMs - now))))
            lastSnapshotMs = vis.atMs
            let frameAge = nowMs() - vis.frameMs
            if frameAge > 100 {
                if vis.frameMs > 0, now - lastStaleLogMs > 2000 {
                    lastStaleLogMs = now
                    Log.warn("no fresh frame for \(Int(frameAge)) ms, not attacking")
                }
            } else if let target = chooseTarget(vis, range: snap.attackRange, cfg: cfg) {
                if cfg.attackMode == .attackMove { attackMove(target, cfg) } else { clickAttack(target, cfg, frameAge: Int(frameAge)) }
                return
            } else if now - lastNoTargetLogMs > 5000 {
                lastNoTargetLogMs = now
                logNoTarget(vis, cfg)
            }
        }
        if comboArmed, cfg.combos.enabled, pendingClickMs == 0 {
            let fresh = comboFresh
            comboFresh = false
            let trigger = fresh ? attackConfirmText : "between attacks, \(Int(attackDue - now)) ms to the next"
            if runCombo(snap, cfg, trigger: trigger, slackMs: attackDue - now, fresh: fresh) {
                comboArmed = false
                return
            }
        }
        if pendingClickMs == 0, now >= nextMoveMs {
            let clicked = moveClick(cfg)
            if clicked, moveLogPendingMs > 0 {
                let real = max(0, currentWindupMs - Double(cfg.extraWindupMs))
                Log.info("move +\(Int(now - moveLogPendingMs)) ms after the attack click (confirmed +\(Int(attackConfirmedMs - moveLogPendingMs)) ms: \(attackConfirmText); windup \(Int(currentWindupMs)) ms, real \(Int(real)) ms)")
                moveLogPendingMs = 0
            }
            nextMoveMs = now + Double(Int.random(in: min(cfg.moveClickMinMs, cfg.moveClickMaxMs)...max(cfg.moveClickMinMs, cfg.moveClickMaxMs)))
            return
        }
        let wake = pendingClickMs > 0 ? now + 3 : min(nextMoveMs, max(attackDue, now + 4))
        lastSnapshotMs = vision.waitForFresh(after: lastSnapshotMs, maxMs: min(6, max(1, Int(wake - now)))).atMs
    }

    /** The attack counts as done once the target's bar dropped, the champion stood through a whole windup (ground motion with a locked camera), or the estimate ran out; moves and combo steps wait for it. */
    private func confirmAttack(_ now: Double, _ cfg: EngineSettings) {
        let vis = vision.latest
        let windupReal = max(0, currentWindupMs - Double(cfg.extraWindupMs))
        let latency = Double(cfg.attackLatencyMs)
        var startedAt = max(pendingClickMs, castLockUntilMs) + latency
        var text: String?
        if pendingFillAtClick > 0, now >= startedAt + windupReal, let track = vis.enemies.first(where: { $0.id == pendingTargetID }), track.lastSeenMs == vis.atMs, track.fill <= pendingFillAtClick - 2 {
            text = "hit +\(Int(now - pendingClickMs)) ms"
        } else if vis.cameraLocked, now - vis.flowMs < 60 {
            startedAt = AttackTiming.attackStart(clickStart: startedAt, motionMs: vis.motionMs, bufferMs: Double(cfg.extraWindupMs))
            if now >= startedAt + windupReal + 15 { text = "stood still from +\(Int(startedAt - pendingClickMs)) ms" }
        } else if now >= pendingClickMs + currentWindupMs + latency {
            text = "windup estimate, ground not measured"
        }
        if text == nil, now >= pendingClickMs + max(600, currentWindupMs + 450) {
            text = "unconfirmed after \(Int(now - pendingClickMs)) ms"
            comboArmed = false
        }
        guard let text else { return }
        let cycleMs = 1000 / max(0.1, live.snapshot.attackSpeed)
        if now - pendingClickMs > max(200, 0.6 * cycleMs) {
            Log.info("attack confirmation slow: \(text) (\(Int(now - pendingClickMs)) ms after the click, \(Int(100 * (now - pendingClickMs) / cycleMs)) % of the \(Int(cycleMs)) ms cycle)")
        }
        lastAttackMs = max(lastAttackMs, max(pendingClickMs, castLockUntilMs))
        attackConfirmText = text
        attackConfirmedMs = now
        pendingClickMs = 0
        nextMoveMs = now
    }

    /** Judges one armed click from the lowest bar fill seen since it: any drop is a hit, and a verdict is only reached while the target stayed in view. */
    private func resolveMissCheck(_ check: MissCheck, now: Double) {
        guard check.seen else { return }
        let hit = AttackTiming.didHit(bestFill: check.bestFill, fillAtClick: check.fillAtClick)
        if hit {
            Log.info("attack #\(check.id): bar \(check.fillAtClick) -> \(check.bestFill) px (drop \(check.fillAtClick - check.bestFill)) in \(Int(now - check.clickedMs)) ms, clicked \(Int(check.depth)) u below the head")
        }
        if !hit {
            Log.warn("attack #\(check.id): the bar never moved in \(Int(now - check.clickedMs)) ms after the click, probable miss (\(check.text))")
            if now - lastMissRecordMs > 30000 {
                lastMissRecordMs = now
                vision.requestRecord("miss-\(Self.stamp())-\(check.id)")
            }
        }
        guard !check.champion.isEmpty, check.champion != ChampionModels.dummyKey, check.fillAtClick >= 12, let model = ChampionModels.table[check.champion],
              let change = bodies.record(champion: check.champion, depth: check.depth, hit: hit) else { return }
        Log.info("body of \(model.name): \(change.note) (mesh \(Int(model.meshHeight)) u)")
        if change.settled { heightLearned(check.champion, (change.height / model.meshHeight * 100).rounded() / 100) }
    }

    /** Casts the next enabled ability that is ready: attack resets right after a confirmed attack, the others timed so the cast ends when the next attack is due (or right after the attack when the cast fits before it); true when something was cast. */
    private func runCombo(_ snap: PlayerSnapshot, _ cfg: EngineSettings, trigger: String, slackMs: Double, fresh: Bool) -> Bool {
        let steps = cfg.combo(for: snap.championName).steps.filter { $0.enabled }
        guard !steps.isEmpty, slackMs > -600 else { return false }
        let hud = vision.latest.abilityReady
        var cast = false
        for offset in 0..<steps.count {
            let index = (comboIndex + 1 + offset) % steps.count
            let step = steps[index]
            let spec = Spells.resolve(abilityID: snap.abilities[step.slot]?.id ?? "", champion: snap.championName, slot: step.slot)
            guard combo.blocker(slot: step.slot, spec: spec, snap: snap, hud: hud, ignoreCooldowns: cfg.combos.ignoreCooldowns) == nil else { continue }
            if hud[step.slot] == nil, spec?.cooldown.contains(where: { $0 > 0 }) != true, !cfg.combos.ignoreCooldowns {
                logSkip(step.slot, "no HUD icon reading and the spell has no cooldown to estimate")
                continue
            }
            let castMs = combo.castLockMs(slot: step.slot, spec: spec)
            let deliveryMs = onTargetFloorMs(cfg) + (step.aim == .target ? Double(cfg.aim.settleMs) + 2 * onTargetFloorMs(cfg) : 0)
            let resets = cfg.attackResets && ChampionResets.resets(champion: snap.championName, slot: step.slot)
            if resets, !fresh {
                logSkip(step.slot, "attack reset waits for the next confirmed attack")
                continue
            }
            if !resets {
                if cfg.combos.castBeforeAttack {
                    guard AttackTiming.castFits(slackMs: slackMs, castMs: castMs + deliveryMs, overrunMs: cfg.combos.neverDelayAttack ? 0 : AttackTiming.castOverrunMs) else { continue }
                } else {
                    guard slackMs >= castMs + deliveryMs + 200 else { continue }
                }
            }
            let ownCooldownMs = combo.fullCooldownMs(slot: step.slot, spec: spec, snap: snap)
            let repressMs = ownCooldownMs > 0 ? min(max(castMs + 500, 1800), ownCooldownMs) : max(castMs + 500, 1800)
            if let since = combo.sinceCastMs(slot: step.slot), since < repressMs { continue }
            if hud[step.slot] == true, combo.cooldownRemainingMs(slot: step.slot, spec: spec, snap: snap) > 1500, nowMs() - lastSuspectMs > 20000 {
                lastSuspectMs = nowMs()
                Log.warn("HUD says \(step.slot) ready while the estimate has \(Int(combo.cooldownRemainingMs(slot: step.slot, spec: spec, snap: snap) / 1000)) s left; \(vision.latest.hudText)")
                vision.requestRecord("hud-suspect-\(Self.stamp())-\(step.slot)")
            }
            let keyCode = cfg.aimKey(for: step.slot)
            var text: String
            if step.aim == .target {
                var reason = ""
                guard let plan = aim.makePlan(slot: step.slot, keyCode: keyCode, cfg: cfg, lockedEnemyID: comboTargetID, reason: &reason) else {
                    logSkip(step.slot, reason)
                    continue
                }
                performAim(plan, cfg, hold: false)
                text = "\(spec?.name ?? step.slot) → \(Int(plan.distanceUnits)) u"
            } else if step.aim == .cursor, let dash = dashDestination(spec: spec, snap: snap, cfg: cfg) {
                if let sideways = dash.sideways, let spec {
                    let plan = AimPlan(slot: step.slot, keyCode: keyCode, spec: spec, targeting: .location, point: sideways, targetPx: .zero, predictedPx: .zero,
                                       enemyID: comboTargetID, predictedMs: 0, distanceUnits: 0, castMode: cfg.aim.castMode, createdMs: nowMs())
                    performAim(plan, cfg, hold: false)
                    text = "\(spec.name) sideways (the cursor would leave range)"
                } else {
                    let pressedAt = nowMs()
                    pressKey(keyCode, cfg: cfg, click: cfg.aim.castMode == .normal)
                    beginCastLock(slot: step.slot, spec: spec, pressedAt: pressedAt)
                    text = "\(spec?.name ?? step.slot) toward the cursor"
                }
            } else if step.aim == .cursor {
                logSkip(step.slot, "no dash direction keeps the target in range")
                continue
            } else {
                let pressedAt = nowMs()
                pressKey(keyCode, cfg: cfg, click: false)
                beginCastLock(slot: step.slot, spec: spec, pressedAt: pressedAt)
                text = "\(spec?.name ?? step.slot) without aiming"
            }
            if resets {
                lastAttackMs = castLockUntilMs - 1000 / max(0.1, snap.attackSpeed)
                text += ", reset AA"
            }
            combo.markCast(slot: step.slot, text: text)
            comboIndex = index
            Log.info("combo \(step.slot): \(text) (\(trigger)); \(vision.latest.hudText)")
            cast = true
            if cfg.combos.oneAbilityPerAttack { return true }
            spinUntil(castLockUntilMs)
        }
        return cast
    }

    /** A skipped combo step is logged at most once per two seconds per slot; the combo re-evaluates every tick. */
    private func logSkip(_ slot: String, _ reason: String) {
        let now = nowMs()
        guard now - (lastSkipLogMs[slot] ?? -1e9) > 2000 else { return }
        lastSkipLogMs[slot] = now
        Log.info("combo \(slot) skipped: \(reason)")
    }

    /** Where a dash may go, in ground units through the projection: toward the cursor when that keeps the attacked enemy in attack reach, else sideways on the cursor's side; nil when no direction keeps the target. */
    private func dashDestination(spec: SpellSpec?, snap: PlayerSnapshot, cfg: EngineSettings) -> (sideways: CGPoint?, viaCursor: Bool)? {
        guard let spec, spec.range > 0, spec.range < 2000 else { return (nil, true) }
        let vis = vision.latest
        guard let projection = vis.projection, let selfPx = vis.selfPoint(cfg: cfg), nowMs() - vis.atMs < 200,
              let track = vis.enemies.first(where: { $0.id == comboTargetID }), vis.frameWidth > 0 else { return (nil, true) }
        let gSelf = projection.ground(selfPx)
        let gTarget = projection.ground(vis.feetPoint(track, cfg: cfg))
        let gCursor = projection.ground(toFrame(Input.mousePosition(), vis: vis))
        let limit = GroundProjection.reach(attackRange: snap.attackRange) * (1 + cfg.attackRangeTolerance / 100)
        func distanceAfter(_ ux: Double, _ uz: Double, _ travel: Double) -> Double {
            hypot(gSelf.x + ux * travel - gTarget.x, gSelf.y + uz * travel - gTarget.y)
        }
        let cx = gCursor.x - gSelf.x, cz = gCursor.y - gSelf.y
        let cursorLength = hypot(cx, cz)
        if cursorLength > 1, distanceAfter(cx / cursorLength, cz / cursorLength, min(spec.range, cursorLength)) <= limit { return (nil, true) }
        let tx = gTarget.x - gSelf.x, tz = gTarget.y - gSelf.y
        let targetLength = hypot(tx, tz)
        guard targetLength > 1 else { return nil }
        let side = (cx * -tz + cz * tx) >= 0 ? 1.0 : -1.0
        for sign in [side, -side] {
            let ux = -tz / targetLength * sign, uz = tx / targetLength * sign
            if distanceAfter(ux, uz, spec.range) <= limit {
                return (toPoints(projection.screen(CGPoint(x: gSelf.x + ux * spec.range, y: gSelf.y + uz * spec.range)), vis: vis), false)
            }
        }
        return nil
    }

    /** Presses an ability key where the cursor already is; normal cast mode confirms a directional spell with a left click. */
    private func pressKey(_ keyCode: UInt16, cfg: EngineSettings, click: Bool) {
        Input.key(keyCode, down: true)
        spinMs(cfg.aim.holdMs)
        Input.key(keyCode, down: false)
        guard click else { return }
        waitForFrames(1, maxMs: 30)
        Input.leftClick(at: Input.mousePosition())
    }

    /** Starts waiting for the attack to be confirmed: no move-clicks until then, then the combo step. */
    private func armAttack(_ target: AttackTarget, at clickedAt: Double, cfg: EngineSettings) {
        previousClickMs = lastClickMs
        lastClickMs = clickedAt
        lastAttackMs = clickedAt
        pendingClickMs = clickedAt
        moveLogPendingMs = clickedAt
        pendingTargetID = target.track.id
        pendingFillAtClick = target.track.fill
        nextMoveMs = .infinity
        comboArmed = cfg.combos.enabled
        comboFresh = true
        comboTargetID = target.track.id
    }

    /** Enemies seen in this frame and at least once before, inside the attack range; the current target stays unless the mode clearly prefers another. */
    private func chooseTarget(_ vis: VisionSnapshot, range: Double, cfg: EngineSettings) -> AttackTarget? {
        let frame = vis.windowFrame.width > 0 ? vis.windowFrame : game.capture.windowFrame
        guard vis.frameWidth > 0, vis.frameHeight > 0, frame.width > 0 else { return nil }
        func toPoints(_ p: CGPoint) -> CGPoint { self.toPoints(p, vis: vis) }
        let fresh = vis.enemies.filter { vis.atMs - $0.lastSeenMs <= 60 && $0.sightings >= 2 }
        let panLimit = 1.2 * Double(vis.frameWidth) / 1920
        let leadMs = min(60, max(0, nowMs() - vis.frameMs)) + 12
        let leadCap = 30 * Double(vis.frameWidth) / 1920
        func learnable(_ track: EnemyTrack) -> Bool { !track.champion.isEmpty && track.champion != ChampionModels.dummyKey && vis.model(track) != nil }
        func bodyHeight(_ track: EnemyTrack) -> Double? {
            guard learnable(track) else { return nil }
            return bodies.height(champion: track.champion, prior: vis.height(track, cfg: cfg), known: cfg.heightFactors[track.champion] != nil)
        }
        let ownGuardX = 140 * Double(vis.frameWidth) / 1920, ownGuardY = 70 * Double(vis.frameHeight) / 1080
        func onOwnBar(_ track: EnemyTrack) -> Bool {
            guard let own = vis.selfBar, vis.atMs - vis.selfSeenMs < 1500 else { return false }
            return abs(track.centerX - (Double(own.x) + Double(own.width) / 2)) < ownGuardX && abs(track.y - Double(own.y)) < ownGuardY
        }
        let phantoms = fresh.filter { !$0.everFilled && onOwnBar($0) }
        if let phantom = phantoms.first, nowMs() - lastPhantomLogMs > 5000 {
            lastPhantomLogMs = nowMs()
            Log.info("ignoring an empty bar on my own champion (#\(phantom.id) at (\(Int(phantom.x)), \(Int(phantom.y))), seen \(phantom.sightings)x): a debuff stack counter, not a unit")
            vision.requestRecord("phantom-\(Self.stamp())")
        }
        var candidates = fresh.filter { $0.stepSpeed <= panLimit && !($0.everFilled == false && onOwnBar($0)) }.map { track -> AttackTarget in
            let height = bodyHeight(track)
            let base = vis.targetPoint(track, cfg: cfg, height: height)
            let lead = CGPoint(x: max(-leadCap, min(leadCap, track.vx * leadMs)), y: max(-leadCap, min(leadCap, track.vy * leadMs)))
            return AttackTarget(track: track, point: toPoints(CGPoint(x: base.x + lead.x, y: base.y + lead.y)), lead: lead, offsetY: base.y - track.y, height: height ?? 0)
        }
        if candidates.isEmpty, !fresh.isEmpty {
            if nowMs() - lastPanLogMs > 2000 {
                lastPanLogMs = nowMs()
                Log.info("waiting: enemies move \(String(format: "%.1f", (fresh.map { $0.stepSpeed }.max() ?? 0) / Double(vis.frameWidth) * 1920)) px/ms on screen (camera pan or dash), limit 1.2")
            }
            return nil
        }
        guard !candidates.isEmpty else { return nil }
        let selfPt = vis.selfPoint(cfg: cfg).map(toPoints)
        if cfg.attackOnlyInRange, let selfPt {
            let limit = GroundProjection.reach(attackRange: range) * (1 + cfg.attackRangeTolerance / 100)
            func distance(_ target: AttackTarget) -> Double { units(toPoints(vis.feetPoint(target.track, cfg: cfg, height: target.height > 0 ? target.height : nil)), selfPt, vis: vis) }
            let inRange = candidates.filter { distance($0) <= limit }
            if inRange.isEmpty {
                if nowMs() - lastOutOfRangeLogMs > 3000 {
                    lastOutOfRangeLogMs = nowMs()
                    let nearest = candidates.map(distance).min() ?? 0
                    Log.info("target out of range: nearest \(Int(nearest)) units feet to feet, limit \(Int(limit)) (attack range \(Int(range)) + 2×65 edge range, tolerance \(Int(cfg.attackRangeTolerance)) %); \(vis.rangeText)")
                }
                return nil
            }
            candidates = inRange
        }
        let anchor = selfPt ?? CGPoint(x: frame.midX, y: frame.midY)
        let score: (AttackTarget) -> Double
        let dummyPenalty: (AttackTarget) -> Double = { $0.track.champion == ChampionModels.dummyKey ? 1e6 : 0 }
        switch cfg.targetMode {
        case .lowest:
            score = { $0.track.fillRatio + dummyPenalty($0) }
        case .cursor:
            let cursor = Input.mousePosition()
            score = { hypot($0.point.x - cursor.x, $0.point.y - cursor.y) + dummyPenalty($0) }
        case .center:
            score = { hypot($0.point.x - anchor.x, $0.point.y - anchor.y) + dummyPenalty($0) }
        }
        guard let best = candidates.min(by: { score($0) < score($1) }) else { return nil }
        var chosen = best
        if cfg.stickyTarget, let current = candidates.first(where: { $0.track.id == targetID }), current.track.id != best.track.id {
            let keep = cfg.targetMode == .lowest ? score(current) <= score(best) + 0.15 : score(current) <= score(best) * 1.3
            if keep { chosen = current }
        }
        targetID = chosen.track.id
        if chosen.height > 0 {
            let click = bodies.clickDepth(champion: chosen.track.champion, prior: vis.height(chosen.track, cfg: cfg), known: cfg.heightFactors[chosen.track.champion] != nil, fraction: 1 - cfg.clickHeight / 100)
            let base = vis.targetPoint(chosen.track, cfg: cfg, height: chosen.height, depth: click.depth)
            chosen.point = toPoints(CGPoint(x: base.x + chosen.lead.x, y: base.y + chosen.lead.y))
            chosen.offsetY = base.y - chosen.track.y
            chosen.depth = click.depth
            chosen.probe = click.probe
        }
        let marker = (point: chosen.point, text: chosen.track.identity, atMs: nowMs())
        shared.withLock { $0.target = marker }
        return chosen
    }

    /** Move-click on the cursor unless it sits inside the hold zone around the champion. */
    @discardableResult
    private func moveClick(_ cfg: EngineSettings) -> Bool {
        let cursor = Input.mousePosition()
        if cfg.holdRadius > 0, let selfPt = selfPoint(cfg: cfg) {
            let radius = cfg.holdRadius * game.capture.windowFrame.width / 1920
            if hypot(cursor.x - selfPt.x, cursor.y - selfPt.y) <= radius { return false }
        }
        Input.rightClick(at: cursor)
        return true
    }

    /** Waveclear: full kiting cadence, but every attack is an attack-move at the cursor so the game hits the nearest unit; no target detection and no combos. */
    private func waveClear(_ snap: PlayerSnapshot, _ cfg: EngineSettings) {
        let now = nowMs()
        if pendingClickMs > 0 { confirmAttack(now, cfg) }
        let attackDue = lastAttackMs + 1000.0 / snap.attackSpeed
        if pendingClickMs == 0, now >= attackDue {
            let cursor = Input.mousePosition()
            guard cursorInSafeArea(cursor) else {
                if now - lastNoTargetLogMs > 1000 {
                    lastNoTargetLogMs = now
                    Log.warn("waveclear skipped: cursor over HUD/minimap at (\(Int(cursor.x)), \(Int(cursor.y)))")
                }
                sleepMs(8)
                return
            }
            Input.key(cfg.attackMoveKeyCode, down: true)
            spinMs(6)
            Input.key(cfg.attackMoveKeyCode, down: false)
            if cfg.attackMoveClick {
                spinMs(6)
                Input.leftClick(at: cursor)
            }
            let pressedAt = nowMs()
            lastAttackMs = pressedAt
            pendingClickMs = pressedAt
            pendingTargetID = -1
            pendingFillAtClick = 0
            nextMoveMs = .infinity
            moveLogPendingMs = 0
            attacks += 1
            Log.info("waveclear: attack-move at (\(Int(cursor.x)), \(Int(cursor.y))), key \(KeyNames.name(cfg.attackMoveKeyCode)); windup \(Int(currentWindupMs)) ms")
            return
        }
        if pendingClickMs == 0, now >= nextMoveMs {
            moveClick(cfg)
            nextMoveMs = now + Double(Int.random(in: min(cfg.moveClickMinMs, cfg.moveClickMaxMs)...max(cfg.moveClickMinMs, cfg.moveClickMaxMs)))
            return
        }
        let wake = pendingClickMs > 0 ? now + 3 : min(nextMoveMs, max(attackDue, now + 4))
        lastSnapshotMs = vision.waitForFresh(after: lastSnapshotMs, maxMs: min(6, max(1, Int(wake - now)))).atMs
    }

    /** Own champion's ground point in screen points from the vision, when it saw a frame in the last 200 ms. */
    private func selfPoint(cfg: EngineSettings) -> CGPoint? {
        let vis = vision.latest
        guard vis.frameWidth > 0, nowMs() - vis.atMs < 200, let px = vis.selfPoint(cfg: cfg) else { return nil }
        return toPoints(px, vis: vis)
    }

    /** Distance in game units between two screen points through the vision's ground projection (perspective and elevation from the range ring); infinite before the first frame. */
    private func units(_ a: CGPoint, _ b: CGPoint, vis: VisionSnapshot) -> Double {
        guard let projection = vis.projection, vis.frameWidth > 0, game.capture.windowFrame.width > 0 else { return .infinity }
        return projection.units(toFrame(a, vis: vis), toFrame(b, vis: vis))
    }

    private func toFrame(_ p: CGPoint, vis: VisionSnapshot) -> CGPoint {
        let frame = vis.windowFrame.width > 0 ? vis.windowFrame : game.capture.windowFrame
        return CGPoint(x: (p.x - frame.minX) * Double(vis.frameWidth) / frame.width, y: (p.y - frame.minY) * Double(vis.frameHeight) / frame.height)
    }

    private func toPoints(_ p: CGPoint, vis: VisionSnapshot) -> CGPoint {
        let frame = vis.windowFrame.width > 0 ? vis.windowFrame : game.capture.windowFrame
        return CGPoint(x: frame.minX + p.x * frame.width / Double(vis.frameWidth), y: frame.minY + p.y * frame.height / Double(vis.frameHeight))
    }

    private func toggleHelicopter(_ cfg: EngineSettings) -> Bool {
        guard cfg.helicopterKeyCode != KeyNames.none else {
            spinning = false
            return false
        }
        let down = Input.isKeyDown(cfg.helicopterKeyCode)
        if down && !helicopterKeyWasDown {
            spinning.toggle()
            Log.info("helicopter \(spinning ? "on" : "off")")
        }
        helicopterKeyWasDown = down
        if spinning && activationHeld { spinning = false }
        return spinning
    }

    /** Fun: walks in a tight circle around the champion so the model keeps turning; the circle is laid out in ground units (a screen circle drifts up, its top is farther away than its bottom) around a point 10 units below the feet. */
    private func spin(_ cfg: EngineSettings) {
        let now = nowMs()
        guard now - lastSpinMs >= Double(max(20, cfg.helicopterIntervalMs)) else {
            lastSnapshotMs = vision.waitForFresh(after: lastSnapshotMs, maxMs: 2).atMs
            return
        }
        lastSpinMs = now
        let frame = game.capture.windowFrame
        helicopterAngle += .pi / 3
        let vis = vision.latest
        let point: CGPoint
        if let projection = vis.projection, vis.frameWidth > 0, let feet = vis.selfPoint(cfg: cfg) {
            let ground = projection.ground(feet)
            let radius = cfg.helicopterRadius * Double(vis.frameWidth) / 1920 / projection.kx
            point = toPoints(projection.screen(CGPoint(x: ground.x + cos(helicopterAngle) * radius, y: ground.y - 10 + sin(helicopterAngle) * radius)), vis: vis)
        } else {
            let center = selfPoint(cfg: cfg) ?? CGPoint(x: frame.midX, y: frame.midY + 20)
            let radius = cfg.helicopterRadius * frame.width / 1920
            point = CGPoint(x: center.x + cos(helicopterAngle) * radius, y: center.y + sin(helicopterAngle) * radius * 0.7)
        }
        let origin = Input.mousePosition()
        var hand = HandTracker(origin: origin)
        let onTarget = max(Double(cfg.clickHoldMs + cfg.clickSettleMs), onTargetFloorMs(cfg))
        let started = nowMs()
        Input.rightMouse(down: true, at: point)
        hand.posted(point)
        spinMs(cfg.clickHoldMs)
        Input.rightMouse(down: false, at: point)
        spinUntil(started + onTarget)
        hand.move(to: origin)
    }

    /** Fun: an emote shortly after each of our champion kills. */
    private func handleEmote(_ snap: PlayerSnapshot, _ cfg: EngineSettings) {
        if lastKills < 0 { lastKills = snap.kills }
        if snap.kills > lastKills {
            lastKills = snap.kills
            if cfg.emoteOnKill { emoteDueMs = nowMs() + 400 }
        }
        guard emoteDueMs > 0, nowMs() >= emoteDueMs else { return }
        emoteDueMs = 0
        if cfg.emoteCtrl { Input.key(59, down: true) }
        Input.key(cfg.emoteKeyCode, down: true)
        spinMs(6)
        Input.key(cfg.emoteKeyCode, down: false)
        if cfg.emoteCtrl { Input.key(59, down: false) }
        Log.info("emote after kill #\(snap.kills)")
    }

    /** Minimum time the cursor must sit on the target: one game frame (the game samples the cursor once per frame) plus delivery slack. */
    private func onTargetFloorMs(_ cfg: EngineSettings) -> Double {
        let fps = max(30, game.capture.fps)
        return 1000 / fps + 2
    }

    /** Right-clicks the target: cursor to the model (with a few px of human jitter), click, cursor straight back; no position query while the cursor is away. */
    private func clickAttack(_ target: AttackTarget, _ cfg: EngineSettings, frameAge: Int) {
        let origin = Input.mousePosition()
        var hand = HandTracker(origin: origin)
        let jitter = cfg.clickJitter * game.capture.windowFrame.width / 1920
        let point = CGPoint(x: target.point.x + Double.random(in: -jitter...jitter), y: target.point.y + Double.random(in: -jitter...jitter))
        let onTarget = max(Double(cfg.clickHoldMs + cfg.clickSettleMs), onTargetFloorMs(cfg))
        let started = nowMs()
        Input.rightMouse(down: true, at: point)
        let downMs = nowMs() - started
        hand.posted(point)
        spinMs(cfg.clickHoldMs)
        let upStarted = nowMs()
        Input.rightMouse(down: false, at: point)
        let clickedAt = nowMs()
        let upMs = clickedAt - upStarted
        let previousAttackMs = lastAttackMs
        armAttack(target, at: clickedAt, cfg: cfg)
        waitForFrames(1, maxMs: 25)
        spinUntil(started + onTarget)
        let backStarted = nowMs()
        hand.move(to: origin)
        let backMs = nowMs() - backStarted
        let away = nowMs() - started
        attacks += 1
        if !target.track.champion.isEmpty, target.track.champion != ChampionModels.dummyKey, recordedChampions.insert(target.track.champion).inserted {
            vision.requestRecord("champion-\(target.track.champion)-\(Self.stamp())")
        } else if nowMs() - lastRecordMs > 30000 {
            lastRecordMs = nowMs()
            vision.requestRecord("frame-\(Self.stamp())-hit-\(Int(target.track.x))-\(Int(target.track.y))")
        }
        let track = target.track
        let body = target.height > 0 ? String(format: ", %.0f u below the head of %.0f%@", target.depth, target.height, target.probe ? " (probe)" : "") : ""
        let clickText = "\(track.identity.isEmpty ? "unrecognised unit" : track.identity), bar px (\(Int(track.x)), \(Int(track.y))) fill \(track.fill)/\(track.width) -> click (\(Int(point.x)), \(Int(point.y))) pt, \(Int(target.offsetY)) px below the bar\(body), lead (\(Int(target.lead.x)), \(Int(target.lead.y))) px, \(vision.latest.projection?.source ?? "-")"
        if track.fill > 2 {
            missChecks.append(MissCheck(id: track.id, fillAtClick: track.fill, clickedMs: clickedAt, fromMs: clickedAt + currentWindupMs, text: clickText, champion: track.champion, depth: target.depth, bestFill: track.fill))
        }
        let period = 1000 / max(0.1, live.snapshot.attackSpeed)
        let chained = previousAttackMs > 0 && clickedAt - previousAttackMs < 3000
        let cadence = chained ? "; gap \(Int(clickedAt - previousAttackMs)) ms vs period \(Int(period)) ms (\(Int(clickedAt - previousAttackMs - period)) late, click to click \(Int(previousClickMs > 0 ? clickedAt - previousClickMs : 0)) ms)" : ""
        Log.info("attack #\(track.id): \(clickText); windup \(Int(currentWindupMs)) ms; cursor (\(Int(origin.x)), \(Int(origin.y))) away \(Int(away)) ms (floor \(Int(onTargetFloorMs(cfg))) ms @ \(Int(game.capture.fps)) fps, posts \(Int(downMs))/\(Int(upMs))/\(Int(backMs)) ms); frame \(frameAge) ms; scan \(Int(vision.latest.scanMicros)) us\(cadence)")
    }

    /** Presses the attack-move key (and clicks at the cursor for the default LoL bind); the cursor never moves. */
    private func attackMove(_ target: AttackTarget, _ cfg: EngineSettings) {
        let cursor = Input.mousePosition()
        if cfg.attackMoveClick && !cursorInSafeArea(cursor) {
            if nowMs() - lastNoTargetLogMs > 1000 {
                lastNoTargetLogMs = nowMs()
                Log.warn("attack-move skipped: cursor over HUD/minimap at (\(Int(cursor.x)), \(Int(cursor.y)))")
            }
            return
        }
        Input.key(cfg.attackMoveKeyCode, down: true)
        spinMs(6)
        Input.key(cfg.attackMoveKeyCode, down: false)
        if cfg.attackMoveClick {
            spinMs(6)
            Input.leftClick(at: cursor)
        }
        let pressedAt = nowMs()
        armAttack(target, at: pressedAt, cfg: cfg)
        attacks += 1
        let track = target.track
        Log.info("attack-move #\(track.id): bar px (\(Int(track.x)), \(Int(track.y))) fill \(track.fill)/\(track.width), key \(KeyNames.name(cfg.attackMoveKeyCode))\(cfg.attackMoveClick ? " + left click at (\(Int(cursor.x)), \(Int(cursor.y)))" : ""); windup \(Int(currentWindupMs)) ms")
    }

    /** Waits until the game presented `count` new frames (input is processed before each), bounded by maxMs. */
    private func waitForFrames(_ count: Int, maxMs: Int) {
        let until = nowMs() + Double(maxMs)
        var last = game.capture.lastFrameAtMs
        for _ in 0..<count {
            let remaining = Int(until - nowMs())
            guard remaining > 0, game.capture.waitForFrame(after: last, timeoutMs: remaining) else { return }
            last = game.capture.lastFrameAtMs
        }
    }

    /** Runs a spell: cursor to the aimed point, the key held as long as the finger holds it (or just tapped for combos), cursor back to where the hand is. */
    private func performAim(_ plan: AimPlan, _ cfg: EngineSettings, hold: Bool = true) {
        guard nowMs() - plan.createdMs < 250 else {
            Log.warn("aim \(plan.slot): stale plan dropped")
            return
        }
        if hold {
            pendingClickMs = 0
            comboArmed = false
        }
        let aimStarted = nowMs()
        let origin = Input.mousePosition()
        var hand = HandTracker(origin: origin)
        var current = plan
        var heldMs = 0.0
        var settledMs = 0.0
        var keyPressedAt = nowMs()
        func moveCursor(_ point: CGPoint) {
            hand.accumulate()
            hand.move(to: point)
        }
        if let second = plan.secondPoint {
            moveCursor(plan.point)
            spinMs(cfg.aim.settleMs)
            waitForFrames(2, maxMs: 40)
            Input.key(plan.keyCode, down: true)
            keyPressedAt = nowMs()
            spinMs(cfg.aim.holdMs)
            waitForFrames(2, maxMs: 40)
            moveCursor(second)
            spinMs(cfg.aim.settleMs)
            waitForFrames(2, maxMs: 40)
            Input.key(plan.keyCode, down: false)
        } else if plan.castMode == .normal {
            Input.key(plan.keyCode, down: true)
            spinMs(cfg.aim.holdMs)
            Input.key(plan.keyCode, down: false)
            waitForFrames(1, maxMs: 30)
            moveCursor(plan.point)
            spinMs(cfg.aim.settleMs)
            waitForFrames(2, maxMs: 40)
            Input.leftClick(at: plan.point)
            keyPressedAt = nowMs()
            hand.posted(plan.point)
        } else {
            moveCursor(plan.point)
            spinMs(cfg.aim.settleMs)
            waitForFrames(2, maxMs: 40)
            settledMs = nowMs() - aimStarted
            Input.key(plan.keyCode, down: true)
            let pressedAt = nowMs()
            keyPressedAt = pressedAt
            spinMs(cfg.aim.holdMs)
            waitForFrames(1, maxMs: 25)
            var lastTrackMs = nowMs()
            var reason = ""
            while hold, aim.isPhysicallyHeld(plan.keyCode), nowMs() - pressedAt < 5000, !paused {
                if nowMs() - lastTrackMs >= 16 {
                    lastTrackMs = nowMs()
                    if let updated = aim.makePlan(slot: plan.slot, keyCode: plan.keyCode, cfg: cfg, lockedEnemyID: plan.enemyID, reason: &reason),
                       hypot(updated.point.x - current.point.x, updated.point.y - current.point.y) >= 1 {
                        moveCursor(updated.point)
                        current = updated
                    }
                }
                waitForFrames(1, maxMs: 4)
            }
            heldMs = nowMs() - pressedAt
            Input.key(plan.keyCode, down: false)
        }
        spinMs(cfg.aim.restoreMs)
        waitForFrames(2, maxMs: 50)
        let restored = hand.restoredPoint(from: origin)
        hand.move(to: restored)
        beginCastLock(slot: plan.slot, spec: plan.spec, pressedAt: keyPressedAt)
        let text = "\(plan.spec?.name ?? plan.slot) → \(Int(current.distanceUnits)) u" + (current.predictedMs > 0 ? ", prediction \(Int(current.predictedMs)) ms" : "")
        aim.record(slot: plan.slot, text: text)
        Log.info("aim \(plan.slot) \(plan.spec?.id ?? "?") (\(plan.targeting.rawValue), \(plan.castMode.rawValue)): target px (\(Int(current.targetPx.x)), \(Int(current.targetPx.y))) -> (\(Int(current.predictedPx.x)), \(Int(current.predictedPx.y))), \(Int(current.distanceUnits)) units, prediction \(Int(current.predictedMs)) ms; settle \(Int(settledMs)) ms, held \(Int(heldMs)) ms, total \(Int(nowMs() - aimStarted)) ms; cursor (\(Int(origin.x)), \(Int(origin.y))) -> (\(Int(current.point.x)), \(Int(current.point.y))) -> (\(Int(restored.x)), \(Int(restored.y)))")
    }

    /** True when the cursor is over the game world, not the bottom HUD or the minimap corner. */
    private func cursorInSafeArea(_ p: CGPoint) -> Bool {
        let w = game.capture.windowFrame
        guard w.width > 0 else { return true }
        let rx = (p.x - w.minX) / w.width
        let ry = (p.y - w.minY) / w.height
        if ry > 0.84 { return false }
        if rx > 0.80 && ry > 0.72 { return false }
        return true
    }

    /** What the vision sees while nothing is attackable; with no enemy at all a frame is recorded at most every 5 minutes. */
    private func logNoTarget(_ vis: VisionSnapshot, _ cfg: EngineSettings) {
        let tracked = vis.enemies.map { "#\($0.id) (\(Int($0.x)),\(Int($0.y)) \($0.fill)/\($0.width) seen \($0.sightings)x, \(Int(vis.atMs - $0.lastSeenMs)) ms ago)" }.joined(separator: " ")
        let selfText = vis.selfPoint(cfg: cfg).map { "self px (\(Int($0.x)), \(Int($0.y)))\(vis.atMs - vis.selfSeenMs < 1000 ? "" : " assumed")" } ?? "self unknown"
        Log.warn("no target: \(vis.enemies.count) tracked \(tracked); \(selfText); frame \(vis.frameWidth)x\(vis.frameHeight), scan \(Int(vis.scanMicros)) us")
        if vis.enemies.isEmpty, nowMs() - lastNoTargetRecordMs > 300_000 {
            lastNoTargetRecordMs = nowMs()
            vision.requestRecord("notarget-\(Self.stamp())")
        }
    }

    private static let stampFormatter = ISO8601DateFormatter()

    private static func stamp() -> String {
        stampFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
