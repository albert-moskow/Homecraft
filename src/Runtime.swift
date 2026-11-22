import Foundation

/// Java runtime: своя копия Temurin 21, чтобы не зависеть от системы.
enum Java {
    static let adoptiumAPI = "https://api.adoptium.net/v3/binary/latest/21/ga/mac/aarch64/jdk/hotspot/normal/eclipse"

    static func binary(paths: Paths) -> URL? {
        // 1. Своя копия в java/ — самый предсказуемый вариант.
        if let dirs = try? FileManager.default.contentsOfDirectory(at: paths.java, includingPropertiesForKeys: nil) {
            for d in dirs.sorted(by: { $0.path < $1.path }) {
                for sub in ["Contents/Home/bin/java", "bin/java"] {
                    let cand = d.appendingPathComponent(sub)
                    if FileManager.default.isExecutableFile(atPath: cand.path), isJava21(cand) {
                        return cand
                    }
                }
            }
        }
        // 2. Установленная JDK 21 в системной папке.
        let jvms = "/Library/Java/JavaVirtualMachines"
        if let dirs = try? FileManager.default.contentsOfDirectory(atPath: jvms) {
            for d in dirs where d.contains("21") {
                let cand = URL(fileURLWithPath: jvms)
                    .appendingPathComponent(d)
                    .appendingPathComponent("Contents/Home/bin/java")
                if FileManager.default.isExecutableFile(atPath: cand.path), isJava21(cand) {
                    return cand
                }
            }
        }
        // 3. Homebrew / system — только если это действительно 21.
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/opt/openjdk@21/bin/java"),
            URL(fileURLWithPath: "/usr/local/opt/openjdk@21/bin/java"),
            URL(fileURLWithPath: "/usr/bin/java")
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            if isJava21(c) { return c }
        }
        return nil
    }

    static func isJava21(_ java: URL) -> Bool {
        // -version пишет в stderr; объём мал, но читаем ДО ожидания —
        // иначе буфер канала может заблокировать процесс.
        let p = Process()
        p.executableURL = java
        p.arguments = ["-version"]
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.contains("version \"21")
    }

    /// Скачивает JDK 21 в paths.java и возвращает бинарь.
    static func ensure(paths: Paths, progress: @escaping (String, Double) -> Void) throws -> URL {
        if let existing = binary(paths: paths) { return existing }

        progress("Скачиваю Java 21", 0.02)
        let tar = paths.cache.appendingPathComponent("jdk21.tar.gz")
        try Net.download(adoptiumAPI, to: tar) { p in
            progress("Java 21", 0.02 + p * 0.20)
        }

        progress("Распаковываю Java", 0.25)
        let dest = paths.java.appendingPathComponent("jdk", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", tar.path, "-C", dest.path, "--strip-components", "1"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw LErr.java("tar завершился с кодом \(p.terminationStatus)") }

        let javaBin = dest.appendingPathComponent("Contents/Home/bin/java")
        guard FileManager.default.isExecutableFile(atPath: javaBin.path) else {
            throw LErr.java("java не найден после распаковки")
        }
        try? FileManager.default.removeItem(at: tar)
        progress("Java готова", 0.30)
        return javaBin
    }
}

/// NeoForge: установка через официальный installer.
enum NeoForge {
    static func installerURL(version: String) -> String {
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(version)/neoforge-\(version)-installer.jar"
    }

    /// Устанавливает NeoForge в paths.game, возвращает папку версии и список доп. библиотек.
    static func install(mcVersion: String, neoVersion: String, paths: Paths, java: URL,
                        progress: @escaping (String, Double) -> Void) throws -> String {
        let neoId = "neoforge-\(neoVersion)"
        let target = paths.game.appendingPathComponent("versions/\(neoId)", isDirectory: true)
        let marker = target.appendingPathComponent("\(neoId).json")
        if FileManager.default.fileExists(atPath: marker.path) {
            progress("NeoForge уже установлен", 0.5)
            return neoId
        }

        progress("Скачиваю NeoForge \(neoVersion)", 0.32)
        let jar = paths.cache.appendingPathComponent("neoforge-\(neoVersion)-installer.jar")
        try Net.download(installerURL(version: neoVersion), to: jar) { p in
            progress("NeoForge", 0.32 + p * 0.10)
        }

        // Установщик NeoForge проверяет наличие профиля лаунчера — создаём минимальный.
        let profiles = paths.game.appendingPathComponent("launcher_profiles.json")
        if !FileManager.default.fileExists(atPath: profiles.path) {
            let stub = """
            {"profiles":{},"settings":{"enableSnapshots":false,"keepLauncherOpen":false},
             "version":3}
            """
            try stub.write(to: profiles, atomically: true, encoding: .utf8)
        }

        progress("Устанавливаю NeoForge", 0.45)
        let p = Process()
        p.executableURL = java
        p.arguments = ["-jar", jar.path, "--installClient", paths.game.path]
        p.currentDirectoryURL = paths.game

        // Вывод пишем в файл, а не в Pipe: установщик печатает много,
        // заполняет буфер канала и навсегда встаёт, если его не вычитывать.
        let logURL = paths.logs.appendingPathComponent("neoforge-install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }
        p.standardOutput = logHandle
        p.standardError = logHandle

        try p.run()
        p.waitUntilExit()

        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: marker.path) else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            throw LErr.manifest("NeoForge installer упал (\(p.terminationStatus))\n\(tail.suffix(800))")
        }
        try? FileManager.default.removeItem(at: jar)
        progress("NeoForge установлен", 0.55)
        return neoId
    }
}