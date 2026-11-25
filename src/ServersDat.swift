import Foundation

/// Автоматическое добавление серверов HomeCraft в `servers.dat` (формат NBT без сжатия),
/// чтобы они всегда были в меню «Сетевая игра» (Multiplayer).
enum ServersDat {
    struct Entry {
        let name: String
        let ip: String
    }

    static let defaultEntries: [Entry] = [
        Entry(name: "HomeCraft (РФ)", ip: "homecraft.p7z.ru:25565"),
        Entry(name: "HomeCraft (Международный)", ip: "vivo-figurine.tun.ply.gg:25565")
    ]

    /// Обеспечивает наличие серверов HomeCraft в `game/servers.dat`, сохраняя уже добавленные игроком сервера.
    static func ensure(in gameDir: URL, preferredAddress: String? = nil) {
        let fileURL = gameDir.appendingPathComponent("servers.dat")
        var entries = defaultEntries
        if let pref = preferredAddress?.trimmingCharacters(in: .whitespaces), !pref.isEmpty {
            entries.sort { a, b in
                let aMatch = normalize(a.ip) == normalize(pref)
                let bMatch = normalize(b.ip) == normalize(pref)
                if aMatch != bMatch { return aMatch }
                return false
            }
        }

        if let data = try? Data(contentsOf: fileURL),
           let merged = try? mergeExisting(data: data, required: entries) {
            try? merged.write(to: fileURL, options: .atomic)
            return
        }

        let fresh = buildFresh(entries: entries)
        try? fresh.write(to: fileURL, options: .atomic)
    }

    private static func normalize(_ ip: String) -> String {
        let lower = ip.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix(":25565") {
            return String(lower.dropLast(":25565".count))
        }
        return lower
    }

    private static func buildFresh(entries: [Entry]) -> Data {
        var out = Data()
        // Root TAG_Compound ("")
        out.append(0x0A)
        out.appendUInt16BE(0)

        // TAG_List ("servers") of TAG_Compound (0x0A)
        out.append(0x09)
        out.appendNBTString("servers")
        out.append(0x0A)
        out.appendUInt32BE(UInt32(entries.count))

        for entry in entries {
            out.append(encodeServerCompound(entry))
        }

        // Root TAG_End
        out.append(0x00)
        return out
    }

    private static func encodeServerCompound(_ entry: Entry) -> Data {
        var item = Data()
        // TAG_String "name"
        item.append(0x08)
        item.appendNBTString("name")
        item.appendNBTString(entry.name)

        // TAG_String "ip"
        item.append(0x08)
        item.appendNBTString("ip")
        item.appendNBTString(entry.ip)

        // TAG_Byte "acceptTextures" = 1
        item.append(0x01)
        item.appendNBTString("acceptTextures")
        item.append(0x01)

        // TAG_Byte "hidden" = 0
        item.append(0x01)
        item.appendNBTString("hidden")
        item.append(0x00)

        // Compound TAG_End
        item.append(0x00)
        return item
    }

    /// Читает существующий `servers.dat`, проверяет список `servers` и добавляет недостающие адреса HomeCraft в начало списка.
    private static func mergeExisting(data: Data, required: [Entry]) throws -> Data {
        var cursor = NBTCursor(data: data)
        guard try cursor.readByte() == 0x0A else { throw NBTErr.badFormat }
        _ = try cursor.readString() // root name ""

        var rawServers: [(ip: String?, bytes: Data)] = []
        var otherRootFields = Data()
        var foundServersList = false

        while true {
            let tagType = try cursor.readByte()
            if tagType == 0x00 { break }
            let fieldStart = cursor.offset - 1
            let name = try cursor.readString()

            if tagType == 0x09 && name == "servers" {
                foundServersList = true
                let elemType = try cursor.readByte()
                let count = Int(try cursor.readInt32())
                if elemType == 0x0A && count >= 0 && count < 10_000 {
                    for _ in 0..<count {
                        let itemStart = cursor.offset
                        let ip = try cursor.scanCompoundForIP()
                        let itemEnd = cursor.offset
                        rawServers.append((ip: ip, bytes: data.subdata(in: itemStart..<itemEnd)))
                    }
                } else if count > 0 {
                    for _ in 0..<count {
                        try cursor.skipPayload(type: elemType)
                    }
                }
            } else {
                try cursor.skipPayload(type: tagType)
                let fieldEnd = cursor.offset
                otherRootFields.append(data.subdata(in: fieldStart..<fieldEnd))
            }
        }

        guard foundServersList else { throw NBTErr.badFormat }

        let existingNorm = Set(rawServers.compactMap { $0.ip.map(normalize) })
        var finalItems: [Data] = []

        for req in required where !existingNorm.contains(normalize(req.ip)) {
            finalItems.append(encodeServerCompound(req))
        }
        for existing in rawServers {
            finalItems.append(existing.bytes)
        }

        var out = Data()
        out.append(0x0A)
        out.appendUInt16BE(0)
        out.append(otherRootFields)
        out.append(0x09)
        out.appendNBTString("servers")
        out.append(0x0A)
        out.appendUInt32BE(UInt32(finalItems.count))
        for item in finalItems {
            out.append(item)
        }
        out.append(0x00)
        return out
    }

    private enum NBTErr: Error {
        case badFormat
    }

    private struct NBTCursor {
        let data: Data
        var offset: Int = 0

        mutating func readByte() throws -> UInt8 {
            guard offset < data.count else { throw NBTErr.badFormat }
            let b = data[data.startIndex + offset]
            offset += 1
            return b
        }

        mutating func readUInt16() throws -> UInt16 {
            let b0 = UInt16(try readByte())
            let b1 = UInt16(try readByte())
            return (b0 << 8) | b1
        }

        mutating func readInt32() throws -> Int32 {
            let b0 = UInt32(try readByte())
            let b1 = UInt32(try readByte())
            let b2 = UInt32(try readByte())
            let b3 = UInt32(try readByte())
            return Int32(bitPattern: (b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= data.count else { throw NBTErr.badFormat }
            offset += count
        }

        mutating func readString() throws -> String {
            let len = Int(try readUInt16())
            guard offset + len <= data.count else { throw NBTErr.badFormat }
            let sub = data.subdata(in: offset..<(offset + len))
            offset += len
            return String(data: sub, encoding: .utf8) ?? ""
        }

        mutating func scanCompoundForIP() throws -> String? {
            var foundIP: String?
            while true {
                let t = try readByte()
                if t == 0x00 { break }
                let name = try readString()
                if t == 0x08 && name == "ip" {
                    foundIP = try readString()
                } else {
                    try skipPayload(type: t)
                }
            }
            return foundIP
        }

        mutating func skipPayload(type: UInt8) throws {
            switch type {
            case 1: try skip(1)
            case 2: try skip(2)
            case 3, 5: try skip(4)
            case 4, 6: try skip(8)
            case 7:
                let n = Int(try readInt32())
                try skip(n)
            case 8:
                let n = Int(try readUInt16())
                try skip(n)
            case 9:
                let elem = try readByte()
                let n = Int(try readInt32())
                if n > 0 {
                    for _ in 0..<n { try skipPayload(type: elem) }
                }
            case 10:
                while true {
                    let t = try readByte()
                    if t == 0x00 { break }
                    _ = try readString()
                    try skipPayload(type: t)
                }
            case 11:
                let n = Int(try readInt32())
                try skip(n * 4)
            case 12:
                let n = Int(try readInt32())
                try skip(n * 8)
            default:
                throw NBTErr.badFormat
            }
        }
    }
}

private extension Data {
    mutating func appendUInt16BE(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendUInt32BE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendNBTString(_ s: String) {
        let utf8 = Array(s.utf8)
        appendUInt16BE(UInt16(clamping: utf8.count))
        append(contentsOf: utf8)
    }
}
