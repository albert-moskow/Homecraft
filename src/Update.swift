import Foundation

/// Самообновление: тянет latest.json из git, сравнивает версию,
/// скачивает новый .app и подменяет текущий бандл через вспомогательный скрипт.
enum Update {
    struct Release: Codable {
        let version: String
        let url: String
        let sha256: String
        let notes: String?
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func check(feedURL: String) throws -> Release? {
        let data = try Net.data(feedURL)
        let release = try JSONDecoder().decode(Release.self, from: data)
        return isNewer(release.version, than: currentVersion) ? release : nil
    }

    /// Семантическое сравнение "1.2.3" > "1.2.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Скачивает новую версию и запускает замену. Приложение завершится.
    static func apply(_ release: Release, paths: Paths,
                      progress: @escaping (String, Double) -> Void) throws {
        let zip = paths.cache.appendingPathComponent("update-\(release.version).zip")
        progress("Скачиваю обновление \(release.version)", 0.1)
        try Net.download(release.url, to: zip) { p in
            progress("Обновление \(release.version)", 0.1 + p * 0.7)
        }

        let actual = try Net.sha256(of: zip)
        guard actual == release.sha256 else {
            throw LErr.update("хеш не совпал: ожидался \(release.sha256.prefix(12))…, получен \(actual.prefix(12))…")
        }

        progress("Распаковываю", 0.85)
        let unpack = paths.cache.appendingPathComponent("update-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, unpack.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw LErr.update("ditto завершился с кодом \(unzip.terminationStatus)")
        }

        guard let newApp = (try? FileManager.default.contentsOfDirectory(at: unpack, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            throw LErr.update("в архиве нет .app")
        }

        let currentApp = Bundle.main.bundleURL
        progress("Устанавливаю", 0.95)

        // Подмену делает отдельный скрипт: приложение не может заменить себя на ходу.
        let script = paths.cache.appendingPathComponent("apply-update.sh")
        let body = """
        #!/bin/bash
        sleep 1
        rm -rf "\(currentApp.path).old"
        mv "\(currentApp.path)" "\(currentApp.path).old"
        ditto "\(newApp.path)" "\(currentApp.path)"
        xattr -dr com.apple.quarantine "\(currentApp.path)" 2>/dev/null
        open "\(currentApp.path)"
        rm -rf "\(currentApp.path).old"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [script.path]
        try runner.run()

        progress("Перезапуск", 1.0)
    }
}