import Foundation

/// Сборка командной строки и запуск игры по правилам официального лаунчера:
/// манифест версии может наследоваться (`inheritsFrom`), а аргументы содержат
/// подстановки `${library_directory}`, `${classpath_separator}`, `${version_name}`.
enum Launch {
    struct Options {
        var nickname: String
        var memoryMB: Int = 4096
        var extraJvmArgs: [String] = []
        var width: Int = 1280
        var height: Int = 720
        var fullscreen: Bool = false
        var serverAddress: String?
    }

    // MARK: - Модель манифеста

    private struct Rule {
        let action: String
        let osName: String?
        func applies() -> Bool {
            guard let osName else { return true }
            return osName == "osx" && action == "allow"
        }
    }

    private struct Library {
        var name: String
        var path: String?          // из downloads.artifact.path
        var url: String?           // из downloads.artifact.url
        var sha1: String?
        var rules: [Rule] = []
        var isNative = false
        var nativePath: String?
        var nativeURL: String?
        var nativeSha1: String?
    }

    private struct Manifest {
        var id: String
        var mainClass: String
        var assetIndexId: String
        var assetIndexURL: String?
        var assetIndexSha1: String?
        var clientJarName: String?
        var libraries: [Library] = []
        var jvmArgs: [String] = []
        var gameArgs: [String] = []
        var inheritsFrom: String?
    }

    // MARK: - Чтение и слияние

    private static func parse(_ json: [String: Any], id: String) -> Manifest {
        var m = Manifest(id: id,
                         mainClass: json["mainClass"] as? String ?? "net.minecraft.client.main.Main",
                         assetIndexId: (json["assetIndex"] as? [String: Any])?["id"] as? String
                             ?? (json["assets"] as? String) ?? "legacy",
                         assetIndexURL: (json["assetIndex"] as? [String: Any])?["url"] as? String,
                         assetIndexSha1: (json["assetIndex"] as? [String: Any])?["sha1"] as? String,
                         clientJarName: id,
                         inheritsFrom: json["inheritsFrom"] as? String)

        if let dl = json["downloads"] as? [String: Any],
           let client = dl["client"] as? [String: Any] {
            m.clientJarName = (client["path"] as? String) ?? id
        }

        for raw in json["libraries"] as? [[String: Any]] ?? [] {
            guard let name = raw["name"] as? String else { continue }
            var lib = Library(name: name)

            if let rules = raw["rules"] as? [[String: Any]] {
                lib.rules = rules.map {
                    Rule(action: $0["action"] as? String ?? "",
                         osName: ($0["os"] as? [String: Any])?["name"] as? String)
                }
            }

            if let dl = raw["downloads"] as? [String: Any] {
                if let art = dl["artifact"] as? [String: Any] {
                    lib.path = art["path"] as? String
                    lib.url = art["url"] as? String
                    lib.sha1 = art["sha1"] as? String
                }
                // Классификаторы нативов НЕ должны перетирать artifact:
                // иначе вместо основного jar качается natives-архив.
                if let cls = dl["classifiers"] as? [String: Any] {
                    let key = (cls["natives-macos-arm64"] != nil) ? "natives-macos-arm64" : "natives-macos"
                    if let nat = cls[key] as? [String: Any] {
                        lib.nativePath = nat["path"] as? String
                        lib.nativeURL = nat["url"] as? String
                        lib.nativeSha1 = nat["sha1"] as? String
                    }
                }
            }
            // Нативы с классификатором natives-* кладём в classpath:
            // они не модульные, но содержат .dylib и нужны JVM для загрузки.
            if name.contains(":natives-") { lib.isNative = false }

            // NeoForge/Forge кладут часть библиотек без downloads — путь вычисляем из maven-координат.
            if lib.path == nil {
                lib.path = mavenPath(name)
            }
            m.libraries.append(lib)
        }

        if let args = json["arguments"] as? [String: Any] {
            m.jvmArgs = flattenArgs(args["jvm"])
            m.gameArgs = flattenArgs(args["game"])
        } else {
            if let mc = json["minecraftArguments"] as? String {
                m.gameArgs = mc.split(separator: " ").map(String.init)
            }
        }
        return m
    }

    private static func metaURL(for id: String) throws -> String {
        let idx = try JSONDecoder().decode(VersionIndex.self, from: try Net.data(Vanilla.manifestURL))
        guard let e = idx.versions.first(where: { $0.id == id }) else {
            throw LErr.manifest("версия \(id) не найдена у Mojang")
        }
        return e.url
    }

    /// Аргументы манифеста бывают строкой либо объектом с rules (--demo, --width).
    /// Берём только безусловные и применимые к текущей ОС.
    private static func flattenArgs(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [String] = []
        for item in arr {
            if let s = item as? String { out.append(s); continue }
            guard let dict = item as? [String: Any] else { continue }
            // rules: оставляем только allow-ветки без ограничений по ОС/фичам
            if let rules = dict["rules"] as? [[String: Any]] {
                let applies = rules.contains { r in
                    let action = r["action"] as? String ?? ""
                    let os = (r["os"] as? [String: Any])?["name"] as? String
                    let features = r["features"] as? [String: Any]
                    return action == "allow" && features == nil && (os == nil || os == "osx")
                }
                guard applies else { continue }
            }
            if let v = dict["value"] as? String { out.append(v) }
            else if let vs = dict["value"] as? [String] { out.append(contentsOf: vs) }
        }
        return out
    }

    /// Рекурсивно собирает манифест с учётом inheritsFrom.
    private static func loadManifest(versionId: String, paths: Paths) throws -> Manifest {
        func read(_ id: String) throws -> [String: Any] {
            let f = paths.game.appendingPathComponent("versions/\(id)/\(id).json")
            if let d = try? Data(contentsOf: f),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                return o
            }
            // Установщик NeoForge не кладёт манифест ванильной версии — берём у Mojang.
            let dir = paths.game.appendingPathComponent("versions/\(id)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta = try Vanilla.versionMeta(id)
            let data = try Net.data(metaURL(for: id))
            try data.write(to: f)
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LErr.launch("не удалось прочитать манифест \(id)")
            }
            return o
        }

        let own = parse(try read(versionId), id: versionId)

        guard let parentId = own.inheritsFrom else { return own }
        var parent = try loadManifest(versionId: parentId, paths: paths)

        // Слияние: свои значения приоритетнее, библиотеки объединяются.
        parent.id = own.id
        parent.mainClass = own.mainClass
        parent.assetIndexId = own.assetIndexId != "legacy" ? own.assetIndexId : parent.assetIndexId
        parent.assetIndexURL = own.assetIndexURL ?? parent.assetIndexURL
        parent.assetIndexSha1 = own.assetIndexSha1 ?? parent.assetIndexSha1
        parent.clientJarName = parent.clientJarName ?? own.clientJarName
        // Одна и та же библиотека может прийти из родительского манифеста и из NeoForge.
        var seen = Set(parent.libraries.compactMap { $0.path ?? $0.name })
        for lib in own.libraries {
            let key = lib.path ?? lib.name
            if seen.insert(key).inserted { parent.libraries.append(lib) }
        }
        parent.jvmArgs.append(contentsOf: own.jvmArgs)
        parent.gameArgs.append(contentsOf: own.gameArgs)
        parent.inheritsFrom = nil
        return parent
    }

    /// Скачивает клиентский jar и все библиотеки манифеста.
    private static func ensureFiles(_ m: Manifest, paths: Paths,
                            progress: @escaping (String, Double) -> Void) throws {
        // client.jar родительской версии
        if let base = m.clientJarName {
            let jar = paths.game.appendingPathComponent("versions/\(base)/\(base).jar")
            if !FileManager.default.fileExists(atPath: jar.path),
               let baseJson = try? Data(contentsOf: paths.game
                   .appendingPathComponent("versions/\(base)/\(base).json")),
               let o = try? JSONSerialization.jsonObject(with: baseJson) as? [String: Any],
               let dl = o["downloads"] as? [String: Any],
               let client = dl["client"] as? [String: Any],
               let url = client["url"] as? String {
                try Net.download(url, to: jar, expectedSha1: client["sha1"] as? String)
            }
        }

        let libs = m.libraries.filter { lib in
            lib.rules.isEmpty || lib.rules.contains { $0.applies() }
        }
        for (i, lib) in libs.enumerated() {
            guard let path = lib.path, let url = lib.url else { continue }
            let dest = paths.game.appendingPathComponent("libraries/\(path)")

            // Проверяем sha1, а не только наличие файла: битый jar ломает запуск
            // невнятной ошибкой "Module not found".
            var ok = false
            if FileManager.default.fileExists(atPath: dest.path), let want = lib.sha1 {
                ok = (try? Net.sha1(of: dest)) == want
            } else {
                ok = FileManager.default.fileExists(atPath: dest.path)
            }
            if ok { continue }

            try? FileManager.default.removeItem(at: dest)
            try Net.download(url, to: dest, expectedSha1: lib.sha1)
            progress("Библиотеки \(i + 1)/\(libs.count)", 0.5)
        }
    }

    // MARK: - Запуск

    static func run(versionId: String, paths: Paths, java: URL, opts: Options,
                    progress: @escaping (String, Double) -> Void) throws -> Process {
        let m = try loadManifest(versionId: versionId, paths: paths)
        try ensureFiles(m, paths: paths) { msg, f in progress(msg, 0.55 + f * 0.2) }

        let libDir = paths.game.appendingPathComponent("libraries").path
        let nativesDir = paths.game.appendingPathComponent("versions/\(versionId)/natives").path
        try? FileManager.default.createDirectory(
            atPath: nativesDir, withIntermediateDirectories: true)

        // Нативы: качаем архив с .dylib и распаковываем рядом с игрой.
        for lib in m.libraries where lib.nativePath != nil {
            let jar = paths.game.appendingPathComponent("libraries/\(lib.nativePath!)")
            if !FileManager.default.fileExists(atPath: jar.path), let u = lib.nativeURL {
                try Net.download(u, to: jar, expectedSha1: lib.nativeSha1)
            }
            if FileManager.default.fileExists(atPath: jar.path) {
                unzipNatives(jar: jar, to: URL(fileURLWithPath: nativesDir))
            }
        }

        // classpath — все не-нативные библиотеки + клиентский jar.
        var classpath: [String] = []
        var cpSeen = Set<String>()
        for lib in m.libraries where !lib.isNative {
            guard let p = lib.path else { continue }
            let full = "\(libDir)/\(p)"
            // Дубликаты в classpath ломают securejarhandler ("Duplicate key").
            if cpSeen.insert(full).inserted { classpath.append(full) }
        }
        // client.jar НЕ кладём в classpath: NeoForge подмешивает его сам
        // через -DignoreList, иначе получаем два модуля с пакетом net.minecraft.*
        // (_1._21._1 и minecraft) и ResolutionException.

        let sep = ":"
        let vars: [String: String] = [
            "library_directory": libDir,
            "classpath_separator": sep,
            "version_name": versionId,
            "natives_directory": nativesDir,
            "launcher_name": "HomeCraft",
            "launcher_version": "1.1",
            "classpath": classpath.joined(separator: sep),
            "auth_player_name": opts.nickname,
            "auth_uuid": offlineUUID(opts.nickname),
            "auth_access_token": "0",
            "clientid": "",
            "auth_xuid": "",
            "user_type": "legacy",
            "version_type": "release",
            "game_directory": paths.game.path,
            "assets_root": paths.game.appendingPathComponent("assets").path,
            "assets_index_name": m.assetIndexId,
            "user_properties": "{}",
            "resolution_width": "\(opts.width)",
            "resolution_height": "\(opts.height)"
        ]

        func subst(_ s: String) -> String {
            var out = s
            // не заменять ${classpath} при обработке module-path
            for (k, v) in vars { out = out.replacingOccurrences(of: "${\(k)}", with: v) }
            return out
        }

        var args: [String] = [
            // Без этого GLFW на macOS падает: "must be the first thread in the process".
            "-XstartOnFirstThread",
            "-Xmx\(opts.memoryMB)M",
            "-Xms\(opts.memoryMB / 2)M",
            "-Djava.library.path=\(nativesDir)",
            "-Dminecraft.launcher.brand=HomeCraft",
            "-Dminecraft.launcher.version=1.1"
        ]
        args.append(contentsOf: opts.extraJvmArgs)
        // Java принимает -cp и -p независимо от порядка; пути задаёт манифест.
        args.append("-cp")
        args.append(classpath.joined(separator: sep))
        args.append(contentsOf: m.jvmArgs.map(subst))
        args.append(m.mainClass)
        // Пустые offline-поля сохраняем вместе с флагами (--clientId, --xuid).
        // Неизвестная переменная — ошибка, а не повод удалить только её значение.
        let gameArgs = m.gameArgs.map(subst)
        if let unresolved = gameArgs.first(where: { $0.contains("${") }) {
            throw LErr.launch("неизвестная переменная в аргументе: \(unresolved)")
        }
        args.append(contentsOf: gameArgs)

        // В 1.21.1 параметр --server удалён: автоподключение идёт через quickPlay.
        if let server = opts.serverAddress?.trimmingCharacters(in: .whitespaces), !server.isEmpty {
            args.append(contentsOf: ["--quickPlayMultiplayer", server])
        }
        if opts.fullscreen { args.append("--fullscreen") }

        // Новый профиль проекта сразу запускает QuickPlay. Существующие
        // настройки доступности и графики игрока не перезаписываем.
        let optionsFile = paths.game.appendingPathComponent("options.txt")
        if !FileManager.default.fileExists(atPath: optionsFile.path) {
            try "onboardAccessibility:false\n".write(
                to: optionsFile, atomically: true, encoding: .utf8)
        }

        let p = Process()
        p.executableURL = java
        p.arguments = args
        p.currentDirectoryURL = paths.game

        let logURL = paths.logs.appendingPathComponent("game-\(timestamp()).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { _ in try? handle.close() }

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

    static func unzipNatives(jar: URL, to dir: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", "-j", jar.path, "*.dylib", "*.jnilib", "-d", dir.path]
        try? p.run(); p.waitUntilExit()
    }

    static func offlineUUID(_ name: String) -> String {
        var ctx = MD5Context()
        ctx.update(Array("OfflinePlayer:\(name)".utf8))
        var hash = ctx.finalize()
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
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Минимальный MD5 (CryptoKit не предоставляет MD5).
struct MD5Context {
    private var a: UInt32 = 0x67452301
    private var b: UInt32 = 0xefcdab89
    private var c: UInt32 = 0x98badcfe
    private var d: UInt32 = 0x10325476
    private var buffer = [UInt8]()
    private var length: UInt64 = 0

    private static let s: [UInt32] = [
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21
    ]
    private static let k: [UInt32] = (0..<64).map {
        UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0))
    }

    mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count) * 8
        buffer.append(contentsOf: bytes)
        var off = 0
        while buffer.count - off >= 64 {
            process(Array(buffer[off..<off + 64])); off += 64
        }
        if off > 0 { buffer.removeFirst(off) }
    }

    mutating func finalize() -> [UInt8] {
        var pad: [UInt8] = [0x80]
        let mod = (buffer.count + 1) % 64
        pad.append(contentsOf: [UInt8](repeating: 0, count: mod <= 56 ? 56 - mod : 120 - mod))
        var lenLE = length.littleEndian
        withUnsafeBytes(of: &lenLE) { pad.append(contentsOf: $0) }
        buffer.append(contentsOf: pad)
        var off = 0
        while buffer.count - off >= 64 {
            process(Array(buffer[off..<off + 64])); off += 64
        }
        var out = [UInt8]()
        for v in [a, b, c, d] {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    private mutating func process(_ block: [UInt8]) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(block[i*4]) | (UInt32(block[i*4+1]) << 8)
                 | (UInt32(block[i*4+2]) << 16) | (UInt32(block[i*4+3]) << 24)
        }
        var (aa, bb, cc, dd) = (a, b, c, d)
        for i in 0..<64 {
            var f: UInt32; var g: Int
            switch i {
            case 0..<16:  f = (bb & cc) | (~bb & dd); g = i
            case 16..<32: f = (dd & bb) | (~dd & cc); g = (5*i + 1) % 16
            case 32..<48: f = bb ^ cc ^ dd;           g = (3*i + 5) % 16
            default:      f = cc ^ (bb | ~dd);        g = (7*i) % 16
            }
            let tmp = dd
            dd = cc; cc = bb
            bb = bb &+ (aa &+ f &+ MD5Context.k[i] &+ m[g]).rotateLeft(MD5Context.s[i])
            aa = tmp
        }
        a &+= aa; b &+= bb; c &+= cc; d &+= dd
    }
}

extension UInt32 {
    func rotateLeft(_ n: UInt32) -> UInt32 { (self << n) | (self >> (32 - n)) }
}