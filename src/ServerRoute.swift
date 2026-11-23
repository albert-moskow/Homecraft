import Foundation
import Network

/// Проверяем именно Minecraft Status + Ping/Pong, а не ICMP или открытый TCP-порт.
/// Таймаут охватывает DNS, соединение и весь обмен. Время включает установку TCP.
enum ServerRoute {
    struct Endpoint: Sendable {
        let host: String
        let label: String
        let port: UInt16
        var address: String { "\(host):\(port)" }
    }

    struct Result: Sendable {
        let endpoint: Endpoint
        let milliseconds: Double?
        let failure: String?
    }

    static let endpoints = [
        Endpoint(host: "homecraft.p7z.ru", label: "РФ", port: 25565),
        Endpoint(host: "vivo-figurine.tun.ply.gg", label: "Международный", port: 25565)
    ]

    static func measure(endpoints: [Endpoint] = endpoints, timeout: Double = 5) async -> [Result] {
        await withTaskGroup(of: (Int, Result).self) { group in
            for (index, endpoint) in endpoints.enumerated() {
                group.addTask {
                    do {
                        let ms = try await Probe(endpoint: endpoint, timeout: timeout).run()
                        return (index, Result(endpoint: endpoint, milliseconds: ms, failure: nil))
                    } catch {
                        return (index, Result(endpoint: endpoint, milliseconds: nil,
                                              failure: error.localizedDescription))
                    }
                }
            }
            var results: [(Int, Result)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func fastest(_ results: [Result]) -> Result? {
        results.filter { $0.milliseconds != nil }.min { $0.milliseconds! < $1.milliseconds! }
    }

    private enum ProbeError: LocalizedError {
        case timeout, invalidReply, closed, incompatible
        var errorDescription: String? {
            switch self {
            case .timeout: return "таймаут"
            case .invalidReply: return "неверный ответ Minecraft"
            case .closed: return "соединение закрыто"
            case .incompatible: return "сервер не Minecraft 1.21.1"
            }
        }
    }

    /// Всё состояние обмена принадлежит одной последовательной очереди NWConnection.
    private final class Probe: @unchecked Sendable {
        let endpoint: Endpoint
        let timeout: Double
        let queue = DispatchQueue(label: "HomeCraft.minecraft-status")
        var connection: NWConnection?
        var continuation: CheckedContinuation<Double, Error>?
        var started: UInt64 = 0
        var buffer = Data()
        var awaitingPong = false
        var finished = false
        let nonce = Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })

        init(endpoint: Endpoint, timeout: Double) {
            self.endpoint = endpoint
            self.timeout = timeout
        }

        func run() async throws -> Double {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    self.started = DispatchTime.now().uptimeNanoseconds
                    let connection = NWConnection(host: NWEndpoint.Host(self.endpoint.host),
                                                  port: NWEndpoint.Port(rawValue: self.endpoint.port)!,
                                                  using: .tcp)
                    self.connection = connection
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: self.handshake()
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + self.timeout) {
                        self.finish(.failure(ProbeError.timeout))
                    }
                }
            }
        }

        func finish(_ result: Swift.Result<Double, Error>) {
            guard !finished else { return }
            finished = true
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            continuation?.resume(with: result)
            continuation = nil
        }

        static func varInt(_ value: Int) -> Data {
            var value = value
            var data = Data()
            repeat {
                var byte = UInt8(value & 127)
                value >>= 7
                if value != 0 { byte |= 128 }
                data.append(byte)
            } while value != 0
            return data
        }

        static func readVarInt(_ data: Data, offset: inout Int) throws -> Int? {
            var value = 0
            for shift in 0..<5 {
                guard offset < data.count else { return nil }
                let byte = data[offset]
                offset += 1
                value |= Int(byte & 127) << (shift * 7)
                if byte & 128 == 0 { return value }
            }
            throw ProbeError.invalidReply
        }

        func handshake() {
            guard !finished else { return }
            let host = Data(endpoint.host.utf8)
            var packet = Data([0])
            packet.append(Self.varInt(767)) // Minecraft Java 1.21.1
            packet.append(Self.varInt(host.count))
            packet.append(host)
            packet.append(UInt8(endpoint.port >> 8))
            packet.append(UInt8(endpoint.port & 255))
            packet.append(1) // next state: Status
            var request = Self.varInt(packet.count)
            request.append(packet)
            request.append(contentsOf: [1, 0]) // Status request
            send(request)
        }

        func send(_ data: Data) {
            connection?.send(content: data, completion: .contentProcessed { error in
                if let error { self.finish(.failure(error)) }
                else { self.receive() }
            })
        }

        func receive() {
            guard !finished else { return }
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, closed, error in
                guard !self.finished else { return }
                if let error { self.finish(.failure(error)); return }
                if let data { self.buffer.append(data) }
                do {
                    guard self.buffer.count <= 1_048_581 else { throw ProbeError.invalidReply }
                    var offset = 0
                    guard let size = try Self.readVarInt(self.buffer, offset: &offset) else {
                        if closed { throw ProbeError.closed }
                        self.receive(); return
                    }
                    guard size > 0, size <= 1_048_576 else { throw ProbeError.invalidReply }
                    guard self.buffer.count >= offset + size else {
                        if closed { throw ProbeError.closed }
                        self.receive(); return
                    }
                    let packet = Data(self.buffer[offset..<offset + size])
                    self.buffer = Data(self.buffer.dropFirst(offset + size))
                    try self.handle(packet)
                } catch { self.finish(.failure(error)) }
            }
        }

        func handle(_ packet: Data) throws {
            var offset = 0
            guard let id = try Self.readVarInt(packet, offset: &offset) else { throw ProbeError.invalidReply }
            if awaitingPong {
                guard id == 1, packet.count - offset == 8,
                      packet.suffix(8) == nonce else { throw ProbeError.invalidReply }
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                finish(.success(Double(elapsed) / 1_000_000))
            } else {
                guard id == 0, let size = try Self.readVarInt(packet, offset: &offset),
                      size == packet.count - offset,
                      let json = try JSONSerialization.jsonObject(with: Data(packet.dropFirst(offset))) as? [String: Any],
                      let version = json["version"] as? [String: Any],
                      let protocolID = version["protocol"] as? Int else { throw ProbeError.invalidReply }
                guard protocolID == 767 else { throw ProbeError.incompatible }
                awaitingPong = true
                var ping = Data([9, 1])
                ping.append(nonce)
                send(ping)
            }
        }
    }
}
