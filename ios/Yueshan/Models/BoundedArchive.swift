import Foundation
import libarchive
import Darwin

struct ArchiveMember: Identifiable, Sendable {
    let path: String
    let data: Data
    let directory: Bool
    var id: String { path }
    var format: String { (path as NSString).pathExtension.lowercased() }
}
enum BoundedArchive {
    enum Format: String, Sendable { case zip,rar,sevenZip = "7z" }
    static let maximumExpanded = 64 * 1024 * 1024
    static func identify(_ data: Data) throws -> Format {
        if data.starts(with:[0x50,0x4b,0x03,0x04]) || data.starts(with:[0x50,0x4b,0x05,0x06]) { return .zip }
        if data.starts(with:[0x52,0x61,0x72,0x21,0x1a,0x07,0x00]) || data.starts(with:[0x52,0x61,0x72,0x21,0x1a,0x07,0x01,0x00]) { return .rar }
        if data.starts(with:[0x37,0x7a,0xbc,0xaf,0x27,0x1c]) { return .sevenZip }
        throw BookImportError.message("未识别为 ZIP、RAR 或 7z，请检查文件是否完整。")
    }
    static func read(_ data: Data) throws -> [ArchiveMember] {
        try BookImporter.validateSize(data.count); let format = try identify(data); try rejectSplitRAR(data,format:format)
        // libarchive consults the POSIX thread locale when converting names.
        // iOS starts with "C" even for Chinese UI; keep this synchronous read
        // in a temporary UTF-8 locale without changing the process locale.
        guard let locale = newlocale(LC_CTYPE_MASK,"en_US.UTF-8",nil) else { throw invalid() }
        let previousLocale = uselocale(locale)
        defer { uselocale(previousLocale); freelocale(locale) }
        guard let archive = archive_read_new() else { throw ContentFailure.storageFailure }
        defer { archive_read_free(archive) }
        archive_read_support_filter_none(archive)
        switch format { case .zip: archive_read_support_format_zip(archive)
        case .rar: archive_read_support_format_rar(archive); archive_read_support_format_rar5(archive)
        case .sevenZip: archive_read_support_format_7zip(archive) }
        return try data.withUnsafeBytes { bytes in
            guard archive_read_open_memory(archive,bytes.baseAddress,data.count) == ARCHIVE_OK else { throw invalid() }
            var members: [ArchiveMember] = [],seen = Set<String>(),total = 0
            while true {
                try Task.checkCancellation()
                var entry: OpaquePointer?
                let status = archive_read_next_header(archive,&entry)
                if status == ARCHIVE_EOF { break }
                guard status == ARCHIVE_OK,let entry,let pointer = archive_entry_pathname_utf8(entry),let path = String(validatingUTF8:pointer) else { throw invalid() }
                guard archive_entry_is_encrypted(entry) <= 0,archive_entry_symlink(entry) == nil,archive_entry_hardlink(entry) == nil else { throw BookImportError.message("当前不导入加密、符号链接或硬链接归档。") }
                let isDirectory = archive_entry_filetype(entry) == 0o040000
                let clean = isDirectory ? String(path.drop(while:{$0 == "/"})) : path
                let parts = clean.split(separator:"/",omittingEmptySubsequences:false)
                guard !path.isEmpty,!path.hasPrefix("/"),!path.contains("\\"),!path.contains(":"),path.utf8.count <= 1024,
                      !parts.contains(".."),!parts.contains("."),!parts.dropLast(isDirectory ? 1 : 0).contains(""),
                      !path.unicodeScalars.contains(where:{$0.value < 32}),
                      seen.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted,members.count < 4000 else { throw invalid() }
                guard isDirectory || archive_entry_filetype(entry) == 0o100000 else { throw invalid() }
                let expected = archive_entry_size(entry)
                guard expected >= 0,expected <= BookImporter.maximumBytes,total + Int(expected) <= maximumExpanded else { throw oversized() }
                var payload = Data(),chunk = [UInt8](repeating:0,count:65536)
                while !isDirectory {
                    try Task.checkCancellation()
                    let count = archive_read_data(archive,&chunk,chunk.count)
                    guard count >= 0 else { throw invalid() }; if count == 0 { break }
                    guard payload.count + count <= BookImporter.maximumBytes,total + count <= maximumExpanded else { throw oversized() }
                    payload.append(contentsOf:chunk.prefix(count)); total += count
                }
                guard isDirectory || archive_entry_size_is_set(entry) == 0 || payload.count == expected else { throw invalid() }
                members.append(.init(path:path,data:payload,directory:isDirectory))
            }
            guard !members.isEmpty,archive_read_has_encrypted_entries(archive) <= 0 else { throw invalid() }
            return members.sorted { $0.path.compare($1.path,options:[.numeric,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")) == .orderedAscending }
        }
    }
    private static func rejectSplitRAR(_ data: Data,format: Format) throws {
        guard format == .rar else { return }
        let bytes = [UInt8](data)
        func split() -> BookImportError { .message("当前不支持分卷归档，请提供完整的单卷文件，原包未改动。") }
        if data.starts(with:[0x52,0x61,0x72,0x21,0x1a,0x07,0x00]) {
            guard bytes.count >= 14,bytes[9] == 0x73 else { throw invalid() }
            if bytes[10] & 1 != 0 { throw split() }
        } else {
            var offset = 12
            func number() throws -> UInt64 {
                var value: UInt64 = 0
                for index in 0..<10 {
                    guard offset < bytes.count else { throw invalid() }; let byte = bytes[offset]; offset += 1
                    guard index < 9 || byte <= 1 else { throw invalid() }
                    value |= UInt64(byte & 127) << (index * 7)
                    if byte & 128 == 0 { return value }
                }
                throw invalid()
            }
            let size = try number(),start = offset
            guard size <= 1024 * 1024,size <= UInt64(bytes.count - start),try number() == 1 else { throw invalid() }
            let headerFlags = try number()
            if headerFlags & 1 != 0 { _ = try number() }
            if headerFlags & 2 != 0 { _ = try number() }
            let archiveFlags = try number()
            guard offset <= start + Int(size) else { throw invalid() }
            if archiveFlags & 1 != 0 { throw split() }
        }
    }
    private static func invalid() -> BookImportError { .message("归档损坏、格式变体不受支持或包含不安全路径，原包未改动。") }
    private static func oversized() -> BookImportError { .message("归档超过限制：解包总量 64 MB、单项 20 MB、最多 4000 项。") }
}
