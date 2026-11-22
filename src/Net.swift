import Foundation
import CryptoKit

enum Net {
    static func data(_ url: String, timeout: TimeInterval = 30) throws -> Data {
        guard let u = URL(string: url) else { throw LErr.badURL(url) }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue("HomeCraftLauncher/1.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var err: Error?
        let task = URLSession.shared.dataTask(with: req) { d, r, e in
            if let e { err = e }
            if let http = r as? HTTPURLResponse, http.statusCode >= 400 {
                err = LErr.http(http.statusCode, url)
            }
            out = d
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw LErr.timeout(url)
        }
        if let err { throw err }
        guard let out else { throw LErr.empty(url) }
        return out
    }

    /// Размер файла по HEAD (0 если неизвестен).
    static func remoteSize(_ url: String) -> Int64 {
        guard let u = URL(string: url) else { return 0 }
        var req = URLRequest(url: u)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var size: Int64 = 0
        let task = URLSession.shared.dataTask(with: req) { _, r, _ in
            if let http = r as? HTTPURLResponse { size = http.expectedContentLength }
            sem.signal()
        }
        task.resume()
        // Если HEAD не отвечает за 20 с — не блокируем загрузку, размер узнаем по факту.
        if sem.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            return 0
        }
        return max(0, size)
    }

    /// Скачивание в файл с проверкой sha1 и прогрессом 0…1.
    static func download(_ url: String, to dest: URL, expectedSha1: String? = nil,
                         onProgress: ((Double) -> Void)? = nil) throws {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        if let want = expectedSha1, FileManager.default.fileExists(atPath: dest.path),
           let got = try? sha1(of: dest), got == want {
            onProgress?(1)
            return
        }

        guard let u = URL(string: url) else { throw LErr.badURL(url) }
        var req = URLRequest(url: u)
        req.timeoutInterval = 300
        req.setValue("HomeCraftLauncher/1.0", forHTTPHeaderField: "User-Agent")

        let total = remoteSize(url)
        let tmp = dest.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tmp)

        let sem = DispatchSemaphore(value: 0)
        var err: Error?
        let task = URLSession.shared.downloadTask(with: req) { location, response, e in
            defer { sem.signal() }
            if let e { err = e; return }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                err = LErr.http(http.statusCode, url); return
            }
            guard let location else { err = LErr.empty(url); return }
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.moveItem(at: location, to: tmp)
            } catch { err = error }
        }
        task.resume()

        while sem.wait(timeout: .now() + 0.2) == .timedOut {
            if total > 0,
               let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path),
               let size = attrs[.size] as? Int64 {
                onProgress?(min(0.99, Double(size) / Double(total)))
            }
        }
        if let err { try? FileManager.default.removeItem(at: tmp); throw err }

        if let want = expectedSha1 {
            let got = try sha1(of: tmp)
            guard got == want else {
                try? FileManager.default.removeItem(at: tmp)
                throw LErr.checksum(dest.lastPathComponent, want, got)
            }
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onProgress?(1)
    }

    static func sha1(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum LErr: LocalizedError {
    case badURL(String), http(Int, String), empty(String), checksum(String, String, String)
    case java(String), launch(String), update(String), manifest(String)
    case timeout(String), notFound(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let u): return "Некорректный адрес: \(u)"
        case .http(let c, let u): return "HTTP \(c) для \(u)"
        case .empty(let u): return "Пустой ответ: \(u)"
        case .checksum(let f, let w, let g):
            return "Хеш не совпал у \(f)\nожидался \(w.prefix(12))…\nполучен  \(g.prefix(12))…"
        case .java(let m): return "Java: \(m)"
        case .launch(let m): return "Запуск: \(m)"
        case .update(let m): return "Обновление: \(m)"
        case .manifest(let m): return "Манифест: \(m)"
        case .timeout(let u): return "Нет ответа за отведённое время: \(u)"
        case .notFound(let u): return "Файл не найден (404): \(u)"
        }
    }
}