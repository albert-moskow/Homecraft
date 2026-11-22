import Foundation

/// Модпак из git: сравнение с локальным состоянием, докачка только изменённого.
enum Pack {
    static let stateFile = "pack-state.json"

    struct State: Codable {
        var packVersion: String
        var files: [String: String]  // path -> sha1
    }

    static func loadState(paths: Paths) -> State? {
        let f = paths.game.appendingPathComponent(stateFile)
        guard let d = try? Data(contentsOf: f) else { return nil }
        return try? JSONDecoder().decode(State.self, from: d)
    }

    static func saveState(_ s: State, paths: Paths) {
        let f = paths.game.appendingPathComponent(stateFile)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: f) }
    }

    /// Синхронизирует модпак: качает новые/изменённые файлы, удаляет устаревшие.
    static func sync(_ manifest: ModpackManifest, paths: Paths,
                     progress: @escaping (String, Double) -> Void) throws -> Int {
        let old = loadState(paths: paths)
        var new = State(packVersion: manifest.version, files: [:])

        // 1. Удалить файлы, которых больше нет в манифесте (только из прошлого состояния).
        if let old {
            let wanted = Set(manifest.files.map(\.path))
            for path in old.files.keys where !wanted.contains(path) {
                let f = paths.game.appendingPathComponent(path)
                try? FileManager.default.removeItem(at: f)
            }
        }
        for path in manifest.removePaths ?? [] {
            let f = paths.game.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: f)
        }

        // 2. Скачать/проверить файлы.
        var downloaded = 0
        let files = manifest.files.filter { $0.side != "server" }
        for (i, file) in files.enumerated() {
            let dest = paths.game.appendingPathComponent(file.path)
            let already = old?.files[file.path] == file.sha1
                && FileManager.default.fileExists(atPath: dest.path)

            if !already {
                try Net.download(file.url, to: dest, expectedSha1: file.sha1) { _ in }
                downloaded += 1
            }
            new.files[file.path] = file.sha1
            let f = 0.60 + 0.30 * (Double(i + 1) / Double(max(1, files.count)))
            progress("Моды \(i + 1)/\(files.count)", f)
        }

        saveState(new, paths: paths)
        return downloaded
    }
}