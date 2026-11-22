import Foundation

/// Описание удалённого источника: git-хостинг с манифестами.
struct RemoteConfig: Codable {
    var launcherVersionURL: String
    var modpackManifestURL: String
    var newsURL: String?
    var javaVersion: Int
    var minecraftVersion: String
    var neoForgeVersion: String
}

/// Описание одного файла модпака.
struct PackFile: Codable, Identifiable {
    var path: String        // относительно game dir, напр. "mods/sodium.jar"
    var url: String
    var sha1: String
    var size: Int64
    var side: String        // "client" | "both"
    var id: String { path }
}

struct ModpackManifest: Codable {
    var version: String
    var name: String
    var minecraftVersion: String
    var neoForgeVersion: String
    var files: [PackFile]
    var jvmArgs: [String]?
    var removePaths: [String]?  // что удалить у клиента (устаревшие моды)
}

struct LauncherRelease: Codable {
    var version: String
    var url: String
    var sha256: String
    var notes: String?
}

/// Состояние прогресса для UI.
final class Progress: ObservableObject {
    @Published var message: String = "Готов"
    @Published var fraction: Double = 0
    @Published var isBusy: Bool = false
}