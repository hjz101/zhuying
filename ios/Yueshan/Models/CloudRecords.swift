import Foundation

enum CloudAccessError: LocalizedError {
    case notConfigured, notSignedIn, accountChanged, unavailable, invalidData, quota
    var errorDescription: String? { switch self {
    case .notConfigured: "此构建尚未启用 iCloud 权限。配置开发团队和容器后可连接；本地书库与备份可继续使用。"
    case .notSignedIn: "当前设备未登录可用的 iCloud 账号。"
    case .accountChanged: "iCloud 账号已变化，当前操作已停止；请重新检查账号。"
    case .unavailable: "云端文件尚未就绪或当前不可用，请联网后重试。"
    case .invalidData: "云端记录校验失败，当前书库保持不变。"
    case .quota: "云端记录或文件超过当前支持的额度，请先导出备份。"
    } }
}

struct CloudFile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bytes: Int
    let modified: Date
    var downloaded: Bool
}
protocol CloudDocumentTransport: Sendable {
    func account() async throws -> String
    func files(folder: String,account: String) async throws -> [CloudFile]
    func read(folder: String,id: String,maximumBytes: Int,account: String) async throws -> Data
    func write(_ data: Data,folder: String,id: String,account: String) async throws
    func remove(folder: String,id: String,account: String) async throws
}

/// No CKContainer is constructed in an unsigned build. iCloud Drive supplies
/// account isolation; every coordinated operation verifies the identity again.
struct UbiquitousDocuments: CloudDocumentTransport {
    let containerIdentifier: String
    let enabled: Bool
    init(containerIdentifier: String = Bundle.main.object(forInfoDictionaryKey:"YueshanCloudContainer") as? String ?? "iCloud.com.yueshan.reader",enabled: Bool = Bundle.main.object(forInfoDictionaryKey:"YueshanCloudEnabled") as? Bool ?? false) { self.containerIdentifier = containerIdentifier; self.enabled = enabled }
    func account() async throws -> String {
        try accountSnapshot()
    }
    private func accountSnapshot() throws -> String {
        guard enabled else { throw CloudAccessError.notConfigured }
        guard let token = FileManager.default.ubiquityIdentityToken else { throw CloudAccessError.notSignedIn }
        let data = try NSKeyedArchiver.archivedData(withRootObject:token,requiringSecureCoding:true)
        return FileResourceStore.digest(data)
    }
    private func directory(_ folder: String,account expected: String) async throws -> URL {
        guard ["Backups","Records-v1"].contains(folder),try await account() == expected else { throw CloudAccessError.accountChanged }
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier:containerIdentifier) else { throw CloudAccessError.unavailable }
        let url = root.appendingPathComponent("Documents/Yueshan/" + folder,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func file(_ id: String,in root: URL) throws -> URL {
        guard UUID(uuidString:id) != nil else { throw CloudAccessError.invalidData }
        return root.appendingPathComponent(id + ".json")
    }
    func files(folder: String,account expected: String) async throws -> [CloudFile] {
        let root = try await directory(folder,account:expected)
        let list = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey,.ubiquitousItemDownloadingStatusKey,.isSymbolicLinkKey])
        guard list.count <= 4096 else { throw CloudAccessError.quota }
        let files = try list.compactMap { url -> CloudFile? in
            let placeholder = url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix(".json.icloud")
            let name = placeholder ? String(url.lastPathComponent.dropFirst().dropLast(7)) : url.lastPathComponent
            let id = (name as NSString).deletingPathExtension
            guard (name as NSString).pathExtension == "json",UUID(uuidString:id) != nil else { return nil }
            let value = try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.ubiquitousItemDownloadingStatusKey,.isSymbolicLinkKey])
            guard value.isSymbolicLink != true else { throw CloudAccessError.invalidData }
            return .init(id:id,bytes:placeholder ? 0 : value.fileSize ?? 0,modified:value.contentModificationDate ?? .distantPast,downloaded:!placeholder && value.ubiquitousItemDownloadingStatus != .notDownloaded)
        }
        guard try await account() == expected else { throw CloudAccessError.accountChanged }; return files.sorted { $0.modified > $1.modified }
    }
    func read(folder: String,id: String,maximumBytes: Int,account expected: String) async throws -> Data {
        let root = try await directory(folder,account:expected),url = try file(id,in:root)
        try FileManager.default.startDownloadingUbiquitousItem(at:url)
        guard try url.resourceValues(forKeys:[.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus != .notDownloaded else { throw CloudAccessError.unavailable }
        let coordination = CloudFileCoordination()
        let worker = Task.detached {
            try Task.checkCancellation()
            var error: NSError?,result: Result<Data,Error>?
            coordination.value.coordinate(readingItemAt:url,options:[],error:&error) { coordinated in
                result = Result {
                    try Task.checkCancellation(); guard try accountSnapshot() == expected else { throw CloudAccessError.accountChanged }
                    let values = try coordinated.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey,.ubiquitousItemDownloadingStatusKey])
                    guard values.isSymbolicLink != true,values.ubiquitousItemDownloadingStatus != .notDownloaded,let size = values.fileSize,size > 0,size <= maximumBytes else { throw CloudAccessError.unavailable }
                    return try Data(contentsOf:coordinated)
                }
            }
            if let error { throw error }; guard let result else { throw CloudAccessError.unavailable }; return try result.get()
        }
        let bytes = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{coordination.value.cancel(); worker.cancel()})
        try Task.checkCancellation(); guard try await account() == expected else { throw CloudAccessError.accountChanged }; return bytes
    }
    func write(_ data: Data,folder: String,id: String,account expected: String) async throws {
        guard data.count <= LibraryBackup.maximumBytes else { throw CloudAccessError.quota }
        let root = try await directory(folder,account:expected),url = try file(id,in:root)
        let coordination = CloudFileCoordination()
        let worker = Task.detached {
            try Task.checkCancellation()
            var error: NSError?,failure: Error?
            coordination.value.coordinate(writingItemAt:url,options:.forReplacing,error:&error) { coordinated in do { try Task.checkCancellation(); guard try accountSnapshot() == expected else { throw CloudAccessError.accountChanged }; try data.write(to:coordinated,options:.atomic) } catch { failure = error } }
            if let error { throw error }; if let failure { throw failure }
        }
        try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{coordination.value.cancel(); worker.cancel()})
        try Task.checkCancellation()
        guard try await account() == expected else { throw CloudAccessError.accountChanged }
    }
    func remove(folder: String,id: String,account expected: String) async throws {
        let root = try await directory(folder,account:expected),url = try file(id,in:root)
        var error: NSError?,failure: Error?
        NSFileCoordinator().coordinate(writingItemAt:url,options:.forDeleting,error:&error) { coordinated in do { try FileManager.default.removeItem(at:coordinated) } catch { failure = error } }
        if let error { throw error }; if let failure { throw failure }
        guard try await account() == expected else { throw CloudAccessError.accountChanged }
    }
}
private final class CloudFileCoordination: @unchecked Sendable { let value = NSFileCoordinator() }

actor CloudBackupStore {
    let transport: any CloudDocumentTransport
    init(transport: any CloudDocumentTransport = UbiquitousDocuments()) { self.transport = transport }
    func list() async throws -> (account: String,files: [CloudFile]) {
        let account = try await transport.account(); return (account,try await transport.files(folder:"Backups",account:account))
    }
    func save(_ backup: LibraryBackup,account: String) async throws -> String {
        let data = try backup.encoded(),id = UUID().uuidString
        try await transport.write(data,folder:"Backups",id:id,account:account); return id
    }
    func restore(_ id: String,account: String) async throws -> LibraryBackup {
        let data = try await transport.read(folder:"Backups",id:id,maximumBytes:LibraryBackup.maximumBytes,account:account)
        let backup = try LibraryBackup.decode(data)
        guard try await transport.account() == account else { throw CloudAccessError.accountChanged }; return backup
    }
    func delete(_ id: String,account: String) async throws { try await transport.remove(folder:"Backups",id:id,account:account) }
}

struct SyncVector: Codable, Equatable, Sendable {
    var values: [String:UInt64] = [:]
    func dominates(_ other: Self) -> Bool { other.values.allSatisfy { values[$0.key,default:0] >= $0.value } }
    mutating func merge(_ other: Self) { for (id,value) in other.values { values[id] = max(values[id,default:0],value) } }
    mutating func advance(_ device: String) throws { guard values[device] != nil || values.count < 64,values[device,default:0] < UInt64.max - 1 else { throw CloudAccessError.quota }; values[device,default:0] += 1 }
}
struct SyncEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case book,chapter,favorite,current,farthest,bookmark,settings,mediaCurrent,mediaBookmark }
    let kind: Kind
    let id: String
    let vector: SyncVector
    let device: String
    let counter: UInt64
    let deleted: Bool
    let payload: Data?
    var key: String { kind.rawValue + ":" + id }
    func validate() throws {
        guard !id.isEmpty,id.utf8.count <= 512,vector.values.count <= 64,counter > 0,vector.values[device] == counter,
              vector.values.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value > 0 }),deleted ? payload == nil : (payload?.count ?? 0) > 0,
              (payload?.count ?? 0) <= 512 * 1024 else { throw CloudAccessError.invalidData }
    }
}
struct SyncedPosition: Codable, Equatable, Sendable {
    let anchor: ReadingAnchor
    let chapterOrder: Int
    var rank: [Int] { [chapterOrder,anchor.paragraphIndex,anchor.utf16Offset] }
}
struct RecordSyncState: Codable, Sendable {
    var vector = SyncVector()
    var entries: [String:SyncEntry] = [:]
    var conflicts: [String] = []
    var seenJournals: [String:CloudFile] = [:]
    var alternatives: [String:[SyncEntry]]? = nil
    func validate() throws {
        guard entries.count <= 50000,conflicts.count <= 128,Set(conflicts).count == conflicts.count,seenJournals.count <= 4096,
              entries.values.reduce(0,{$0 + ($1.payload?.count ?? 0)}) <= 24 * 1024 * 1024 else { throw CloudAccessError.quota }
        for (key,entry) in entries { try entry.validate(); guard key == entry.key,vector.dominates(entry.vector) else { throw CloudAccessError.invalidData } }
        var alternativeBytes = 0
        for (key,versions) in alternatives ?? [:] {
            guard conflicts.contains(key),versions.count <= 8 else { throw CloudAccessError.invalidData }
            for entry in versions { try entry.validate(); guard entry.key == key,vector.dominates(entry.vector) else { throw CloudAccessError.invalidData }; alternativeBytes += entry.payload?.count ?? 0 }
        }
        guard alternativeBytes <= 8 * 1024 * 1024 else { throw CloudAccessError.quota }
    }
    mutating func edit(kind: SyncEntry.Kind,id: String,payload: Data?,device: String) throws {
        let key = kind.rawValue + ":" + id
        if kind == .farthest,let old = entries[key]?.payload,let payload,
           let previous = try? JSONDecoder().decode(SyncedPosition.self,from:old),let next = try? JSONDecoder().decode(SyncedPosition.self,from:payload),next.rank.lexicographicallyPrecedes(previous.rank) { return }
        try vector.advance(device)
        let entry = SyncEntry(kind:kind,id:id,vector:vector,device:device,counter:vector.values[device]!,deleted:payload == nil,payload:payload)
        try entry.validate(); entries[entry.key] = entry
        alternatives?.removeValue(forKey:entry.key); conflicts.removeAll{$0 == entry.key}
    }
    mutating func merge(_ incoming: SyncEntry) throws {
        try incoming.validate(); vector.merge(incoming.vector)
        guard let old = entries[incoming.key] else { entries[incoming.key] = incoming; return }
        if old == incoming { return }
        if old.vector == incoming.vector { throw CloudAccessError.invalidData }
        let incomingNewer = incoming.vector.dominates(old.vector),oldNewer = old.vector.dominates(incoming.vector)
        if oldNewer { return }
        if incoming.kind == .farthest,!old.deleted,!incoming.deleted,let a = old.payload,let b = incoming.payload {
            let first = try JSONDecoder().decode(SyncedPosition.self,from:a),second = try JSONDecoder().decode(SyncedPosition.self,from:b)
            if second.rank.lexicographicallyPrecedes(first.rank) { return }
        }
        if incomingNewer {
            entries[incoming.key] = incoming
            if (alternatives?[incoming.key] ?? []).allSatisfy({incoming.vector.dominates($0.vector)}) { alternatives?.removeValue(forKey:incoming.key); conflicts.removeAll{$0 == incoming.key} }
            else if var versions = alternatives?[incoming.key] { versions.removeAll{incoming.vector.dominates($0.vector)}; versions.append(incoming); alternatives?[incoming.key] = versions }
            return
        }
        if !conflicts.contains(incoming.key) { guard conflicts.count < 128 else { throw CloudAccessError.quota }; conflicts.append(incoming.key) }
        var versions = alternatives?[incoming.key] ?? []
        for entry in [old,incoming] where !versions.contains(entry) { versions.append(entry) }
        guard versions.count <= 8 else { throw CloudAccessError.quota }
        if alternatives == nil { alternatives = [:] }; alternatives?[incoming.key] = versions
        let bytes = alternatives?.values.flatMap{$0}.reduce(0,{$0 + ($1.payload?.count ?? 0)}) ?? 0
        guard bytes <= 8 * 1024 * 1024 else { throw CloudAccessError.quota }
        if old.deleted != incoming.deleted { if incoming.deleted { entries[incoming.key] = incoming }; return }
        if incoming.counter > old.counter || incoming.counter == old.counter && incoming.device > old.device { entries[incoming.key] = incoming }
    }
}

actor CloudRecordStore {
    private struct Journal: Codable { let format: String; let version: Int; let digest: String; let payload: Data }
    private let transport: any CloudDocumentTransport
    private let root: URL
    private let writer: any AtomicFileWriting
    private let device: String
    private var syncing = false
    init(directory: URL,device: String,transport: any CloudDocumentTransport = UbiquitousDocuments(),writer: any AtomicFileWriting = AtomicFileWriter()) { root = directory; self.device = device; self.transport = transport; self.writer = writer }
    private func location(_ account: String) throws -> URL {
        guard account.count == 64,account.allSatisfy({"0123456789abcdef".contains($0)}) else { throw CloudAccessError.invalidData }
        let directory = root.appendingPathComponent(account); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); return directory.appendingPathComponent("sync-state.json")
    }
    func synchronize(_ desired: [SyncEntry.Kind:[String:Data]],account: String,resolutions: [String:SyncEntry] = [:],apply: @Sendable (RecordSyncState) async throws -> Void = { _ in }) async throws -> RecordSyncState {
        guard !syncing else { throw CloudAccessError.unavailable }; syncing = true; defer { syncing = false }
        let file = try location(account)
        if FileManager.default.fileExists(atPath:file.path) { guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 32 * 1024 * 1024 else { throw CloudAccessError.quota } }
        var state = FileManager.default.fileExists(atPath:file.path) ? try JSONDecoder().decode(RecordSyncState.self,from:Data(contentsOf:file)) : .init()
        try state.validate()
        let clockFile = file.deletingLastPathComponent().appendingPathComponent("device-clock.json")
        if FileManager.default.fileExists(atPath:clockFile.path) {
            guard (try clockFile.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 4096 else { throw CloudAccessError.invalidData }
            let floor = try JSONDecoder().decode(UInt64.self,from:Data(contentsOf:clockFile))
            if floor > 0 { state.vector.values[device] = max(state.vector.values[device,default:0],floor) }
        }
        let old = state
        // Capture local differences before pulling, so an offline edit remains
        // concurrent with remote edits instead of silently overwriting them.
        for (kind,items) in desired {
            for (id,payload) in items where state.entries[kind.rawValue + ":" + id]?.payload != payload || state.entries[kind.rawValue + ":" + id]?.deleted == true {
                try state.edit(kind:kind,id:id,payload:payload,device:device)
            }
            for entry in old.entries.values where entry.kind == kind && !entry.deleted && items[entry.id] == nil { try state.edit(kind:kind,id:entry.id,payload:nil,device:device) }
        }
        var local = state.entries.values.filter { old.entries[$0.key] != $0 }
        let list = try await transport.files(folder:"Records-v1",account:account)
        guard list.count <= 4096 else { throw CloudAccessError.quota }
        for item in list {
            try Task.checkCancellation()
            if state.seenJournals[item.id] == item { continue }
            let data = try await transport.read(folder:"Records-v1",id:item.id,maximumBytes:8 * 1024 * 1024,account:account)
            let journal = try JSONDecoder().decode(Journal.self,from:data)
            guard journal.format == "yueshan-records",journal.version == 1,FileResourceStore.digest(journal.payload) == journal.digest else { throw CloudAccessError.invalidData }
            let changes = try JSONDecoder().decode([SyncEntry].self,from:journal.payload)
            guard changes.count <= 5000 else { throw CloudAccessError.quota }; for entry in changes { try state.merge(entry) }
            guard state.entries.count <= 50000,state.entries.values.reduce(0,{$0 + ($1.payload?.count ?? 0)}) <= 24 * 1024 * 1024 else { throw CloudAccessError.quota }
            state.seenJournals[item.id] = item
        }
        for (key,choice) in resolutions {
            guard key == choice.key,state.alternatives?[key]?.contains(choice) == true else { throw CloudAccessError.invalidData }
            try state.edit(kind:choice.kind,id:choice.id,payload:choice.payload,device:device)
            local.removeAll{$0.key == key}; if let resolved = state.entries[key] { local.append(resolved) }
        }
        guard try await transport.account() == account else { throw CloudAccessError.accountChanged }
        try state.validate()
        let encoded = try JSONEncoder().encode(state); guard encoded.count <= 32 * 1024 * 1024 else { throw CloudAccessError.quota }
        if !local.isEmpty {
            // Reserve the clock before publishing. A crash or failed local
            // apply must never reuse a stamp for a different payload on retry.
            try writer.write(JSONEncoder().encode(state.vector.values[device,default:0]),to:clockFile)
            var batches: [[SyncEntry]] = [],batch: [SyncEntry] = [],bytes = 2
            for entry in local.sorted(by:{$0.key < $1.key}) {
                let size = try JSONEncoder().encode(entry).count + 1
                if !batch.isEmpty && (bytes + size > 5 * 1024 * 1024 || batch.count >= 5000) { batches.append(batch); batch = []; bytes = 2 }
                batch.append(entry); bytes += size
            }
            if !batch.isEmpty { batches.append(batch) }
            for batch in batches {
                try Task.checkCancellation()
                let payload = try JSONEncoder().encode(batch)
                let journal = Journal(format:"yueshan-records",version:1,digest:FileResourceStore.digest(payload),payload:payload)
                try await transport.write(JSONEncoder().encode(journal),folder:"Records-v1",id:UUID().uuidString,account:account)
            }
        }
        guard try await transport.account() == account else { throw CloudAccessError.accountChanged }
        try await apply(state)
        guard try await transport.account() == account else { throw CloudAccessError.accountChanged }
        try writer.write(encoded,to:file); return state
    }
}
