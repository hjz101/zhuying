import Foundation

struct NarrationRole: Codable, Identifiable, Equatable, Sendable { let id: String; var name: String }
struct RoleAnalysis: Codable, Equatable, Sendable {
    let chapterID: String
    let documentVersion: String
    let profileFingerprint: String
    var roles: [NarrationRole]
    let assignments: [String:String]
    let createdAt: Date
    static func fingerprint(_ profile: AudioServiceProfile) -> String { StableContentID.make(profile.id,profile.credentialOrigin,profile.analysisModel) }
    static func decodeBatch(_ data: Data,segments: [NarrationSegment]) throws -> (roles: [NarrationRole],assignments: [String:String]) {
        struct Response: Decodable {
            struct Role: Decodable { let id: String; let name: String }
            struct Assignment: Decodable { let id: String; let role: String }
            let roles: [Role]; let segments: [Assignment]
        }
        let value = try JSONDecoder().decode(Response.self,from:data), ids = Set(segments.map(\.id))
        guard value.roles.count <= 64,Set(value.roles.map(\.id)).count == value.roles.count,
              value.roles.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 100 && !$0.name.isEmpty && $0.name.count <= 80 }),
              Set(value.segments.map(\.id)).count == value.segments.count,value.segments.allSatisfy({ ids.contains($0.id) }) else { throw NarrationError.invalidAnalysis }
        var roles = [NarrationRole(id:"narrator",name:"旁白")], map: [String:String] = ["narrator":"narrator"]
        for role in value.roles {
            let id = role.id == "narrator" || role.name == "旁白" ? "narrator" : StableContentID.make(role.name)
            map[role.id] = id; if !roles.contains(where:{ $0.id == id }) { roles.append(.init(id:id,name:role.name)) }
        }
        var assignments = Dictionary(uniqueKeysWithValues:segments.map { ($0.id,"narrator") })
        for segment in value.segments { assignments[segment.id] = map[segment.role] ?? "narrator" }
        return (roles,assignments)
    }
}

actor RoleAnalysisStore {
    private let url: URL
    private let writer: any AtomicFileWriting
    private var results: [RoleAnalysis]
    private var pending: RoleAnalysis?
    init(directory: URL,writer: any AtomicFileWriting = AtomicFileWriter()) throws {
        self.writer = writer; url = directory.appendingPathComponent("role-analysis.json")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if FileManager.default.fileExists(atPath:url.path) {
            let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            if size <= 8 * 1024 * 1024,let data = try? Data(contentsOf:url),let decoded = try? JSONDecoder().decode([RoleAnalysis].self,from:data),decoded.count <= 30,decoded.allSatisfy({ (try? Self.validate($0)) != nil }) { results = decoded }
            else { try FileManager.default.moveItem(at:url,to:directory.appendingPathComponent("role-analysis.damaged-" + UUID().uuidString)); results = [] }
        } else { results = [] }
    }
    func result(document: ChapterDocument,profile: AudioServiceProfile) -> RoleAnalysis? {
        results.last { $0.chapterID == document.chapterID && $0.documentVersion == document.version && $0.profileFingerprint == RoleAnalysis.fingerprint(profile) }
    }
    func save(_ result: RoleAnalysis) throws {
        try Self.validate(result)
        var next = results.filter { !($0.chapterID == result.chapterID && $0.documentVersion == result.documentVersion && $0.profileFingerprint == result.profileFingerprint) }; next.append(result)
        next = Array(next.suffix(30)); var data = try JSONEncoder().encode(next)
        while data.count > 8 * 1024 * 1024 && next.count > 1 { next.removeFirst(); data = try JSONEncoder().encode(next) }
        guard data.count <= 8 * 1024 * 1024 else { throw ContentFailure.storageFailure }
        try writer.write(data,to:url); results = next
    }
    func analyze(document: ChapterDocument,client: CompatibleAudioClient,maximumRequests: Int,force: Bool = false) async throws -> (RoleAnalysis,Int) {
        if !force,let pending,pending.chapterID == document.chapterID,pending.documentVersion == document.version,pending.profileFingerprint == RoleAnalysis.fingerprint(client.profile) { try save(pending); self.pending = nil; return (pending,0) }
        if !force,let cached = result(document:document,profile:client.profile) { return (cached,0) }
        let segments = try NarrationSegment.make(document:document)
        guard segments.reduce(0,{ $0 + $1.text.utf16.count }) <= 40000 else { throw NarrationError.quota }
        var batches: [[NarrationSegment]] = [], current: [NarrationSegment] = [], count = 0
        for segment in segments {
            if count + segment.text.utf16.count > 6000 && !current.isEmpty { batches.append(current); current = []; count = 0 }
            current.append(segment); count += segment.text.utf16.count
        }
        if !current.isEmpty { batches.append(current) }
        guard batches.count <= max(0,min(20,maximumRequests)) else { throw NarrationError.quota }
        var roles: [String:NarrationRole] = [:], assignments: [String:String] = [:]
        for batch in batches {
            try Task.checkCancellation()
            let decoded = try RoleAnalysis.decodeBatch(await client.roleResponse(segments:batch),segments:batch)
            for role in decoded.roles { roles[role.id] = role }; assignments.merge(decoded.assignments,uniquingKeysWith:{ _,new in new })
            guard roles.count <= 64 else { throw NarrationError.invalidAnalysis }
        }
        try Task.checkCancellation()
        let result = RoleAnalysis(chapterID:document.chapterID,documentVersion:document.version,profileFingerprint:RoleAnalysis.fingerprint(client.profile),roles:roles.values.sorted { $0.id < $1.id },assignments:assignments,createdAt:Date())
        pending = result; try save(result); pending = nil; return (result,batches.count)
    }
    private static func validate(_ result: RoleAnalysis) throws {
        let ids = Set(result.roles.map(\.id))
        guard !result.chapterID.isEmpty,result.documentVersion.count == 64,result.profileFingerprint.count == 64,result.roles.count <= 64,
              ids.count == result.roles.count,ids.contains("narrator"),result.roles.allSatisfy({ !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.count <= 80 }),
              result.assignments.count <= 50000,result.assignments.values.allSatisfy({ ids.contains($0) }) else { throw NarrationError.invalidAnalysis }
    }
}
