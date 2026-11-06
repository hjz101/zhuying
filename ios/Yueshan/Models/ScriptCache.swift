import Foundation

actor ScriptCache {
    static let shared = ScriptCache(directory:FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("ScriptHost-v1"))
    private struct State: Codable { var values: [String:String] = [:]; var order: [String] = [] }
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private func file(_ scope: String) throws -> URL {
        guard scope.count == 64,scope.allSatisfy({"0123456789abcdef".contains($0)}) else { throw ContentFailure.invalidResponse }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath(),url = root.appendingPathComponent(scope + ".json").resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else { throw ContentFailure.storageFailure }; return url
    }
    private func load(_ scope: String) throws -> State {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath:url.path) else { return .init() }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 512 * 1024 else { throw ContentFailure.invalidResponse }
        let state = try JSONDecoder().decode(State.self,from:Data(contentsOf:url))
        guard state.values.count <= 64,state.order.count == state.values.count,Set(state.order) == Set(state.values.keys) else { throw ContentFailure.invalidResponse }; return state
    }
    func get(scope: String,key: String) throws -> String? { guard key.utf8.count <= 256 else { throw ContentFailure.invalidResponse }; return try load(scope).values[key] }
    func put(scope: String,key: String,value: String) throws {
        guard !key.isEmpty,key.utf8.count <= 256,value.utf8.count <= 16 * 1024 else { throw ContentFailure.invalidResponse }
        var state = try load(scope); state.values[key] = value; state.order.removeAll{$0 == key}; state.order.append(key)
        while state.order.count > 64 || state.values.values.reduce(0,{$0 + $1.utf8.count}) > 384 * 1024 { state.values.removeValue(forKey:state.order.removeFirst()) }
        let bytes = try JSONEncoder().encode(state); guard bytes.count <= 512 * 1024 else { throw ContentFailure.invalidResponse }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); try bytes.write(to:file(scope),options:.atomic)
        let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey]).filter{$0.pathExtension == "json"}.sorted{((try? $0.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)}
        for file in files.dropFirst(32) { try FileManager.default.removeItem(at:file) }
    }
    func usage() throws -> Int { try DisposableCacheFiles.bytes(in:directory) }
    func clear() throws { if FileManager.default.fileExists(atPath:directory.path) { try FileManager.default.removeItem(at:directory) } }
}


enum DisposableCacheFiles {
    static func bytes(in directory: URL) throws -> Int {
        do {
            return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]).filter{$0.pathExtension == "json"}.reduce(0) { total,url in
                let values = try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]); return total + (values.isRegularFile == true && values.isSymbolicLink != true ? values.fileSize ?? 0 : 0)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code) { return 0 }
    }
}
@MainActor enum ExtensionCacheMaintenance {
    static func clear(comments: SourceCommentCache = .shared,scripts: ScriptCache = .shared,images: MediaImageCache? = nil) async throws {
        try Task.checkCancellation(); try await comments.clear(); try await scripts.clear(); (images ?? .shared).clear()
    }
}
