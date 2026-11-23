import Foundation

/// Раскладка файлов лаунчера на диске.
struct Paths {
    let root: URL          // ~/Library/Application Support/HomeCraft
    let game: URL          // root/game
    let java: URL          // root/java
    let cache: URL         // root/cache
    let logs: URL          // root/logs

    static func standard() -> Paths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeCraft", isDirectory: true)
        return Paths(
            root: base,
            game: base.appendingPathComponent("game", isDirectory: true),
            java: base.appendingPathComponent("java", isDirectory: true),
            cache: base.appendingPathComponent("cache", isDirectory: true),
            logs: base.appendingPathComponent("logs", isDirectory: true)
        )
    }

    func prepare() throws {
        for d in [root, game, java, cache, logs] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}

/// Mojang version manifest.
struct VersionIndex: Codable {
    struct Entry: Codable { let id: String; let url: String }
    let versions: [Entry]
}

struct VersionMeta: Codable {
    struct AssetIndex: Codable { let id: String; let url: String; let sha1: String }
    struct Download: Codable { let url: String; let sha1: String; let size: Int64 }
    struct Downloads: Codable {
        let client: Download
        let client_mappings: Download?
    }
    struct LibDownloads: Codable { let artifact: Download? }
    struct Lib: Codable {
        let name: String
        let downloads: LibDownloads?
        let rules: [Rule]?
    }
    struct Rule: Codable {
        struct OS: Codable { let name: String? }
        let action: String
        let os: OS?
    }
    let id: String
    let mainClass: String
    let assets: String
    let assetIndex: AssetIndex
    let downloads: Downloads
    let libraries: [Lib]
    let javaVersion: JavaVersion?
    struct JavaVersion: Codable { let majorVersion: Int }
}

/// Скачивание и подготовка ванильного Minecraft.
enum Vanilla {
    static let manifestURL = "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

    static func versionMeta(_ id: String) throws -> VersionMeta {
        let idxData = try Net.data(manifestURL)
        let idx = try JSONDecoder().decode(VersionIndex.self, from: idxData)
        guard let entry = idx.versions.first(where: { $0.id == id }) else {
            throw LErr.manifest("версия \(id) не найдена у Mojang")
        }
        let data = try Net.data(entry.url)
        return try JSONDecoder().decode(VersionMeta.self, from: data)
    }

    /// Скачать client.jar, библиотеки и assets. Возвращает classpath.
    static func install(version: String, paths: Paths, progress: @escaping (String, Double) -> Void) throws -> [String] {
        let meta = try versionMeta(version)
        let libDir = paths.game.appendingPathComponent("libraries", isDirectory: true)
        let verDir = paths.game.appendingPathComponent("versions/\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: verDir, withIntermediateDirectories: true)

        // 1. client.jar
        progress("Скачиваю клиент \(version)", 0.05)
        let clientJar = verDir.appendingPathComponent("\(version).jar")
        try Net.download(meta.downloads.client.url, to: clientJar,
                         expectedSha1: meta.downloads.client.sha1) { p in
            progress("Клиент \(version)", 0.05 + p * 0.25)
        }

        // 2. Библиотеки
        let libs = meta.libraries.filter { allowed($0.rules) }
        var classpath: [String] = []
        for (i, lib) in libs.enumerated() {
            guard let art = lib.downloads?.artifact else { continue }
            let parts = lib.name.split(separator: ":")
            guard parts.count >= 3 else { continue }
            let group = parts[0].replacingOccurrences(of: ".", with: "/")
            let artifact = parts[1]
            let ver = parts[2]
            let file = libDir.appendingPathComponent("\(group)/\(artifact)/\(ver)/\(artifact)-\(ver).jar")
            try Net.download(art.url, to: file, expectedSha1: art.sha1)
            classpath.append(file.path)
            let f = 0.30 + 0.45 * (Double(i + 1) / Double(max(1, libs.count)))
            progress("Библиотеки \(i + 1)/\(libs.count)", f)
        }

        // 3. Assets (только индекс + объекты, которые реально есть)
        progress("Индекс ресурсов", 0.78)
        let assetsDir = paths.game.appendingPathComponent("assets", isDirectory: true)
        let indexes = assetsDir.appendingPathComponent("indexes", isDirectory: true)
        try FileManager.default.createDirectory(at: indexes, withIntermediateDirectories: true)
        let indexFile = indexes.appendingPathComponent("\(meta.assetIndex.id).json")
        try Net.download(meta.assetIndex.url, to: indexFile, expectedSha1: meta.assetIndex.sha1)

        // 4. Объекты ассетов: без них модели и звуки не грузятся.
        progress("Ресурсы игры", 0.82)
        try downloadAssetObjects(indexFile: indexFile, assetsDir: assetsDir,
                                 progress: progress)
        progress("Готово", 1.0)
        return classpath
    }

    /// Скачивает объекты из asset index параллельно (по 16 потоков).
    /// Кэш общий: путь = objects/<первые 2 символа hash>/<hash>.
    static func downloadAssetObjects(indexFile: URL, assetsDir: URL,
                                     progress: @escaping (String, Double) -> Void) throws {
        guard let data = try? Data(contentsOf: indexFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [String: Any] else { return }

        struct Task { let hash: String; let dest: URL; let url: String }
        var pending: [Task] = []
        let objectsDir = assetsDir.appendingPathComponent("objects", isDirectory: true)

        for (_, value) in objects {
            guard let info = value as? [String: Any],
                  let hash = info["hash"] as? String else { continue }
            let prefix = String(hash.prefix(2))
            let dest = objectsDir.appendingPathComponent(prefix).appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            pending.append(Task(hash: hash, dest: dest,
                                url: "https://resources.download.minecraft.net/\(prefix)/\(hash)"))
        }

        let total = pending.count
        if total == 0 { return }

        let lock = NSLock()
        var done = 0
        var failed = 0

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 16

        for task in pending {
            queue.addOperation {
                do {
                    try Net.download(task.url, to: task.dest, expectedSha1: task.hash)
                } catch {
                    lock.lock(); failed += 1; lock.unlock()
                }
                lock.lock()
                done += 1
                let current = done
                lock.unlock()

                if current % 100 == 0 || current == total {
                    progress("Ресурсы \(current)/\(total)",
                             0.82 + 0.17 * Double(current) / Double(total))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        if failed > 0 {
            // Не валим запуск: игра стартует и без части ресурсов.
            progress("Ресурсы: пропущено \(failed)", 0.99)
        }
    }

    static func allowed(_ rules: [VersionMeta.Rule]?) -> Bool {
        guard let rules, !rules.isEmpty else { return true }
        var allowed = false
        for rule in rules {
            let matchesOS = rule.os?.name == nil || rule.os?.name == "osx"
            if matchesOS { allowed = (rule.action == "allow") }
        }
        return allowed
    }
}