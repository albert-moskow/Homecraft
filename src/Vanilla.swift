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

        progress("Готово", 1.0)
        return classpath
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