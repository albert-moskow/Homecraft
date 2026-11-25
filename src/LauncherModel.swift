import Foundation
import AppKit
import AVFoundation

/// Общая точка входа: связывает UI и все шаги подготовки.
@MainActor
final class LauncherModel: ObservableObject {
    @Published var nickname: String = ""
    /// Адрес сервера; пусто — открыть меню «Сетевая игра».
    @Published var serverAddress: String = ""
    @Published var automaticServer: Bool = true
    @Published var checkingServers = false
    @Published var routeSummary = "Проверка двух маршрутов перед запуском"
    private var selectedRoute: String?
    @Published var memoryMB: Int = 4096
    @Published var status: String = "Готов к запуску"
    @Published var progress: Double = 0
    @Published var isBusy: Bool = false
    @Published var errorText: String?
    @Published var logTail: String = ""
    @Published var updateAvailable: String?
    @Published var packVersion: String = "—"
    @Published var microphoneAuthorized: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var microphoneStatusText: String = ""

    private let paths = Paths.standard()

    /// Пишем ход выполнения в файл: без этого зависания неотлаживаемы.
    nonisolated static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeCraft/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("launcher.log")
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: f, atomically: true, encoding: .utf8)
        }
    }
    private var gameProcess: Process?

    // Замени на свой репозиторий после загрузки на GitHub.
    nonisolated static let feedURL = "https://raw.githubusercontent.com/albert-moskow/Homecraft/main/latest.json"
    nonisolated static let packURL = "https://raw.githubusercontent.com/albert-moskow/Homecraft/main/pack.json"

    init() {
        nickname = UserDefaults.standard.string(forKey: "nickname") ?? ""
        let savedServer = UserDefaults.standard.string(forKey: "serverAddress")
        if savedServer == nil || savedServer == "vivo-figurine.tun.playit.gg:25565" {
            serverAddress = "vivo-figurine.tun.ply.gg:25565"
        } else {
            serverAddress = savedServer!
        }
        automaticServer = UserDefaults.standard.object(forKey: "automaticServer") as? Bool ?? true
        let saved = UserDefaults.standard.integer(forKey: "memoryMB")
        if saved > 0 { memoryMB = saved }
        refreshMicrophoneStatus()
    }

    func refreshMicrophoneStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneAuthorized = true
            microphoneStatusText = "Разрешён"
        case .notDetermined:
            microphoneAuthorized = false
            microphoneStatusText = "Не запрошен"
        case .denied:
            microphoneAuthorized = false
            microphoneStatusText = "Запрещён в настройках macOS"
        case .restricted:
            microphoneAuthorized = false
            microphoneStatusText = "Ограничен системой"
        @unknown default:
            microphoneAuthorized = false
            microphoneStatusText = "Неизвестно"
        }
    }

    nonisolated private static func resetMicrophoneTCC() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Microphone", "ru.homecraft.launcher"]
        try? p.run()
        p.waitUntilExit()
    }

    func ensureMicrophoneAccess(forceReset: Bool = false) async {
        let currentVersion = Update.currentVersion
        let savedVersion = UserDefaults.standard.string(forKey: "tccMicVersion")
        if forceReset || savedVersion != currentVersion {
            Self.log("resetting TCC Microphone for ru.homecraft.launcher (version \(currentVersion))")
            await Task.detached { Self.resetMicrophoneTCC() }.value
            UserDefaults.standard.set(currentVersion, forKey: "tccMicVersion")
        }

        var auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Self.log("microphone requestAccess granted=\(granted)")
            auth = AVCaptureDevice.authorizationStatus(for: .audio)
            if auth == .notDetermined && !forceReset {
                await Task.detached { Self.resetMicrophoneTCC() }.value
                NSApp.activate(ignoringOtherApps: true)
                let retryGranted = await AVCaptureDevice.requestAccess(for: .audio)
                Self.log("microphone retry requestAccess granted=\(retryGranted)")
            }
        }
        refreshMicrophoneStatus()
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    var canLaunch: Bool {
        !nickname.trimmingCharacters(in: .whitespaces).isEmpty && !isBusy && !checkingServers && gameProcess == nil
    }

    func savePrefs() {
        UserDefaults.standard.set(nickname, forKey: "nickname")
        UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
        UserDefaults.standard.set(automaticServer, forKey: "automaticServer")
        UserDefaults.standard.set(memoryMB, forKey: "memoryMB")
    }

    func checkForUpdates() {
        Task.detached {
            do {
                if let release = try Update.check(feedURL: Self.feedURL) {
                    await MainActor.run { self.updateAvailable = release.version }
                }
            } catch {
                // нет сети или ещё не загружено в git — не мешаем играть
            }
        }
    }

    func performUpdate() {
        guard !isBusy, let version = updateAvailable else { return }
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let release = try Update.check(feedURL: Self.feedURL)
                guard let release else { return }
                try Update.apply(release, paths: paths) { msg, frac in
                    Task { @MainActor in
                        self.status = msg
                        self.progress = frac
                    }
                }
                _ = version
                NSApplication.shared.terminate(nil)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// Проверки идут одновременно и не блокируют главный поток SwiftUI.
    func refreshServerRoutes() async {
        guard !checkingServers else { return }
        checkingServers = true
        defer { checkingServers = false }
        selectedRoute = nil
        routeSummary = "Проверяю РФ и международный маршрут…"
        let results = await ServerRoute.measure()
        let details = results.map { result in
            if let ms = result.milliseconds {
                return "\(result.endpoint.label): \(Int(ms.rounded())) мс"
            }
            return "\(result.endpoint.label): недоступен"
        }.joined(separator: " · ")
        if let best = ServerRoute.fastest(results) {
            selectedRoute = best.endpoint.address
            if automaticServer { serverAddress = best.endpoint.address }
            routeSummary = "\(details)\nВыбран: \(best.endpoint.label)"
        } else {
            routeSummary = "Оба адреса недоступны. Проверьте сеть или задайте адрес вручную."
        }
        Self.log("routes: \(results.map { "\($0.endpoint.address)=\($0.milliseconds.map(String.init(describing:)) ?? $0.failure ?? "недоступен")" }.joined(separator: ", "))")
    }

    func launch() {
        guard canLaunch else { return }
        if let running = gameProcess, running.isRunning {
            status = "Игра уже запущена"
            return
        }
        gameProcess = nil
        savePrefs()
        isBusy = true
        errorText = nil
        progress = 0

        Task {
            defer { isBusy = false }
            do {
                try paths.prepare()
                Self.log("prepare OK")

                status = "Проверяю доступ к микрофону"
                await ensureMicrophoneAccess()

                // 1. Java
                let java = try Java.ensure(paths: paths) { msg, frac in
                    Task { @MainActor in self.status = msg; self.progress = frac * 0.3 }
                }

                Self.log("java = \(java.path)")

                // 2. Ванильный клиент
                status = "Проверяю Minecraft 1.21.1"
                _ = try Vanilla.install(version: "1.21.1", paths: paths) { msg, frac in
                    Task { @MainActor in self.status = msg; self.progress = 0.3 + frac * 0.2 }
                }

                Self.log("vanilla OK")

                // 3. NeoForge
                let neoId = try NeoForge.install(
                    mcVersion: "1.21.1",
                    neoVersion: "21.1.267",
                    paths: paths,
                    java: java
                ) { msg, frac in
                    Task { @MainActor in self.status = msg; self.progress = 0.5 + frac * 0.15 }
                }

                Self.log("neoforge OK: \(neoId)")

                // 4. Модпак из git
                status = "Проверяю модпак"
                let data = try Net.data(Self.packURL)
                let manifest = try JSONDecoder().decode(ModpackManifest.self, from: data)
                let downloaded = try Pack.sync(manifest, paths: paths) { msg, frac in
                    Task { @MainActor in self.status = msg; self.progress = 0.65 + frac * 0.3 }
                }
                await MainActor.run { self.packVersion = manifest.version }

                status = downloaded > 0 ? "Скачано файлов: \(downloaded)" : "Модпак актуален"

                Self.log("pack OK: \(manifest.version)")

                // Проверяем маршрут после загрузок, непосредственно перед запуском игры.
                if automaticServer {
                    status = "Выбираю маршрут к HomeCraft"
                    await refreshServerRoutes()
                    guard let selectedRoute else {
                        throw LErr.launch("оба адреса HomeCraft недоступны; попробуйте позже или выберите адрес вручную")
                    }
                    serverAddress = selectedRoute
                }

                // 5. Запуск
                let opts = Launch.Options(nickname: nickname, memoryMB: memoryMB,
                                          serverAddress: serverAddress)
                let proc = try Launch.run(versionId: neoId, paths: paths, java: java, opts: opts) { msg, frac in
                    Task { @MainActor in self.status = msg; self.progress = frac }
                }
                gameProcess = proc
                isBusy = false
                status = "Игра запущена"

                Self.log("launched pid=\(proc.processIdentifier)")

                proc.terminationHandler = { p in
                    Task { @MainActor in
                        self.status = "Игра закрыта (код \(p.terminationStatus))"
                        self.gameProcess = nil
                    }
                }

                startLogTail()
            } catch {
                Self.log("FAILED: \(error.localizedDescription)")
                errorText = error.localizedDescription
                status = "Ошибка"
            }
        }
    }

    private func startLogTail() {
        let dir = paths.logs
        Task.detached {
            var lastSize: UInt64 = 0
            while true {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { continue }
                guard let newest = files
                    .filter({ $0.pathExtension == "log" })
                    .sorted(by: { a, b in
                        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        return da > db
                    }).first else { continue }

                let size = (try? FileManager.default.attributesOfItem(atPath: newest.path)[.size] as? UInt64) ?? 0
                guard size != lastSize else { continue }
                lastSize = size

                if let handle = try? FileHandle(forReadingFrom: newest) {
                    let toRead: UInt64 = 4096
                    let start = size > toRead ? size - toRead : 0
                    try? handle.seek(toOffset: start)
                    let data = (try? handle.readToEnd()) ?? Data()
                    try? handle.close()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    await MainActor.run { self.logTail = String(text.suffix(2000)) }
                }
            }
        }
    }
}
