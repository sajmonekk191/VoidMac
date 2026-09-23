import Foundation

/** Follows minion bars across frames: each bar goes to the nearest track of its width that can be it (a bar never gains health, and one turning white keeps its track whatever hit took it there), a white bar seen first starts its own track only with the bar's exact band height and a fill of 2.4 px at 1080p (white text of the HUD, the practice tool's target panel and a champion's white resource bar fail one or the other), every track keeps its last 1.5 s of health and is dropped 300 ms after its bar vanished. */
enum MinionTracker {
    static func update(_ tracks: [MinionTrack], with hits: [MinionHit], geometry: MinionBarGeometry, now: Double, nextID: inout Int) -> (tracks: [MinionTrack], assist: MinionHit?) {
        var pairs: [(hit: Int, track: Int, distance: Double)] = []
        for (h, hit) in hits.enumerated() {
            for (t, track) in tracks.enumerated() {
                let dx = track.x - Double(hit.x), dy = track.y - Double(hit.y)
                let reach = geometry.scale * min(60, 10 + 0.5 * (now - track.lastSeenMs))
                guard hit.large == track.large, abs(dx) <= reach, abs(dy) <= reach, hit.fraction <= track.fraction + 0.05, !hit.white || abs(track.height - hit.height) <= 3 else { continue }
                pairs.append((h, t, dx * dx + dy * dy))
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedHits = Set<Int>(), usedTracks = Set<Int>()
        var next: [MinionTrack] = []
        var assist: MinionHit?
        for pair in pairs where !usedHits.contains(pair.hit) && !usedTracks.contains(pair.track) {
            usedHits.insert(pair.hit)
            usedTracks.insert(pair.track)
            let hit = hits[pair.hit]
            var track = tracks[pair.track]
            track.x = Double(hit.x)
            track.y = Double(hit.y)
            track.span = hit.span
            track.height = hit.height
            track.fraction = hit.fraction
            track.white = hit.white
            let mark = hit.mark.map { $0 / Double(hit.span) }
            if let mark { track.lastMark = mark }
            if let mark, let previous = track.mark, abs(previous - mark) <= 0.02 {
                track.markSightings += 1
            } else {
                track.markSightings = mark == nil ? 0 : 1
            }
            track.mark = mark
            track.sightings += 1
            track.lastSeenMs = now
            track.maxFraction = max(track.maxFraction, hit.fraction)
            track.samples.append(HealthSample(t: now, fraction: hit.fraction))
            track.samples.removeAll { now - $0.t > 1500 }
            track.lossPerMs = MinionTrack.lossRate(track.samples, span: hit.span)
            if hit.white || track.markSightings >= 3 { assist = hit }
            next.append(track)
        }
        for (h, hit) in hits.enumerated() where !usedHits.contains(h) && (!hit.white || (hit.height == geometry.bandHeight && hit.fill >= 2.4 * geometry.scale)) {
            let mark = hit.mark.map { $0 / Double(hit.span) }
            next.append(MinionTrack(id: nextID, x: Double(hit.x), y: Double(hit.y), span: hit.span, height: hit.height, fraction: hit.fraction, white: hit.white,
                                    large: hit.large, mark: mark, lastMark: mark, firstSeenMs: now, lastSeenMs: now, maxFraction: hit.fraction,
                                    samples: [HealthSample(t: now, fraction: hit.fraction)]))
            if hit.white { assist = hit }
            nextID += 1
        }
        for (t, track) in tracks.enumerated() where !usedTracks.contains(t) && now - track.lastSeenMs < 300 { next.append(track) }
        return (next, assist)
    }
}
