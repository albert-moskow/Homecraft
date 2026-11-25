import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var showLog = false
    @State private var showSettings = false
    @State private var showCustomMods = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                                    Color(red: 0.14, green: 0.12, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            // Кнопка привязана к центру окна, независимо от статуса и логов.
            playButton
                .overlay(alignment: .bottom) {
                    VStack(spacing: 10) {
                        Image(systemName: "cube.fill")
                            .font(.system(size: 46, weight: .light))
                            .foregroundStyle(.purple)
                        Text("HomeCraft")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("NeoForge 1.21.1")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 80)
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 10) {
                        Text(model.status)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if model.isBusy {
                            ProgressView(value: model.progress)
                                .frame(width: 300)
                                .tint(.purple)
                        }
                        if let error = model.errorText {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 480)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                        if model.nickname.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Указать ник в настройках") { showSettings = true }
                        }
                        if !model.microphoneAuthorized {
                            HStack(spacing: 10) {
                                Button("Разрешить микрофон для Voice Chat") {
                                    Task { await model.ensureMicrophoneAccess(forceReset: true) }
                                }
                                Button("Настройки macOS") {
                                    model.openMicrophoneSettings()
                                }
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.top, 64)
                }

            VStack {
                HStack {
                    if let version = model.updateAvailable {
                        Button("Обновить до \(version)") { model.performUpdate() }
                            .disabled(model.isBusy)
                    }
                    Spacer()
                    Button { showCustomMods = true } label: {
                        Label(model.customMods.isEmpty
                              ? "Свои моды"
                              : "Свои моды (\(model.customMods.filter(\.enabled).count))",
                              systemImage: "shippingbox")
                    }
                    Button { showSettings = true } label: {
                        Label("Настройки", systemImage: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                Spacer()
                if showLog {
                    ScrollView {
                        Text(model.logTail.isEmpty ? "Лог пуст" : model.logTail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .textSelection(.enabled)
                    }
                    .frame(height: 100)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
                }
                HStack {
                    Text("Лаунчер \(Update.currentVersion) · Модпак \(model.packVersion)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(showLog ? "Скрыть лог" : "Показать лог") { showLog.toggle() }
                        .font(.system(size: 11))
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings, onDismiss: { model.savePrefs() }) {
            LauncherSettingsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showCustomMods) {
            CustomModsView()
                .environmentObject(model)
        }
    }

    private var playButton: some View {
        Button { model.launch() } label: {
            Label(model.isBusy ? "Подготовка…" : "Играть", systemImage: "play.fill")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 240, height: 54)
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(
            model.canLaunch
            ? LinearGradient(colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                      Color(red: 0.62, green: 0.35, blue: 0.85)],
                             startPoint: .leading, endPoint: .trailing)
            : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                             startPoint: .leading, endPoint: .trailing)))
        .foregroundStyle(.white)
        .disabled(!model.canLaunch)
    }
}

private struct LauncherSettingsView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Настройки")
                .font(.system(size: 24, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 8) {
                Text("Никнейм").font(.headline)
                TextField("Steve", text: $model.nickname)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.nickname")
            }
            .disabled(model.isBusy)

            VStack(alignment: .leading, spacing: 8) {
                Text("Сервер").font(.headline)
                Toggle("Выбирать автоматически", isOn: $model.automaticServer)
                    .disabled(model.isBusy)
                TextField("адрес:порт", text: $model.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("settings.server")
                    .disabled(model.automaticServer || model.isBusy)
                Text(model.routeSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.checkingServers ? "Проверяю…" : "Проверить маршруты") {
                    Task { await model.refreshServerRoutes() }
                }
                .disabled(model.checkingServers || model.isBusy)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Память").font(.headline)
                    Spacer()
                    Text("\(model.memoryMB) МБ")
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(model.memoryMB) },
                    set: { model.memoryMB = Int($0) }
                ), in: 2048...8192, step: 512)
                    .tint(.purple)
                    .accessibilityLabel("Память Minecraft")
            }
            .disabled(model.isBusy)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Микрофон (Voice Chat)").font(.headline)
                    Spacer()
                    Text(model.microphoneStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(model.microphoneAuthorized ? .green : .orange)
                }
                HStack(spacing: 10) {
                    Button("Запросить разрешение") {
                        Task { await model.ensureMicrophoneAccess(forceReset: true) }
                    }
                    Button("Открыть настройки macOS") {
                        model.openMicrophoneSettings()
                    }
                }
            }
            .disabled(model.isBusy)

            HStack {
                Spacer()
                Button("Готово") {
                    model.savePrefs()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(28)
        .frame(width: 440)
        .preferredColorScheme(.dark)
    }
}

/// Личные моды игрока: лежат только у него и не входят в общую сборку.
private struct CustomModsView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Свои моды")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Text("Эти моды хранятся только у вас, в папке mods-custom: они не входят в общую сборку, не скачиваются другим игрокам и не попадают на сервер. Включённые моды подключаются при запуске игры.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.personalPacks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Готовые наборы")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(model.personalPacks) { pack in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pack.name)
                                    .font(.system(size: 12, weight: .medium))
                                Text(pack.description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if model.installingPacks.contains(pack.id) {
                                ProgressView()
                                    .controlSize(.small)
                            } else if model.installedPacks.contains(pack.id) {
                                Text("Установлено")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Установить") { model.installPersonalPack(pack) }
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
                    }
                }
            }

            if model.customMods.isEmpty {
                Text("Пока пусто. Нажмите «Добавить .jar…» или положите файлы в папку mods-custom.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.customMods) { mod in
                            row(mod)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 300)
            }

            if let message = model.customModsMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Добавить .jar…") { chooseFiles() }
                Button("Открыть папку") { model.openCustomModsFolder() }
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
            }
        }
        .padding(24)
        .frame(width: 540)
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshCustomMods()
            model.loadPersonalPacks()
        }
    }

    private func row(_ mod: CustomMods.Item) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { mod.enabled },
                set: { model.setCustomMod(mod.name, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(mod.meta.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(mod.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(mod.meta.incompatible ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                model.deleteCustomMod(mod.name)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Удалить мод из папки mods-custom")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Добавить свои моды"
        panel.message = "Выберите .jar для NeoForge 1.21.1. Моды останутся только у вас."
        panel.allowedContentTypes = [UTType(filenameExtension: "jar")].compactMap { $0 }
        if panel.runModal() == .OK {
            model.addCustomMods(panel.urls)
        }
    }
}
