import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: LauncherModel
    @State private var showLog = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.13),
                                    Color(red: 0.14, green: 0.12, blue: 0.18)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider().overlay(Color.white.opacity(0.08))
                main
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Левая панель

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HomeCraft")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("NeoForge 1.21.1")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 10) {
                Text("Никнейм")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Steve", text: $model.nickname)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1)))
                    .foregroundStyle(.white)
                    .onSubmit { model.savePrefs() }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Память")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Text("\(model.memoryMB) МБ")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
                Slider(value: Binding(
                    get: { Double(model.memoryMB) },
                    set: { model.memoryMB = Int($0) }
                ), in: 2048...8192, step: 512)
                .tint(Color(red: 0.55, green: 0.45, blue: 0.95))
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Модпак", model.packVersion)
                infoRow("Версия лаунчера", Update.currentVersion)
            }

            if let update = model.updateAvailable {
                Button {
                    model.performUpdate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Обновить до \(update)")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.35, green: 0.65, blue: 0.45)))
                .foregroundStyle(.white)
            }
        }
        .padding(20)
        .frame(width: 260)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Правая панель

    private var main: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 22) {
                Image(systemName: "cube.fill")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(red: 0.65, green: 0.55, blue: 1.0),
                                                Color(red: 0.95, green: 0.55, blue: 0.75)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )

                VStack(spacing: 8) {
                    Text(model.status)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    if model.isBusy {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                            .tint(Color(red: 0.6, green: 0.5, blue: 1.0))
                            .frame(width: 320)
                    }

                    if let err = model.errorText {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                            .textSelection(.enabled)
                    }
                }

                Button {
                    model.launch()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text(model.isBusy ? "Подготовка…" : "Играть")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(width: 220, height: 46)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(model.canLaunch
                              ? LinearGradient(colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                                        Color(red: 0.62, green: 0.35, blue: 0.85)],
                                               startPoint: .leading, endPoint: .trailing)
                              : LinearGradient(colors: [.gray.opacity(0.3), .gray.opacity(0.3)],
                                               startPoint: .leading, endPoint: .trailing))
                )
                .foregroundStyle(.white)
                .disabled(!model.canLaunch)

                Button {
                    showLog.toggle()
                } label: {
                    Text(showLog ? "Скрыть лог" : "Показать лог")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }

            if showLog {
                ScrollView {
                    Text(model.logTail.isEmpty ? "Лог пуст" : model.logTail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
                .padding(.horizontal, 30)
                .padding(.top, 20)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }
}