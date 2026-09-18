import AppKit
import Foundation

/** Data Dragon spell and champion icons, downloaded once and cached in Application Support. */
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private(set) var images: [String: NSImage] = [:]
    private var pending = Set<String>()
    private let directory = Settings.fileURL.deletingLastPathComponent().appendingPathComponent("icons")

    func spell(_ file: String) -> NSImage? {
        file.isEmpty ? nil : image(path: "img/spell/\(file)", key: "spell_\(file)")
    }

    func champion(_ id: String) -> NSImage? {
        id.isEmpty ? nil : image(path: "img/champion/\(id).png", key: "champion_\(id).png")
    }

    private func image(path: String, key: String) -> NSImage? {
        if let image = images[key] { return image }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        let local = directory.appendingPathComponent(key)
        let remote = URL(string: "https://ddragon.leagueoflegends.com/cdn/\(SpellData.version)/\(path)")
        let directory = directory
        DispatchQueue.global(qos: .utility).async {
            var data = try? Data(contentsOf: local)
            if data == nil, let remote, let downloaded = try? Data(contentsOf: remote) {
                data = downloaded
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? downloaded.write(to: local)
            }
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                self.pending.remove(key)
                if let image { self.images[key] = image }
            }
        }
        return nil
    }
}
