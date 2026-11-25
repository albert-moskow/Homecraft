import Foundation

/// Личные моды игрока: `game/mods-custom`.
///
/// Общая сборка (pack.json) и серверный AutoModpack про эту папку не знают,
/// поэтому моды отсюда никогда не попадают в модпак и не уезжают на сервер.
/// Перед запуском включённые моды копируются в `mods/`, при выключении копии
/// удаляются — так их можно включать и выключать, не трогая файлы сборки.
enum CustomMods {
    static let folderName = "mods-custom"
    static let stateName = "custom-mods.json"
    static let defaultMcVersion = "1.21.1"

    struct State: Codable {
        var enabled: [String] = []
        /// Копии, созданные прошлым запуском (чистим перед новой синхронизацией).
        var applied: [String] = []
    }

    struct Meta {
        var title: String
        var version: String?
        var modId: String?
        var loader: String
        var minecraftRange: String?
        var incompatible: Bool
        var note: String?
    }

    struct Item: Identifiable {
        var name: String
        var enabled: Bool
        var meta: Meta
        var id: String { name }

        var subtitle: String {
            var parts = [name]
            if let version = meta.version, !version.isEmpty { parts.append("v\(version)") }
            if let range = meta.minecraftRange, !range.isEmpty { parts.append("MC \(range)") }
            if meta.loader == "fabric" { parts.append("Fabric-мод — NeoForge его не загрузит") }
            if meta.incompatible { parts.append("⚠︎ не для \(CustomMods.defaultMcVersion)") }
            if let note = meta.note, !note.isEmpty { parts.append(note) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Пути и состояние

    static func folder(for paths: Paths) -> URL {
        paths.game.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func stateURL(for paths: Paths) -> URL {
        paths.game.appendingPathComponent(stateName)
    }

    static func loadState(_ paths: Paths) -> State {
        guard let data = try? Data(contentsOf: stateURL(for: paths)),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    static func saveState(_ state: State, _ paths: Paths) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL(for: paths))
        }
    }

    // MARK: - Список

    static func items(_ paths: Paths, mcVersion: String = defaultMcVersion) -> [Item] {
        let state = loadState(paths)
        let dir = folder(for: paths)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names
            .filter { $0.lowercased().hasSuffix(".jar") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let meta = readMeta(dir.appendingPathComponent(name), mcVersion: mcVersion)
                return Item(name: name, enabled: state.enabled.contains(name), meta: meta)
            }
    }

    // MARK: - Добавление и удаление

    /// Копирует выбранные `.jar` в `mods-custom` и сразу включает их.
    @discardableResult
    static func install(_ urls: [URL], paths: Paths) throws -> [String] {
        let dir = folder(for: paths)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = loadState(paths)
        var added: [String] = []

        for url in urls where url.pathExtension.lowercased() == "jar" {
            let base = url.deletingPathExtension().lastPathComponent
            var name = url.lastPathComponent
            var dest = dir.appendingPathComponent(name)
            var counter = 2
            while FileManager.default.fileExists(atPath: dest.path) {
                name = "\(base)-\(counter).jar"
                dest = dir.appendingPathComponent(name)
                counter += 1
            }
            try FileManager.default.copyItem(at: url, to: dest)
            if !state.enabled.contains(name) { state.enabled.append(name) }
            added.append(name)
        }

        saveState(state, paths)
        return added
    }

    static func setEnabled(_ name: String, _ enabled: Bool, paths: Paths) {
        var state = loadState(paths)
        state.enabled.removeAll { $0 == name }
        if enabled { state.enabled.append(name) }
        saveState(state, paths)
    }

    static func remove(_ name: String, paths: Paths) {
        var state = loadState(paths)
        state.enabled.removeAll { $0 == name }
        saveState(state, paths)
        try? FileManager.default.removeItem(at: folder(for: paths).appendingPathComponent(name))
        apply(paths: paths)
    }

    // MARK: - Подключение к игре

    /// Синхронизирует `mods/`: удаляет старые копии и копирует включённые моды.
    /// Файлы общей сборки не перезаписываются — при совпадении имени копия
    /// получает префикс `user-`.
    static func apply(paths: Paths, log: ((String) -> Void)? = nil) {
        let fm = FileManager.default
        let modsDir = paths.game.appendingPathComponent("mods", isDirectory: true)
        try? fm.createDirectory(at: modsDir, withIntermediateDirectories: true)

        var state = loadState(paths)
        for name in state.applied {
            try? fm.removeItem(at: modsDir.appendingPathComponent(name))
        }
        state.applied = []

        let packPaths = packFilePaths(paths)
        let src = folder(for: paths)

        for name in state.enabled {
            let from = src.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else {
                log?("custom mod missing: \(name)")
                continue
            }

            var target = name
            if packPaths.contains("mods/\(name)")
                || fm.fileExists(atPath: modsDir.appendingPathComponent(name).path) {
                target = "user-" + name
            }
            let dest = modsDir.appendingPathComponent(target)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: from, to: dest)
                state.applied.append(target)
                log?("custom mod enabled: \(target)")
            } catch {
                log?("custom mod failed: \(name): \(error.localizedDescription)")
            }
        }

        saveState(state, paths)
    }

    /// Пути, которыми владеет модпак (из `pack-state.json`).
    private static func packFilePaths(_ paths: Paths) -> Set<String> {
        let file = paths.game.appendingPathComponent(Pack.stateFile)
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [String: String] else {
            return []
        }
        return Set(files.keys)
    }

    // MARK: - Метаданные мода

    static func readMeta(_ jar: URL, mcVersion: String = defaultMcVersion) -> Meta {
        let fallbackTitle = jar.deletingPathExtension().lastPathComponent

        if let toml = archiveEntry(jar, "META-INF/neoforge.mods.toml")
            ?? archiveEntry(jar, "META-INF/mods.toml") {
            let section = modsSection(toml)
            let title = value(in: section, key: "displayName")
                ?? value(in: section, key: "modId")
                ?? fallbackTitle
            let range = minecraftRange(in: toml)
            var incompatible = false
            if let range, let ok = rangeContains(range, mcVersion) { incompatible = !ok }
            return Meta(
                title: title,
                version: value(in: section, key: "version"),
                modId: value(in: section, key: "modId"),
                loader: "neoforge",
                minecraftRange: range,
                incompatible: incompatible,
                note: nil)
        }

        if let json = archiveEntry(jar, "fabric.mod.json"),
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let title = object["name"] as? String ?? object["id"] as? String ?? fallbackTitle
            return Meta(
                title: title,
                version: object["version"] as? String,
                modId: object["id"] as? String,
                loader: "fabric",
                minecraftRange: nil,
                incompatible: false,
                note: nil)
        }

        return Meta(
            title: fallbackTitle,
            version: nil,
            modId: nil,
            loader: "unknown",
            minecraftRange: nil,
            incompatible: false,
            note: "не мод NeoForge — игра его не загрузит")
    }

    /// Читает один файл из zip через системный `unzip` (он есть в macOS всегда).
    private static func archiveEntry(_ jar: URL, _ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", jar.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Читаем до ожидания: иначе большой файл заполнит буфер канала.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Первая секция `[[mods]]`: именно там лежат название и версия мода.
    private static func modsSection(_ text: String) -> String {
        guard let start = text.range(of: "[[mods]]") else { return text }
        let rest = text[start.upperBound...]
        if let next = rest.range(of: "\n[[") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    private static func minecraftRange(in text: String) -> String? {
        for block in text.components(separatedBy: "[[") {
            guard let id = value(in: block, key: "modId"), id == "minecraft" else { continue }
            if let range = value(in: block, key: "versionRange") { return range }
        }
        return nil
    }

    private static func value(in text: String, key: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix(key) else { continue }
            let afterKey = String(trimmed.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            guard afterKey.hasPrefix("=") else { continue }
            var value = String(afterKey.dropFirst()).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value = String(value.dropFirst())
                if let end = value.firstIndex(of: "\"") { return String(value[..<end]) }
            } else {
                if let end = value.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    value = String(value[..<end])
                }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// Проверяет maven-диапазон (`[1.21.1,1.22)`) на попадание версии.
    static func rangeContains(_ raw: String, _ version: String) -> Bool? {
        let range = raw.trimmingCharacters(in: .whitespaces)
        if range.isEmpty || range == "*" || range == "any" { return true }
        guard let first = range.first, let last = range.last else { return nil }
        guard "[(".contains(first), "])".contains(last) else {
            return compare(version, range).map { $0 == 0 }
        }

        let parts = range.dropFirst().dropLast()
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        if parts.count == 1 {
            if parts[0].isEmpty { return true }
            return compare(version, parts[0]).map { $0 == 0 }
        }
        guard parts.count == 2 else { return nil }

        if !parts[0].isEmpty, let cmp = compare(version, parts[0]) {
            if first == "[" {
                if cmp < 0 { return false }
            } else if cmp <= 0 {
                return false
            }
        }
        if !parts[1].isEmpty, let cmp = compare(version, parts[1]) {
            if last == "]" {
                if cmp > 0 { return false }
            } else if cmp >= 0 {
                return false
            }
        }
        return true
    }

    private static func compare(_ a: String, _ b: String) -> Int? {
        func numbers(_ value: String) -> [Int] {
            var result: [Int] = []
            for part in value.split(separator: ".") {
                let digits = part.prefix { $0.isNumber }
                guard !digits.isEmpty, let number = Int(digits) else { break }
                result.append(number)
                if digits.count != part.count { break }
            }
            return result
        }
        let left = numbers(a)
        let right = numbers(b)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        for i in 0..<max(left.count, right.count) {
            let l = i < left.count ? left[i] : 0
            let r = i < right.count ? right[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
