import Foundation
#if canImport(Compression)
import Compression
#endif
import CommonCrypto

/// Minimal TTF/WOFF binary parser for font-obfuscation bypass.
///
/// Parses the `cmap`, `loca`, `glyf`, `head` and `maxp` tables to build
/// glyph signatures for Unicode scalar substitution.
public final class TTFParser {

    // MARK: - Types

    private struct TableRecord {
        let offset: Int
        let length: Int
    }

    private struct SimpleGlyph {
        let points: [(x: Int, y: Int)]
    }

    private struct CompositeComponent {
        let glyphIndex: UInt16
        let argument1: Int
        let argument2: Int
        let xScale: Double
        let scale01: Double
        let scale10: Double
        let yScale: Double
    }

    private enum Glyph {
        case simple(SimpleGlyph)
        case composite([CompositeComponent])
    }

    private struct Format4Subtable {
        let segCount: Int
        let endCode: [UInt16]
        let startCode: [UInt16]
        let idDelta: [Int16]
        let idRangeOffsets: [UInt16]
        let glyphIdArrayOffset: Int
        let subtableOffset: Int
        let length: Int
    }

    private struct Format12Group {
        let startCharCode: UInt32
        let endCharCode: UInt32
        let startGlyphID: UInt32
    }

    private final class Reader {
        let data: Data
        private(set) var offset: Int = 0

        init(data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        func seek(_ offset: Int) throws {
            guard offset >= 0, offset <= data.count else {
                throw ParserError.parseError("TTF seek out of bounds")
            }
            self.offset = offset
        }

        func skip(_ length: Int) throws {
            try seek(offset + length)
        }

        func readUInt8() throws -> UInt8 {
            guard offset + 1 <= data.count else {
                throw ParserError.parseError("TTF unexpected EOF")
            }
            let value = data[offset]
            offset += 1
            return value
        }

        func readInt8() throws -> Int8 {
            Int8(bitPattern: try readUInt8())
        }

        func readUInt16() throws -> UInt16 {
            guard offset + 2 <= data.count else {
                throw ParserError.parseError("TTF unexpected EOF")
            }
            let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            offset += 2
            return value
        }

        func readInt16() throws -> Int16 {
            Int16(bitPattern: try readUInt16())
        }

        func readUInt32() throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw ParserError.parseError("TTF unexpected EOF")
            }
            let value = (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
            offset += 4
            return value
        }

        func readInt32() throws -> Int32 {
            Int32(bitPattern: try readUInt32())
        }

        func readData(length: Int) throws -> Data {
            guard length >= 0, offset + length <= data.count else {
                throw ParserError.parseError("TTF unexpected EOF")
            }
            let chunk = data.subdata(in: offset..<(offset + length))
            offset += length
            return chunk
        }
    }

    // MARK: - Public state

    public private(set) var glyphSignatures: [Unicode.Scalar: String] = [:]
    public private(set) var charToGlyph: [Unicode.Scalar: UInt16] = [:]

    // MARK: - Cache

    internal static var fontCache: [String: TTFParser] = [:]
    private static var fontCacheKeys: [String] = []
    private static let fontCacheLock = NSLock()
    private static let maxCacheEntries = 20

    public static func cached(data: Data) throws -> TTFParser {
        let key = sha256Hex(data)

        fontCacheLock.lock()
        if let cached = fontCache[key] {
            touchCacheKey(key)
            fontCacheLock.unlock()
            return cached
        }
        fontCacheLock.unlock()

        let parser = try TTFParser(data: data)

        fontCacheLock.lock()
        fontCache[key] = parser
        touchCacheKey(key)
        if fontCacheKeys.count > maxCacheEntries, let evicted = fontCacheKeys.first {
            fontCache.removeValue(forKey: evicted)
            fontCacheKeys.removeFirst()
        }
        fontCacheLock.unlock()
        return parser
    }

    public static func cacheKey(for data: Data) -> String {
        sha256Hex(data)
    }

    public static func replaceFont(
        text: String,
        errorFont: TTFParser,
        correctFont: TTFParser
    ) -> String {
        var signatureToCorrect: [String: Unicode.Scalar] = [:]
        for (scalar, signature) in correctFont.glyphSignatures where !signature.isEmpty {
            signatureToCorrect[signature] = scalar
        }

        let replaced = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            guard !isBlankUnicode(scalar),
                  let signature = errorFont.glyphSignatures[scalar],
                  !signature.isEmpty,
                  let correct = signatureToCorrect[signature] else {
                return scalar
            }
            #if DEBUG
            ParserLog.debug("TTFParser", "replace U+\(String(scalar.value, radix: 16)) -> U+\(String(correct.value, radix: 16))")
            #endif
            return correct
        }
        return String(String.UnicodeScalarView(replaced))
    }

    // MARK: - Private state

    private let fontData: Data
    private var tables: [String: TableRecord] = [:]
    private var glyphs: [UInt16: Glyph] = [:]
    private var loca: [Int] = []
    private var numGlyphs: Int = 0
    private var glyfTable: TableRecord?
    private var indexToLocFormat: Int16 = 0

    // MARK: - Init

    public init(data: Data) throws {
        let normalizedData = try Self.normalizeFontData(data)
        self.fontData = normalizedData
        try parse()
        ParserLog.debug("TTFParser", "loaded glyphs=\(glyphSignatures.count) chars=\(charToGlyph.count)")
    }

    // MARK: - Parse

    private func parse() throws {
        let reader = Reader(data: fontData)
        let sfVersion = try reader.readUInt32()
        guard sfVersion == 0x00010000 || sfVersion == 0x4F54544F else {
            throw ParserError.parseError("Unsupported font sfVersion: \(String(sfVersion, radix: 16))")
        }

        let numTables = Int(try reader.readUInt16())
        try reader.skip(6)

        for _ in 0..<numTables {
            let tagData = try reader.readData(length: 4)
            guard let tag = String(data: tagData, encoding: .ascii) else {
                throw ParserError.parseError("Invalid table tag")
            }
            _ = try reader.readUInt32()
            let offset = Int(try reader.readUInt32())
            let length = Int(try reader.readUInt32())
            guard offset >= 0, length >= 0, offset + length <= fontData.count else {
                throw ParserError.parseError("Invalid table range for \(tag)")
            }
            tables[tag] = TableRecord(offset: offset, length: length)
        }

        try parseHead()
        try parseMaxp()
        try parseLoca()
        try parseCmap()
        try buildGlyphSignatures()
    }

    private func parseHead() throws {
        guard let headTable = tables["head"] else {
            throw ParserError.parseError("Missing head table")
        }
        let reader = Reader(data: fontData, offset: headTable.offset)
        try reader.skip(50)
        indexToLocFormat = try reader.readInt16()
    }

    private func parseMaxp() throws {
        guard let maxpTable = tables["maxp"] else {
            throw ParserError.parseError("Missing maxp table")
        }
        let reader = Reader(data: fontData, offset: maxpTable.offset)
        _ = try reader.readUInt32()
        numGlyphs = Int(try reader.readUInt16())
        guard numGlyphs > 0 else {
            throw ParserError.parseError("Invalid maxp numGlyphs")
        }
    }

    private func parseLoca() throws {
        guard let locaTable = tables["loca"], let glyfTable = tables["glyf"] else {
            throw ParserError.parseError("Missing loca/glyf table")
        }
        self.glyfTable = glyfTable

        let reader = Reader(data: fontData, offset: locaTable.offset)
        loca = []
        loca.reserveCapacity(numGlyphs + 1)

        if indexToLocFormat == 0 {
            for _ in 0..<(locaTable.length / 2) {
                loca.append(Int(try reader.readUInt16()) * 2)
            }
        } else {
            for _ in 0..<(locaTable.length / 4) {
                loca.append(Int(try reader.readUInt32()))
            }
        }

        guard loca.count >= numGlyphs + 1 else {
            throw ParserError.parseError("Invalid loca count")
        }
    }

    private func parseCmap() throws {
        guard let cmapTable = tables["cmap"] else {
            throw ParserError.parseError("Missing cmap table")
        }
        let reader = Reader(data: fontData, offset: cmapTable.offset)
        _ = try reader.readUInt16()
        let numTables = Int(try reader.readUInt16())

        var format4Offset: Int?
        var format12Offset: Int?

        for _ in 0..<numTables {
            let platformID = try reader.readUInt16()
            let encodingID = try reader.readUInt16()
            let offset = Int(try reader.readUInt32())
            let subtableOffset = cmapTable.offset + offset
            guard subtableOffset + 2 <= fontData.count else { continue }
            let format = try Reader(data: fontData, offset: subtableOffset).readUInt16()

            if format == 12, (platformID == 3 && encodingID == 10) || platformID == 0 {
                format12Offset = subtableOffset
            } else if format == 4, format4Offset == nil, (platformID == 3 && encodingID == 1) || platformID == 0 {
                format4Offset = subtableOffset
            }
        }

        if let format12Offset {
            try parseCmapFormat12(at: format12Offset)
        }
        if let format4Offset {
            try parseCmapFormat4(at: format4Offset)
        }

        guard !charToGlyph.isEmpty else {
            throw ParserError.parseError("Unsupported or empty cmap")
        }
    }

    private func parseCmapFormat4(at offset: Int) throws {
        let reader = Reader(data: fontData, offset: offset)
        let format = try reader.readUInt16()
        guard format == 4 else {
            throw ParserError.parseError("Invalid cmap format 4")
        }
        let length = Int(try reader.readUInt16())
        _ = try reader.readUInt16()
        let segCount = Int(try reader.readUInt16()) / 2
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()
        _ = try reader.readUInt16()

        var endCode: [UInt16] = []
        var startCode: [UInt16] = []
        var idDelta: [Int16] = []
        var idRangeOffsets: [UInt16] = []
        endCode.reserveCapacity(segCount)
        startCode.reserveCapacity(segCount)
        idDelta.reserveCapacity(segCount)
        idRangeOffsets.reserveCapacity(segCount)

        for _ in 0..<segCount { endCode.append(try reader.readUInt16()) }
        _ = try reader.readUInt16()
        for _ in 0..<segCount { startCode.append(try reader.readUInt16()) }
        for _ in 0..<segCount { idDelta.append(try reader.readInt16()) }
        for _ in 0..<segCount { idRangeOffsets.append(try reader.readUInt16()) }

        let glyphIdArrayOffset = reader.offset
        let table = Format4Subtable(
            segCount: segCount,
            endCode: endCode,
            startCode: startCode,
            idDelta: idDelta,
            idRangeOffsets: idRangeOffsets,
            glyphIdArrayOffset: glyphIdArrayOffset,
            subtableOffset: offset,
            length: length
        )

        for segmentIndex in 0..<segCount {
            let start = Int(table.startCode[segmentIndex])
            let end = Int(table.endCode[segmentIndex])
            guard start <= end, start != 0xFFFF else { continue }
            for codePoint in start...end {
                guard let scalar = Unicode.Scalar(codePoint) else { continue }
                let glyph = try glyphID(for: codePoint, table: table, segmentIndex: segmentIndex)
                if glyph != 0 {
                    charToGlyph[scalar] = glyph
                }
            }
        }
    }

    private func glyphID(for codePoint: Int, table: Format4Subtable, segmentIndex: Int) throws -> UInt16 {
        let idRangeOffset = Int(table.idRangeOffsets[segmentIndex])
        let delta = Int(table.idDelta[segmentIndex])

        if idRangeOffset == 0 {
            return UInt16((codePoint + delta) & 0xFFFF)
        }

        let idRangeOffsetAddress = table.subtableOffset + 14 + table.segCount * 2 + 2 + table.segCount * 2 + table.segCount * 2 + segmentIndex * 2
        let glyphIndexAddress = idRangeOffsetAddress + idRangeOffset + (codePoint - Int(table.startCode[segmentIndex])) * 2
        guard glyphIndexAddress + 2 <= table.subtableOffset + table.length,
              glyphIndexAddress + 2 <= fontData.count else {
            return 0
        }

        let reader = Reader(data: fontData, offset: glyphIndexAddress)
        let glyphIndex = Int(try reader.readUInt16())
        guard glyphIndex != 0 else { return 0 }
        return UInt16((glyphIndex + delta) & 0xFFFF)
    }

    private func parseCmapFormat12(at offset: Int) throws {
        let reader = Reader(data: fontData, offset: offset)
        let format = try reader.readUInt16()
        guard format == 12 else {
            throw ParserError.parseError("Invalid cmap format 12")
        }
        _ = try reader.readUInt16()
        _ = try reader.readUInt32()
        _ = try reader.readUInt32()
        let groupCount = Int(try reader.readUInt32())

        for _ in 0..<groupCount {
            let startCharCode = try reader.readUInt32()
            let endCharCode = try reader.readUInt32()
            let startGlyphID = try reader.readUInt32()
            guard startCharCode <= endCharCode else { continue }
            for codePoint in startCharCode...endCharCode {
                guard let scalar = Unicode.Scalar(codePoint) else { continue }
                let glyph = startGlyphID + (codePoint - startCharCode)
                guard glyph <= UInt32(UInt16.max) else { continue }
                charToGlyph[scalar] = UInt16(glyph)
            }
        }
    }

    private func buildGlyphSignatures() throws {
        var glyphToSignature: [UInt16: String] = [:]
        for (scalar, glyphID) in charToGlyph {
            if let signature = glyphToSignature[glyphID] {
                glyphSignatures[scalar] = signature
                continue
            }

            let signature = try signature(forGlyphID: glyphID, visited: Set())
            glyphToSignature[glyphID] = signature
            glyphSignatures[scalar] = signature
        }
    }

    private func signature(forGlyphID glyphID: UInt16, visited: Set<UInt16>) throws -> String {
        guard !visited.contains(glyphID) else { return "" }
        let glyph = try loadGlyph(id: glyphID)
        switch glyph {
        case .simple(let simple):
            return glyphSignature(points: simple.points)
        case .composite(let components):
            var points: [(x: Int, y: Int)] = []
            let nextVisited = visited.union([glyphID])
            for component in components {
                let childGlyph = try loadGlyph(id: component.glyphIndex)
                let childPoints = try resolvedPoints(for: childGlyph, visited: nextVisited)
                let transformed = childPoints.map { point in
                    let x = Int((Double(point.x) * component.xScale) + (Double(point.y) * component.scale01)) + component.argument1
                    let y = Int((Double(point.x) * component.scale10) + (Double(point.y) * component.yScale)) + component.argument2
                    return (x: x, y: y)
                }
                points.append(contentsOf: transformed)
            }
            return glyphSignature(points: points)
        }
    }

    private func resolvedPoints(for glyph: Glyph, visited: Set<UInt16>) throws -> [(x: Int, y: Int)] {
        switch glyph {
        case .simple(let simple):
            return simple.points
        case .composite(let components):
            var points: [(x: Int, y: Int)] = []
            for component in components {
                let childGlyph = try loadGlyph(id: component.glyphIndex)
                let childPoints = try resolvedPoints(for: childGlyph, visited: visited.union([component.glyphIndex]))
                let transformed = childPoints.map { point in
                    let x = Int((Double(point.x) * component.xScale) + (Double(point.y) * component.scale01)) + component.argument1
                    let y = Int((Double(point.x) * component.scale10) + (Double(point.y) * component.yScale)) + component.argument2
                    return (x: x, y: y)
                }
                points.append(contentsOf: transformed)
            }
            return points
        }
    }

    private func loadGlyph(id glyphID: UInt16) throws -> Glyph {
        if let cached = glyphs[glyphID] {
            return cached
        }
        guard let glyfTable, Int(glyphID) + 1 < loca.count else {
            throw ParserError.parseError("Invalid glyph index \(glyphID)")
        }

        let start = loca[Int(glyphID)]
        let end = loca[Int(glyphID) + 1]
        guard end >= start else {
            throw ParserError.parseError("Invalid glyph loca range")
        }
        if start == end {
            let glyph = Glyph.simple(SimpleGlyph(points: []))
            glyphs[glyphID] = glyph
            return glyph
        }

        let glyphOffset = glyfTable.offset + start
        guard glyphOffset + 10 <= fontData.count else {
            throw ParserError.parseError("Glyph offset out of range")
        }

        let reader = Reader(data: fontData, offset: glyphOffset)
        let numberOfContours = try reader.readInt16()
        _ = try reader.readInt16()
        _ = try reader.readInt16()
        _ = try reader.readInt16()
        _ = try reader.readInt16()

        let glyph: Glyph
        if numberOfContours >= 0 {
            glyph = .simple(try parseSimpleGlyph(reader: reader, contourCount: Int(numberOfContours)))
        } else {
            glyph = .composite(try parseCompositeGlyph(reader: reader))
        }

        glyphs[glyphID] = glyph
        return glyph
    }

    private func parseSimpleGlyph(reader: Reader, contourCount: Int) throws -> SimpleGlyph {
        if contourCount == 0 {
            return SimpleGlyph(points: [])
        }

        var endPtsOfContours: [UInt16] = []
        endPtsOfContours.reserveCapacity(contourCount)
        for _ in 0..<contourCount {
            endPtsOfContours.append(try reader.readUInt16())
        }

        let instructionLength = Int(try reader.readUInt16())
        try reader.skip(instructionLength)

        let pointCount = Int(endPtsOfContours.last ?? 0) + 1
        var flags: [UInt8] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount {
            let flag = try reader.readUInt8()
            flags.append(flag)
            if flag & 0x08 != 0 {
                let repeatCount = Int(try reader.readUInt8())
                for _ in 0..<repeatCount {
                    flags.append(flag)
                }
            }
        }

        var xCoordinates: [Int] = Array(repeating: 0, count: pointCount)
        var currentX = 0
        for index in 0..<pointCount {
            let flag = flags[index]
            let delta: Int
            switch flag & 0x12 {
            case 0x02:
                delta = -Int(try reader.readUInt8())
            case 0x12:
                delta = Int(try reader.readUInt8())
            case 0x10:
                delta = 0
            default:
                delta = Int(try reader.readInt16())
            }
            currentX += delta
            xCoordinates[index] = currentX
        }

        var yCoordinates: [Int] = Array(repeating: 0, count: pointCount)
        var currentY = 0
        for index in 0..<pointCount {
            let flag = flags[index]
            let delta: Int
            switch flag & 0x24 {
            case 0x04:
                delta = -Int(try reader.readUInt8())
            case 0x24:
                delta = Int(try reader.readUInt8())
            case 0x20:
                delta = 0
            default:
                delta = Int(try reader.readInt16())
            }
            currentY += delta
            yCoordinates[index] = currentY
        }

        let points = zip(xCoordinates, yCoordinates).map { (x: $0.0, y: $0.1) }
        return SimpleGlyph(points: points)
    }

    private func parseCompositeGlyph(reader: Reader) throws -> [CompositeComponent] {
        var components: [CompositeComponent] = []
        while true {
            let flags = Int(try reader.readUInt16())
            let glyphIndex = try reader.readUInt16()

            let argument1: Int
            let argument2: Int
            switch flags & 0b11 {
            case 0b00:
                argument1 = Int(try reader.readUInt8())
                argument2 = Int(try reader.readUInt8())
            case 0b10:
                argument1 = Int(try reader.readInt8())
                argument2 = Int(try reader.readInt8())
            case 0b01:
                argument1 = Int(try reader.readUInt16())
                argument2 = Int(try reader.readUInt16())
            default:
                argument1 = Int(try reader.readInt16())
                argument2 = Int(try reader.readInt16())
            }

            var xScale = 1.0
            var scale01 = 0.0
            var scale10 = 0.0
            var yScale = 1.0

            switch flags & 0b11001000 {
            case 0b00001000:
                let scale = try readF2Dot14(reader)
                xScale = scale
                yScale = scale
            case 0b01000000:
                xScale = try readF2Dot14(reader)
                yScale = try readF2Dot14(reader)
            case 0b10000000:
                xScale = try readF2Dot14(reader)
                scale01 = try readF2Dot14(reader)
                scale10 = try readF2Dot14(reader)
                yScale = try readF2Dot14(reader)
            default:
                break
            }

            components.append(
                CompositeComponent(
                    glyphIndex: glyphIndex,
                    argument1: argument1,
                    argument2: argument2,
                    xScale: xScale,
                    scale01: scale01,
                    scale10: scale10,
                    yScale: yScale
                )
            )

            if flags & 0x20 == 0 {
                break
            }
        }
        return components
    }

    private func readF2Dot14(_ reader: Reader) throws -> Double {
        Double(try reader.readInt16()) / 16384.0
    }

    private func glyphSignature(points: [(x: Int, y: Int)]) -> String {
        guard !points.isEmpty else { return "" }
        let minX = points.map(\ .x).min() ?? 0
        let minY = points.map(\ .y).min() ?? 0
        let normalized = points.map { (x: $0.x - minX, y: $0.y - minY) }
        let sorted = normalized.sorted { lhs, rhs in
            if lhs.x != rhs.x { return lhs.x < rhs.x }
            return lhs.y < rhs.y
        }
        return sorted.map { "\($0.x),\($0.y)" }.joined(separator: "|")
    }

    // MARK: - Font normalization

    private static func normalizeFontData(_ data: Data) throws -> Data {
        let magic = try Reader(data: data).readUInt32()
        if magic == 0x774F4646 {
            return try decompressWOFF(data)
        }
        return data
    }

    private static func decompressWOFF(_ data: Data) throws -> Data {
        #if canImport(Compression)
        let reader = Reader(data: data)
        let signature = try reader.readUInt32()
        guard signature == 0x774F4646 else {
            throw ParserError.parseError("Invalid WOFF signature")
        }

        let flavor = try reader.readUInt32()
        let totalSfntSize = Int(try reader.readUInt32())
        let numTables = Int(try reader.readUInt16())
        try reader.skip(2)
        _ = try reader.readUInt32()
        try reader.skip(16)

        struct WOFFEntry {
            let tag: String
            let offset: Int
            let compLength: Int
            let origLength: Int
            let checksum: UInt32
        }

        var entries: [WOFFEntry] = []
        for _ in 0..<numTables {
            let tagData = try reader.readData(length: 4)
            guard let tag = String(data: tagData, encoding: .ascii) else {
                throw ParserError.parseError("Invalid WOFF table tag")
            }
            let offset = Int(try reader.readUInt32())
            let compLength = Int(try reader.readUInt32())
            let origLength = Int(try reader.readUInt32())
            let checksum = try reader.readUInt32()
            entries.append(WOFFEntry(tag: tag, offset: offset, compLength: compLength, origLength: origLength, checksum: checksum))
        }

        var output = Data()
        func appendUInt16(_ value: UInt16) { output.append(UInt8((value >> 8) & 0xFF)); output.append(UInt8(value & 0xFF)) }
        func appendUInt32(_ value: UInt32) {
            output.append(UInt8((value >> 24) & 0xFF))
            output.append(UInt8((value >> 16) & 0xFF))
            output.append(UInt8((value >> 8) & 0xFF))
            output.append(UInt8(value & 0xFF))
        }

        let searchRange = UInt16((1 << Int(floor(log2(Double(max(numTables, 1)))))) * 16)
        let entrySelector = UInt16(max(0, Int(floor(log2(Double(max(numTables, 1)))))))
        let rangeShift = UInt16(numTables * 16) - searchRange

        appendUInt32(flavor)
        appendUInt16(UInt16(numTables))
        appendUInt16(searchRange)
        appendUInt16(entrySelector)
        appendUInt16(rangeShift)

        let directorySize = 12 + numTables * 16
        var tableOffset = directorySize
        var tableBuffers: [(entry: WOFFEntry, data: Data, offset: Int)] = []
        tableBuffers.reserveCapacity(entries.count)

        for entry in entries {
            guard entry.offset + entry.compLength <= data.count else {
                throw ParserError.parseError("WOFF table range out of bounds")
            }
            let rawTable = data.subdata(in: entry.offset..<(entry.offset + entry.compLength))
            let tableData: Data
            if entry.compLength < entry.origLength {
                tableData = try zlibDecompress(rawTable, expectedSize: entry.origLength)
            } else {
                tableData = rawTable
            }
            guard tableData.count == entry.origLength else {
                throw ParserError.parseError("WOFF table length mismatch for \(entry.tag)")
            }
            tableBuffers.append((entry, tableData, tableOffset))
            tableOffset += alignedLength(entry.origLength)
        }

        for item in tableBuffers {
            let tagBytes = Array(item.entry.tag.utf8)
            guard tagBytes.count == 4 else {
                throw ParserError.parseError("Invalid WOFF tag length")
            }
            output.append(contentsOf: tagBytes)
            appendUInt32(item.entry.checksum)
            appendUInt32(UInt32(item.offset))
            appendUInt32(UInt32(item.entry.origLength))
        }

        for item in tableBuffers {
            if output.count < item.offset {
                output.append(Data(repeating: 0, count: item.offset - output.count))
            }
            output.append(item.data)
            let padding = alignedLength(item.data.count) - item.data.count
            if padding > 0 {
                output.append(Data(repeating: 0, count: padding))
            }
        }

        if output.count < totalSfntSize {
            output.append(Data(repeating: 0, count: totalSfntSize - output.count))
        }
        return output
        #else
        throw ParserError.parseError("WOFF parsing requires Compression framework")
        #endif
    }

    #if canImport(Compression)
    private static func zlibDecompress(_ data: Data, expectedSize: Int) throws -> Data {
        let destinationCapacity = max(expectedSize, data.count * 8, 1024)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { sourceBuffer in
            guard let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer,
                destinationCapacity,
                sourceBase,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else {
            throw ParserError.parseError("WOFF zlib decompress failed")
        }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }
    #endif

    // MARK: - Helpers

    private static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private static func touchCacheKey(_ key: String) {
        fontCacheKeys.removeAll { $0 == key }
        fontCacheKeys.append(key)
    }

    private static func alignedLength(_ length: Int) -> Int {
        let remainder = length % 4
        return remainder == 0 ? length : (length + 4 - remainder)
    }

    private static func isBlankUnicode(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0009, 0x0020, 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }
}
