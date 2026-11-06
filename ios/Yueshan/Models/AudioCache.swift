import Foundation

enum WAVAudio {
    static func validate(_ data: Data) throws {
        guard data.count >= 44,data.count <= 12 * 1024 * 1024,String(data:data.prefix(4),encoding:.ascii) == "RIFF",String(data:data[8..<12],encoding:.ascii) == "WAVE" else { throw NarrationError.invalidAudio }
        func number(_ offset: Int,_ bytes: Int) -> Int { (0..<bytes).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) } }
        guard number(4,4) + 8 <= data.count else { throw NarrationError.invalidAudio }
        var cursor = 12, validFormat = false, samples = 0, block = 0, chunks = 0
        while cursor + 8 <= data.count {
            chunks += 1; guard chunks <= 1024 else { throw NarrationError.invalidAudio }
            let size = number(cursor + 4,4), start = cursor + 8
            guard size <= data.count - start else { throw NarrationError.invalidAudio }
            let name = String(data:data[cursor..<(cursor + 4)],encoding:.ascii)
            if name == "fmt ",size >= 16 {
                let format = number(start,2), channels = number(start + 2,2), rate = number(start + 4,4), bits = number(start + 14,2)
                validFormat = [1,3].contains(format) && (1...2).contains(channels) && (8000...192000).contains(rate) && [16,24,32].contains(bits)
                block = number(start + 12,2); validFormat = validFormat && block == channels * bits / 8
            }
            if name == "data" { samples += size }
            cursor = start + size + size % 2
        }
        guard validFormat,samples > 0,block > 0,samples % block == 0 else { throw NarrationError.invalidAudio }
    }
}

actor AudioCache {
    private struct Entry: Codable { let filename: String; let bytes: Int; var accessed: Date }
    private let root: URL
    private let writer: any AtomicFileWriting
    private let limit: Int
    private var entries: [String:Entry]
    init(directory: URL,limit: Int = 64 * 1024 * 1024,writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        root = directory; self.limit = limit; self.writer = writer
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let index = directory.appendingPathComponent("audio-cache.json")
        if FileManager.default.fileExists(atPath:index.path) {
            if let data = try? Data(contentsOf:index),data.count <= 1024 * 1024,let saved = try? JSONDecoder().decode([String:Entry].self,from:data),saved.count <= 128,
               saved.allSatisfy({ Self.validKey($0.key) && Self.validFile($0.value.filename) && $0.value.bytes > 0 }) { entries = saved }
            else { try FileManager.default.moveItem(at:index,to:directory.appendingPathComponent("audio-cache.damaged-" + UUID().uuidString)); entries = [:] }
        } else { entries = [:] }
        try Self.collect(root:root,keep:Set(entries.values.map(\.filename)))
    }
    func data(key: String) throws -> Data? {
        guard var entry = entries[key] else { return nil }
        let url = try file(entry.filename)
        guard let bytes = try? Data(contentsOf:url),bytes.count == entry.bytes,FileResourceStore.digest(bytes) + ".wav" == entry.filename,(try? WAVAudio.validate(bytes)) != nil else {
            var next = entries; next.removeValue(forKey:key); try commit(next); try collect(); return nil
        }
        entry.accessed = Date(); entries[key] = entry; return bytes
    }
    func save(_ data: Data,key: String) throws {
        try Task.checkCancellation(); try WAVAudio.validate(data)
        guard Self.validKey(key),data.count <= limit else { throw ContentFailure.storageFailure }
        let name = FileResourceStore.digest(data) + ".wav", url = try file(name), existed = FileManager.default.fileExists(atPath:url.path)
        var next = entries; next[key] = .init(filename:name,bytes:data.count,accessed:Date())
        while next.count > 128 || next.values.reduce(0, { $0 + $1.bytes }) > limit {
            guard let victim = next.filter({ $0.key != key }).min(by:{ $0.value.accessed < $1.value.accessed })?.key else { throw ContentFailure.storageFailure }; next.removeValue(forKey:victim)
        }
        do { try writer.write(data,to:url); try commit(next) }
        catch { if !existed { try? FileManager.default.removeItem(at:url) }; throw error }
        try? collect()
    }
    func clear() throws { try commit([:]); try collect() }
    func bytes() throws -> Int {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey]).filter { Self.validFile($0.lastPathComponent) }.reduce(0) { total,url in total + ((try url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
    }
    private func commit(_ value: [String:Entry]) throws { try writer.write(JSONEncoder().encode(value),to:root.appendingPathComponent("audio-cache.json")); entries = value }
    private func collect() throws {
        try Self.collect(root:root,keep:Set(entries.values.map(\.filename)))
    }
    private static func collect(root: URL,keep: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where validFile(url.lastPathComponent) && !keep.contains(url.lastPathComponent) { try FileManager.default.removeItem(at:url) }
    }
    private static func validKey(_ key: String) -> Bool { key.count == 64 && key.allSatisfy { "0123456789abcdef".contains($0) } }
    private static func validFile(_ name: String) -> Bool { name.hasSuffix(".wav") && validKey(String(name.dropLast(4))) }
    private func file(_ name: String) throws -> URL {
        let folder = root.standardizedFileURL.resolvingSymlinksInPath(),url = folder.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard Self.validFile(name),url.deletingLastPathComponent() == folder else { throw ContentFailure.storageFailure }; return url
    }
}
