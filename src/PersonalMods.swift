import Foundation

/// Готовые наборы личных модов: скачиваются в `mods-custom` по кнопке.
///
/// Наборы лежат в репозитории лаунчера (`personal-mods.json`), но не входят в
/// `pack.json`: их получает только тот, кто сам нажал «Установить». Сервер и
/// общая сборка про них не знают.
enum PersonalMods {
    static let manifestURL = "https://raw.githubusercontent.com/albert-moskow/Homecraft/main/personal-mods.json"

    struct File: Codable {
        var name: String
        var url: String
        var sha1: String
        var size: Int64
    }

    struct Pack: Codable, Identifiable {
        var id: String
        var name: String
        var description: String
        var files: [File]
    }

    struct Manifest: Codable {
        var version: String
        var packs: [Pack]
    }

    static func load() throws -> Manifest {
        let data = try Net.data(manifestURL)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Все файлы набора уже лежат в `mods-custom` с нужными хешами.
    static func isInstalled(_ pack: Pack, paths: Paths) -> Bool {
        let dir = CustomMods.folder(for: paths)
        return pack.files.allSatisfy { file in
            let dest = dir.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: dest.path) else { return false }
            return (try? Net.sha1(of: dest)) == file.sha1
        }
    }

    /// Скачивает отсутствующие файлы в `mods-custom` и включает их.
    @discardableResult
    static func install(_ pack: Pack, paths: Paths,
                        progress: ((String, Double) -> Void)? = nil) throws -> Int {
        let dir = CustomMods.folder(for: paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = CustomMods.loadState(paths)
        var downloaded = 0

        for (index, file) in pack.files.enumerated() {
            let dest = dir.appendingPathComponent(file.name)
            let ready = FileManager.default.fileExists(atPath: dest.path)
                && (try? Net.sha1(of: dest)) == file.sha1
            if !ready {
                try Net.download(file.url, to: dest, expectedSha1: file.sha1)
                downloaded += 1
            }
            if !state.enabled.contains(file.name) { state.enabled.append(file.name) }
            progress?(file.name, Double(index + 1) / Double(pack.files.count))
        }

        CustomMods.saveState(state, paths)
        CustomMods.apply(paths: paths) { LauncherModel.log($0) }
        return downloaded
    }
}
