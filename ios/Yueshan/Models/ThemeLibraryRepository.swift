import Foundation

/// Theme catalog metadata lives in SQLite; CSS and SVG are immutable resources.
/// This module supplies staged records to the library's single commit queue.
final class ThemeLibraryRepository {
    private struct StoredAsset: Codable {
        let id: String
        let name: String
        let kind: ThemeAssetKind
        let resource: ResourceFileReference
        let sourceThemeID: String?
        let sourceName: String
        let favorite: Bool
    }
    private struct Archive: Codable {
        var version = 1
        let themes: [DemoTheme]
        let assets: [StoredAsset]
        let themeID: String
        let titleID: String?
        let bubbleID: String?
    }
    struct Staged {
        let data: Data
        let created: Set<ResourceFileReference>
        let references: [String: ResourceFileReference]
    }
    struct Loaded {
        let snapshot: ThemeLibrarySnapshot
        let warnings: [String]
    }
    private let files: FileResourceStore
    private var previous: [String: ResourceFileReference] = [:]
    init(directory: URL, writer: any AtomicFileWriting = AtomicFileWriter()) { files = .init(directory: directory, writer: writer) }
    func stage(_ snapshot: ThemeLibrarySnapshot) throws -> Staged {
        guard !snapshot.themes.isEmpty, Set(snapshot.themes.map(\.id)).count == snapshot.themes.count,
              Set(snapshot.assets.map(\.id)).count == snapshot.assets.count,
              snapshot.themes.contains(where: { $0.id == snapshot.themeID }) else { throw ContentFailure.invalidResponse }
        var created = Set<ResourceFileReference>(), references: [String: ResourceFileReference] = [:]
        do {
            let assets = try snapshot.assets.map { asset -> StoredAsset in
                let reference: ResourceFileReference
                if ThemeAssetValidator.isValid(asset.content, kind: asset.kind) {
                    let value = try files.stage(Data(asset.content.utf8), kind: asset.kind == .title ? .css : .svg)
                    reference = value.reference
                    if value.created { created.insert(reference) }
                } else if asset.content.isEmpty, let old = previous[asset.id], old.kind == (asset.kind == .title ? .css : .svg) {
                    reference = old // Keep a damaged resource reference until explicit removal or replacement.
                } else { throw ContentFailure.invalidResponse }
                references[asset.id] = reference
                return .init(id: asset.id, name: asset.name, kind: asset.kind, resource: reference,
                             sourceThemeID: asset.sourceThemeID, sourceName: asset.sourceName, favorite: asset.favorite)
            }
            let archive = Archive(themes: snapshot.themes, assets: assets, themeID: snapshot.themeID, titleID: snapshot.titleID, bubbleID: snapshot.bubbleID)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return .init(data: try encoder.encode(archive), created: created, references: references)
        } catch { files.discard(created); throw error }
    }
    func commit(_ staged: Staged) { previous = staged.references }
    func rollback(_ staged: Staged) { files.discard(staged.created) }
    func load(_ data: Data) throws -> Loaded {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1, !archive.themes.isEmpty, Set(archive.themes.map(\.id)).count == archive.themes.count,
              Set(archive.assets.map(\.id)).count == archive.assets.count,
              archive.assets.allSatisfy({ $0.resource.isValid && $0.resource.kind == ($0.kind == .title ? .css : .svg) }) else { throw ContentFailure.storageFailure }
        var warnings: [String] = []
        let assets = archive.assets.map { asset -> ThemeAsset in
            var content = (try? files.read(asset.resource)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !ThemeAssetValidator.isValid(content, kind: asset.kind) { content = ""; warnings.append(asset.name) }
            return .init(id: asset.id, name: asset.name, kind: asset.kind, content: content,
                         sourceThemeID: asset.sourceThemeID, sourceName: asset.sourceName, favorite: asset.favorite)
        }
        previous = Dictionary(uniqueKeysWithValues: archive.assets.map { ($0.id, $0.resource) })
        try files.collect(referenced: Set(previous.values))
        return .init(snapshot: .init(themes: archive.themes, assets: assets, themeID: archive.themeID,
                                    titleID: archive.titleID, bubbleID: archive.bubbleID), warnings: warnings)
    }
}
