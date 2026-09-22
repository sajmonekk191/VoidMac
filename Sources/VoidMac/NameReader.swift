import CoreGraphics
import Foundation
import Vision

/** Identifies the champion behind an enemy bar: the system text recogniser reads the name above the bar and the level in its box, matched against the enemy list from the Live Client; one read at a time on a background queue. */
final class NameReader: @unchecked Sendable {
    struct Identity: Equatable {
        var champion: String
        var level: Int
        var text: String
        var atMs: Double
    }

    /** One crop to read: the bar's track, the image with the enlargement it still needs, and where the fill starts inside the enlarged image. */
    struct Job {
        let trackID: Int
        let image: CGImage
        let scale: Int
        let fillX: Double
        let fillY: Double
        let atMs: Double
    }

    private struct Attempt {
        var tries = 0
        var lastMs = -1e9
    }

    private let lock = NSLock()
    private var identities: [Int: Identity] = [:]
    private var attempts: [Int: Attempt] = [:]
    private var busy = false
    private let queue = DispatchQueue(label: "void.names", qos: .utility)
    var enemies: () -> [EnemyPlayer] = { [] }

    func identity(for id: Int) -> Identity? {
        lock.withLock { identities[id] }
    }

    /** Unknown tracks are read every 350 ms (six tries, then every 3 s), known ones re-checked every `refreshMs`; nothing while a read runs. */
    func wants(_ id: Int, now: Double, refreshMs: Double = 6000) -> Bool {
        lock.withLock {
            guard !busy else { return false }
            let attempt = attempts[id] ?? Attempt()
            if let known = identities[id] { return now - known.atMs > refreshMs && now - attempt.lastMs > refreshMs }
            return now - attempt.lastMs > (attempt.tries < 6 ? 350 : 3000)
        }
    }

    /** Drops what was learned about tracks that no longer exist. */
    func keep(_ live: Set<Int>) {
        lock.withLock {
            identities = identities.filter { live.contains($0.key) }
            attempts = attempts.filter { live.contains($0.key) }
        }
    }

    func submit(_ job: Job) {
        lock.withLock {
            busy = true
            var attempt = attempts[job.trackID] ?? Attempt()
            attempt.tries += 1
            attempt.lastMs = job.atMs
            attempts[job.trackID] = attempt
        }
        queue.async { self.read(job) }
    }

    private func read(_ job: Job) {
        defer { lock.withLock { busy = false } }
        let lines = Self.recognize(FrameDump.enlarged(job.image, scale: job.scale))
        var name = ""
        var level = 0
        for line in lines {
            if line.box.midY < job.fillY - 2 {
                name += (name.isEmpty ? "" : " ") + line.text
            } else if line.box.midX < job.fillX, let digits = Int(line.text.filter(\.isNumber)) {
                level = digits
            }
        }
        let tries = lock.withLock { attempts[job.trackID]?.tries ?? 0 }
        let candidates = enemies()
        guard let match = Self.match(name: name, level: level, enemies: candidates) else {
            if tries == 6 { Log.info("enemy #\(job.trackID): no champion recognised (read \"\(name)\", level \(level), \(candidates.count) enemies in the game)") }
            return
        }
        let text = match.via == "dummy" ? "dummy" : "\(match.player.championName) lvl \(match.player.level) via \(match.via)"
        let previous: Identity? = lock.withLock {
            let old = identities[job.trackID]
            identities[job.trackID] = Identity(champion: match.player.champion, level: match.player.level, text: text, atMs: job.atMs)
            return old
        }
        if previous?.champion != match.player.champion { Log.info("enemy #\(job.trackID): \(text) (read \"\(name)\", level \(level))") }
    }

    /** Text lines in the image with their boxes in image px (top-left origin). */
    static func recognize(_ image: CGImage) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let width = Double(image.width), height = Double(image.height)
        return results.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return (candidate.string, CGRect(x: b.minX * width, y: (1 - b.maxY) * height, width: b.width * width, height: b.height * height))
        }
    }

    /** A practice dummy by its name plate; else the enemy whose name reads like the text (similarity ≥ 0.6 and clearly ahead of the runner-up); with no readable name, the only enemy of the read level. */
    static func match(name: String, level: Int, enemies: [EnemyPlayer]) -> (player: EnemyPlayer, via: String)? {
        let read = normalized(name)
        if read.contains("dummy") { return (EnemyPlayer(champion: ChampionModels.dummyKey, championName: "Target Dummy", level: level, names: []), "dummy") }
        if read.count >= 3 {
            var scored = enemies.map { player -> (EnemyPlayer, Double) in
                (player, player.names.map { similarity(read, normalized($0)) }.max() ?? 0)
            }
            scored.sort { $0.1 > $1.1 }
            if let best = scored.first, best.1 >= 0.6, scored.count == 1 || best.1 - scored[1].1 >= 0.15 { return (best.0, "name") }
            if let best = scored.first, best.1 >= 0.3 { return nil }
        }
        if level > 0 {
            let same = enemies.filter { $0.level == level }
            if same.count == 1 { return (same[0], "level") }
        }
        return nil
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /** 1 for equal strings, 0.85 when one contains the other, else 1 minus the edit distance over the longer length. */
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if min(a.count, b.count) >= 4, a.contains(b) || b.contains(a) { return 0.85 }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}
