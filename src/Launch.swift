import Foundation

/// Сборка командной строки и запуск игры.
enum Launch {
    struct Options {
        var nickname: String
        var memoryMB: Int = 4096
        var extraJvmArgs: [String] = []
        var width: Int = 1280
        var height: Int = 720
        var fullscreen: Bool = false
        var serverAddress: String?     // автоподключение
    }

    static func run(versionId: String, paths: Paths, java: URL, opts: Options,
                    progress: @escaping (String, Double) -> Void) throws -> Process {
        let verDir = paths.game.appendingPathComponent("versions/\(versionId)", isDirectory: true)
        let json = verDir.appendingPathComponent("\(versionId).json")
        guard let data = try? Data(contentsOf: json),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LErr.launch("не найден \(versionId).json")
        }

        let mainClass = root["mainClass"] as? String ?? "net.minecraft.client.main.Main"
        let assetsId = root["assets"] as? String ?? "1.21"
        let clientJar = verDir.appendingPathComponent("\(versionId).jar")

        // classpath: библиотеки версии + client.jar
        var cp: [String] = []
        if let libs = root["libraries"] as? [[String: Any]] {
            for lib in libs {
                guard let name = lib["name"] as? String else { continue }
                if !neoTolerantAllows(lib) { continue }
                if let dl = lib["downloads"] as? [String: Any],
                   let art = dl["artifact"] as? [String: Any],
                   let path = art["path"] as? String {
                    cp.append(paths.game.appendingPathComponent("libraries/\(path)").path)
                } else {
                    cp.append(paths.game.appendingPathComponent("libraries/\(mavenPath(name))").path)
                }
            }
        }
        cp.append(clientJar.path)

        let nativesDir = paths.game.appendingPathComponent("versions/\(versionId)/natives", isDirectory: true)
        try? FileManager.default.createDirectory(at: nativesDir, withIntermediateDirectories: true)
        extractNatives(root: root, paths: paths, to: nativesDir)

        let assetIndex = paths.game.appendingPathComponent("assets/indexes/\(assetsId).json").path
        let assetsRoot = paths.game.appendingPathComponent("assets").path

        var args: [String] = [
            "-Xmx\(opts.memoryMB)M",
            "-Xms\(opts.memoryMB / 2)M",
            "-Djava.library.path=\(nativesDir.path)",
            "-Djna.tmpdir=\(nativesDir.path)",
            "-Dorg.lwjgl.system.SharedLibraryExtractPath=\(nativesDir.path)",
            "-Dio.netty.native.workdir=\(nativesDir.path)",
            "-Dminecraft.launcher.brand=HomeCraft",
            "-Dminecraft.launcher.version=1.0"
        ]
        args.append(contentsOf: opts.extraJvmArgs)

        // NeoForge требует module-path из своих библиотек
        let modulePath = cp.filter { $0.contains("bootstraplauncher") || $0.contains("securejarhandler")
            || $0.contains("asm") || $0.contains("JarJarFileSystems") || $0.contains("mixin") }
        if !modulePath.isEmpty {
            args.append("--module-path")
            args.append(modulePath.joined(separator: ":"))
            args.append("--add-modules")
            args.append("ALL-MODULE-PATH")
            args.append("--add-opens")
            args.append("java.base/java.util.jar=cpw.mods.securejarhandler")
            args.append("--add-opens")
            args.append("java.base/java.lang.invoke=cpw.mods.securejarhandler")
            args.append("--add-exports")
            args.append("java.base/sun.security.util=cpw.mods.securejarhandler")
            args.append("--add-exports")
            args.append("jdk.naming.dns/com.sun.jndi.dns=java.naming")
        }

        args.append("-cp")
        args.append(cp.joined(separator: ":"))
        args.append(mainClass)

        var game: [String] = [
            "--username", opts.nickname,
            "--version", versionId,
            "--gameDir", paths.game.path,
            "--assetsDir", assetsRoot,
            "--assetIndex", assetsId,
            "--uuid", offlineUUID(opts.nickname),
            "--accessToken", "0",
            "--userType", "legacy",
            "--versionType", "release"
        ]
        if let ai = assetIndex as String? {
            game.append(contentsOf: ["--assetIndex", assetsId])
            _ = ai
        }
        if let server = opts.serverAddress, !server.isEmpty {
            game.append(contentsOf: ["--server", server])
        }
        if opts.fullscreen { game.append("--fullscreen") }
        else {
            game.append(contentsOf: ["--width", "\(opts.width)", "--height", "\(opts.height)"])
        }

        let p = Process()
        p.executableURL = java
        p.arguments = args + game
        p.currentDirectoryURL = paths.game
        p.environment = ProcessInfo.processInfo.environment.merging([
            "JAVA_HOME": java.deletingLastPathComponent().deletingLastPathComponent().path
        ]) { _, new in new }

        let logURL = paths.logs.appendingPathComponent("game-\(timestamp()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }

        progress("Запускаю игру", 1.0)
        try p.run()
        return p
    }

    // MARK: - helpers

    static func mavenPath(_ name: String) -> String {
        let parts = name.split(separator: ":")
        guard parts.count >= 3 else { return name }
        let group = parts[0].replacingOccurrences(of: ".", with: "/")
        let artifact = parts[1]
        let version = parts[2]
        let classifier = parts.count > 3 ? "-\(parts[3])" : ""
        return "\(group)/\(artifact)/\(version)/\(artifact)-\(version)\(classifier).jar"
    }

    /// neoForge/Forge кладут часть библиотек без блока downloads — их путь вычисляем из name.
    static func neoTolerantAllows(_ lib: [String: Any]) -> Bool {
        guard let rules = lib["rules"] as? [[String: Any]] else { return true }
        var allowed = false
        for rule in rules {
            let action = rule["action"] as? String ?? ""
            if let os = rule["os"] as? [String: Any], let name = os["name"] as? String {
                if name == "osx" { allowed = (action == "allow") }
            } else {
                allowed = (action == "allow")
            }
        }
        return allowed
    }

    static func extractNatives(root: [String: Any], paths: Paths, to dir: URL) {
        guard let libs = root["libraries"] as? [[String: Any]] else { return }
        for lib in libs {
            guard let dl = lib["downloads"] as? [String: Any],
                  let classifiers = dl["classifiers"] as? [String: Any],
                  let natives = classifiers["natives-macos-arm64"] as? [String: Any]
                    ?? classifiers["natives-macos"] as? [String: Any],
                  let path = natives["path"] as? String else { continue }
            let jar = paths.game.appendingPathComponent("libraries/\(path)")
            unzip(jar: jar, to: dir)
        }
    }

    static func unzip(jar: URL, to dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", jar.path, "*.dylib", "*.jnilib", "-d", dir.path]
        try? p.run(); p.waitUntilExit()
    }

    static func offlineUUID(_ name: String) -> String {
        // UUID.nameUUIDFromBytes("OfflinePlayer:" + name) — как в ванильном сервере
        let input = Array("OfflinePlayer:\(name)".utf8)
        var hash = [UInt8](repeating: 0, count: 16)
        // MD5
        var ctx = MD5Context()
        ctx.update(input)
        hash = ctx.finalize()
        hash[6] = (hash[6] & 0x0F) | 0x30
        hash[8] = (hash[8] & 0x3F) | 0x80
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let i = hex.index(hex.startIndex, offsetBy: 8)
        let j = hex.index(hex.startIndex, offsetBy: 12)
        let k = hex.index(hex.startIndex, offsetBy: 16)
        let l = hex.index(hex.startIndex, offsetBy: 20)
        return "\(hex[..<i])-\(hex[i..<j])-\(hex[j..<k])-\(hex[k..<l])-\(hex[l...])"
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Минимальный MD5 (CryptoKit не даёт MD5).
struct MD5Context {
    private var a: UInt32 = 0x67452301
    private var b: UInt32 = 0xefcdab89
    private var c: UInt32 = 0x98badcfe
    private var d: UInt32 = 0x10325476
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
    ]
    private static let k: [UInt32] = (0..<64).map {
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0))
    }

    mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count) * 8
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 {
            process(Array(buffer[offset..<offset + 64]))
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    mutating func finalize() -> [UInt8] {
        var pad: [UInt8] = [0x80]
        let mod = (buffer.count + 1) % 64
        let zeros = mod <= 56 ? 56 - mod : 120 - mod
        pad.append(contentsOf: [UInt8](repeating: 0, count: zeros))
        var lenLE = length.littleEndian
        withUnsafeBytes(of: &lenLE) { pad.append(contentsOf: $0) }
        updateNoLength(pad)
        var out = [UInt8]()
        for v in [a, b, c, d] {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    private mutating func updateNoLength(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 {
            process(Array(buffer[offset..<offset + 64]))
            offset += 64
        }
        if offset > 0 { buffer.removeFirst(offset) }
    }

    private mutating func process(_ block: [UInt8]) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(block[i * 4]) | (UInt32(block[i * 4 + 1]) << 8)
                | (UInt32(block[i * 4 + 2]) << 16) | (UInt32(block[i * 4 + 3]) << 24)
        }
        var (aa, bb, cc, dd) = (a, b, c, d)
        for i in 0..<64 {
            var f: UInt32
            var g: Int
            switch i {
            case 0..<16: f = (bb & cc) | (~bb & dd); g = i
            case 16..<32: f = (dd & bb) | (~dd & cc); g = (5 * i + 1) % 16
            case 32..<48: f = bb ^ cc ^ dd; g = (3 * i + 5) % 16
            default: f = cc ^ (bb | ~dd); g = (7 * i) % 16
            }
            let tmp = dd
            dd = cc
            cc = bb
            let sum = aa &+ f &+ MD5Context.k[i] &+ m[g]
            bb = bb &+ sum.rotateLeft(MD5Context.s[i])
            aa = tmp
        }
        a &+= aa; b &+= bb; c &+= cc; d &+= dd
    }
}

extension UInt32 {
    func rotateLeft(_ n: UInt32) -> UInt32 {
        (self << n) | (self >> (32 - n))
    }
}