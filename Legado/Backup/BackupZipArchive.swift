import Foundation
import zlib

struct BackupArchiveEntry {
    let path: String
    let data: Data
}

enum BackupZipArchiveError: LocalizedError {
    case invalidArchive(String)
    case unsupportedCompressionMethod(UInt16)
    case unsupportedFlags(UInt16)
    case invalidEntryName(String)
    case zlibError(String)
    case crcMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let message):
            return "无效备份文件：\(message)"
        case .unsupportedCompressionMethod(let method):
            return "不支持的 ZIP 压缩方式：\(method)"
        case .unsupportedFlags(let flags):
            return "ZIP 使用了当前不支持的标志位：\(flags)"
        case .invalidEntryName(let name):
            return "ZIP 包含非法路径：\(name)"
        case .zlibError(let message):
            return "ZIP 解压失败：\(message)"
        case .crcMismatch(let name):
            return "ZIP 校验失败：\(name)"
        }
    }
}

enum BackupZipArchive {
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let compressionStored: UInt16 = 0
    private static let compressionDeflated: UInt16 = 8

    static func createArchive(entries: [BackupArchiveEntry], to outputURL: URL) throws {
        var archiveData = Data()
        var centralDirectory = Data()
        let timestamp = dosTimestamp(for: .now)

        for entry in entries {
            let fileNameData = Data(entry.path.utf8)
            let crc = checksum(for: entry.data)
            let localHeaderOffset = UInt32(archiveData.count)
            let compressedSize = UInt32(entry.data.count)
            let uncompressedSize = UInt32(entry.data.count)

            archiveData.appendLittleEndian(localFileHeaderSignature)
            archiveData.appendLittleEndian(UInt16(20))
            archiveData.appendLittleEndian(UInt16(0))
            archiveData.appendLittleEndian(compressionStored)
            archiveData.appendLittleEndian(timestamp.time)
            archiveData.appendLittleEndian(timestamp.date)
            archiveData.appendLittleEndian(crc)
            archiveData.appendLittleEndian(compressedSize)
            archiveData.appendLittleEndian(uncompressedSize)
            archiveData.appendLittleEndian(UInt16(fileNameData.count))
            archiveData.appendLittleEndian(UInt16(0))
            archiveData.append(fileNameData)
            archiveData.append(entry.data)

            centralDirectory.appendLittleEndian(centralDirectorySignature)
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(compressionStored)
            centralDirectory.appendLittleEndian(timestamp.time)
            centralDirectory.appendLittleEndian(timestamp.date)
            centralDirectory.appendLittleEndian(crc)
            centralDirectory.appendLittleEndian(compressedSize)
            centralDirectory.appendLittleEndian(uncompressedSize)
            centralDirectory.appendLittleEndian(UInt16(fileNameData.count))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(localHeaderOffset)
            centralDirectory.append(fileNameData)
        }

        let centralDirectoryOffset = UInt32(archiveData.count)
        archiveData.append(centralDirectory)
        archiveData.appendLittleEndian(endOfCentralDirectorySignature)
        archiveData.appendLittleEndian(UInt16(0))
        archiveData.appendLittleEndian(UInt16(0))
        archiveData.appendLittleEndian(UInt16(entries.count))
        archiveData.appendLittleEndian(UInt16(entries.count))
        archiveData.appendLittleEndian(UInt32(centralDirectory.count))
        archiveData.appendLittleEndian(centralDirectoryOffset)
        archiveData.appendLittleEndian(UInt16(0))

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try archiveData.write(to: outputURL, options: .atomic)
    }

    static func extractArchive(at archiveURL: URL, to directoryURL: URL) throws {
        let archiveData = try Data(contentsOf: archiveURL)
        var offset = 0

        while offset + 4 <= archiveData.count {
            let signature: UInt32 = try archiveData.readLittleEndian(at: offset)
            switch signature {
            case localFileHeaderSignature:
                let flags: UInt16 = try archiveData.readLittleEndian(at: offset + 6)
                guard flags & 0x08 == 0 else {
                    throw BackupZipArchiveError.unsupportedFlags(flags)
                }

                let compressionMethod: UInt16 = try archiveData.readLittleEndian(at: offset + 8)
                let expectedCRC: UInt32 = try archiveData.readLittleEndian(at: offset + 14)
                let compressedSize = Int(try archiveData.readLittleEndian(at: offset + 18) as UInt32)
                let uncompressedSize = Int(try archiveData.readLittleEndian(at: offset + 22) as UInt32)
                let fileNameLength = Int(try archiveData.readLittleEndian(at: offset + 26) as UInt16)
                let extraFieldLength = Int(try archiveData.readLittleEndian(at: offset + 28) as UInt16)

                let fileNameStart = offset + 30
                let fileNameEnd = fileNameStart + fileNameLength
                let fileNameData = try archiveData.checkedSubdata(in: fileNameStart..<fileNameEnd)
                guard let fileName = String(data: fileNameData, encoding: .utf8) else {
                    throw BackupZipArchiveError.invalidArchive("文件名编码无效")
                }

                let fileDataStart = fileNameEnd + extraFieldLength
                let fileDataEnd = fileDataStart + compressedSize
                let compressedData = try archiveData.checkedSubdata(in: fileDataStart..<fileDataEnd)
                let entryData: Data

                switch compressionMethod {
                case compressionStored:
                    entryData = compressedData
                case compressionDeflated:
                    entryData = try inflateRaw(data: compressedData, expectedSize: uncompressedSize)
                default:
                    throw BackupZipArchiveError.unsupportedCompressionMethod(compressionMethod)
                }

                guard checksum(for: entryData) == expectedCRC else {
                    throw BackupZipArchiveError.crcMismatch(fileName)
                }

                let destinationURL = try outputURL(for: fileName, inside: directoryURL)
                if fileName.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try entryData.write(to: destinationURL, options: .atomic)
                }

                offset = fileDataEnd

            case centralDirectorySignature, endOfCentralDirectorySignature:
                return

            default:
                throw BackupZipArchiveError.invalidArchive("未知 ZIP 头：0x\(String(signature, radix: 16))")
            }
        }
    }

    private static func outputURL(for entryName: String, inside rootDirectory: URL) throws -> URL {
        let path = entryName.replacingOccurrences(of: "\\", with: "/")
        guard !path.hasPrefix("/") else {
            throw BackupZipArchiveError.invalidEntryName(entryName)
        }

        let components = path.split(separator: "/").map(String.init)
        guard !components.contains("..") else {
            throw BackupZipArchiveError.invalidEntryName(entryName)
        }

        return components.reduce(rootDirectory) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func dosTimestamp(for date: Date) -> (time: UInt16, date: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: .current, from: date)
        let year = min(max(components.year ?? 1980, 1980), 2107)
        let month = min(max(components.month ?? 1, 1), 12)
        let day = min(max(components.day ?? 1, 1), 31)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let second = min(max(components.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private static func checksum(for data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress
            return UInt32(crc32(0, baseAddress, uInt(data.count)))
        }
    }

    private static func inflateRaw(data: Data, expectedSize: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw BackupZipArchiveError.zlibError("inflateInit2 failed: \(initResult)")
        }
        defer { inflateEnd(&stream) }

        let chunkSize = max(expectedSize, 32 * 1024)
        var output = Data()
        var status = Z_OK

        try data.withUnsafeBytes { rawBuffer in
            guard let inputBaseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            repeat {
                let bufferCount = buffer.count
                status = buffer.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(bufferCount)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let producedBytes = bufferCount - Int(stream.avail_out)
                if producedBytes > 0 {
                    output.append(contentsOf: buffer.prefix(producedBytes))
                }

                guard status == Z_OK || status == Z_STREAM_END else {
                    let message = stream.msg.map { String(cString: $0) } ?? "status \(status)"
                    throw BackupZipArchiveError.zlibError(message)
                }
            } while status != Z_STREAM_END
        }

        return output
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    func readLittleEndian<T: FixedWidthInteger>(at offset: Int) throws -> T {
        let length = MemoryLayout<T>.size
        guard offset >= 0, offset + length <= count else {
            throw BackupZipArchiveError.invalidArchive("文件头超出范围")
        }

        return withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }

    func checkedSubdata(in range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw BackupZipArchiveError.invalidArchive("ZIP 内容长度异常")
        }
        return self[range]
    }
}
