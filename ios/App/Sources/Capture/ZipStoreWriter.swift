import Foundation

enum ZipStoreWriter {
    static func zipDirectory(_ directoryURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let fileURLs = try fileManager.subpathsOfDirectory(atPath: directoryURL.path)
            .map { directoryURL.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.path < $1.path }

        fileManager.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var centralDirectory = Data()
        var offset: UInt32 = 0

        for fileURL in fileURLs {
            let data = try Data(contentsOf: fileURL)
            let relativeName = fileURL.path
                .replacingOccurrences(of: directoryURL.path + "/", with: "")
            let nameData = Data(relativeName.utf8)
            let crc = CRC32.checksum(data)

            var local = Data()
            local.appendUInt32(0x04034b50)
            local.appendUInt16(20)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt16(0)
            local.appendUInt32(crc)
            local.appendUInt32(UInt32(data.count))
            local.appendUInt32(UInt32(data.count))
            local.appendUInt16(UInt16(nameData.count))
            local.appendUInt16(0)
            local.append(nameData)
            local.append(data)
            try handle.write(contentsOf: local)

            var central = Data()
            central.appendUInt32(0x02014b50)
            central.appendUInt16(20)
            central.appendUInt16(20)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(data.count))
            central.appendUInt32(UInt32(data.count))
            central.appendUInt16(UInt16(nameData.count))
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt16(0)
            central.appendUInt32(0)
            central.appendUInt32(offset)
            central.append(nameData)
            centralDirectory.append(central)

            offset += UInt32(local.count)
        }

        let centralDirectoryOffset = offset
        try handle.write(contentsOf: centralDirectory)
        offset += UInt32(centralDirectory.count)

        var end = Data()
        end.appendUInt32(0x06054b50)
        end.appendUInt16(0)
        end.appendUInt16(0)
        end.appendUInt16(UInt16(fileURLs.count))
        end.appendUInt16(UInt16(fileURLs.count))
        end.appendUInt32(UInt32(centralDirectory.count))
        end.appendUInt32(centralDirectoryOffset)
        end.appendUInt16(0)
        try handle.write(contentsOf: end)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xedb88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
}
