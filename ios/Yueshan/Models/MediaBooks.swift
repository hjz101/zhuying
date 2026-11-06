import Foundation
import PDFKit
import ImageIO

struct MediaBookReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case pdf,comic }
    let kind: Kind
    let resources: [ResourceFileReference]
    let pageCount: Int
    func validate() throws {
        guard pageCount > 0,pageCount <= 2000,!resources.isEmpty,resources.allSatisfy(\.isValid),resources.reduce(0,{$0 + $1.bytes}) <= BoundedArchive.maximumExpanded,
              kind == .pdf ? resources.count == 1 && resources[0].kind == .pdf : resources.count == pageCount && resources.allSatisfy({$0.kind == .image}) else { throw ContentFailure.invalidResponse }
    }
}
struct MediaReadingLocation: Codable, Equatable, Sendable {
    var page: Int
    var x: Double = 0
    var y: Double = 1
    var zoom: Double = 1
    var updatedAt: Date = Date()
    func validated(pages: Int) -> Self {
        .init(page:min(max(0,page),max(0,pages - 1)),x:x.isFinite ? min(1,max(0,x)) : 0,y:y.isFinite ? min(1,max(0,y)) : 1,zoom:zoom.isFinite ? min(5,max(0.2,zoom)) : 1,updatedAt:updatedAt)
    }
}
struct MediaBookmark: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bookID: String
    var title: String
    let location: MediaReadingLocation
}
struct PDFOutlineItem: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let page: Int
    let depth: Int
    static func load(_ url: URL) -> [Self] {
        guard let document = PDFDocument(url:url),let root = document.outlineRoot else { return [] }
        var result: [Self] = [],visited = Set<ObjectIdentifier>()
        func visit(_ outline: PDFOutline,depth: Int) {
            guard depth < 16,result.count < 2000,visited.insert(ObjectIdentifier(outline)).inserted else { return }
            if let page = outline.destination?.page,let label = outline.label {
                result.append(.init(id:result.count,title:String(label.prefix(256)),page:document.index(for:page),depth:depth))
            }
            for index in 0..<min(outline.numberOfChildren,2000) { if let child = outline.child(at:index) { visit(child,depth:depth + 1) } }
        }
        visit(root,depth:0); return result
    }
}
enum MediaBookImporter {
    static func originalPDF(_ data: Data,name: String) throws -> PreparedBookImport {
        try BookImporter.validateSize(data.count)
        guard let pdf = PDFDocument(data:data),!pdf.isLocked,pdf.pageCount > 0,pdf.pageCount <= 2000 else { throw BookImportError.message("PDF 无法打开、已加密或超过 2000 页；原文件保留。") }
        let reference = ResourceFileReference(digest:FileResourceStore.digest(data),bytes:data.count,kind:.pdf)
        let media = MediaBookReference(kind:.pdf,resources:[reference],pageCount:pdf.pageCount)
        let title = (name as NSString).deletingPathExtension
        let book = Book(id:"local-pdf-" + reference.digest,title:title,author:"本地导入",genre:"本地书籍",category:"其他",status:"已完结",words:"\(pdf.pageCount) 页",color:"sage",subtitle:"PDF 原版式",intro:"保留原始页面；扫描页可浏览，不代表文字识别。",tags:["本地","PDF"],chapters:(0..<pdf.pageCount).map{"第 \($0 + 1) 页"},content:(0..<pdf.pageCount).map{["原版式页面索引 \($0 + 1)"]},media:media)
        return .init(book:book,bytes:data.count,encoding:"PDF 原版式",resources:[reference:data])
    }
    static func comic(_ members: [ArchiveMember],name: String) throws -> PreparedBookImport {
        let images = members.filter { !$0.directory && ["png","jpg","jpeg","webp","gif"].contains($0.format) }
        guard !images.isEmpty,images.count <= 2000 else { throw BookImportError.message("归档没有支持的图片，或超过 2000 页。") }
        var resources: [ResourceFileReference:Data] = [:],references: [ResourceFileReference] = []
        for item in images {
            try Task.checkCancellation(); try validateImage(item.data)
            let ref = ResourceFileReference(digest:FileResourceStore.digest(item.data),bytes:item.data.count,kind:.image)
            references.append(ref); resources[ref] = item.data
        }
        let media = MediaBookReference(kind:.comic,resources:references,pageCount:images.count); try media.validate()
        let digest = StableContentID.list(references.map(\.digest)),title = (name as NSString).deletingPathExtension
        let book = Book(id:"local-comic-" + digest,title:title,author:"本地导入",genre:"漫画",category:"漫画",status:"已完结",words:"\(images.count) 页",color:"sage",subtitle:"图片漫画",intro:"本地图片，按文件名自然顺序阅读。",tags:["本地","漫画"],chapters:images.map(\.path),content:images.indices.map{["图片页面索引 \($0 + 1)"]},media:media)
        return .init(book:book,bytes:resources.values.reduce(0,{$0 + $1.count}),encoding:"图片归档 · \(images.count) 页",resources:resources)
    }
    static func validateImage(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024,let source = CGImageSourceCreateWithData(data as CFData,nil),let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,let height = info[kCGImagePropertyPixelHeight] as? Int,width > 0,height > 0,width <= 16000,height <= 32000,width * height <= 32_000_000 else { throw BookImportError.message("图片损坏或过大（单页 ≤ 8 MB／3200 万像素）。") }
    }
}

final class MediaResourceStore: @unchecked Sendable {
    let files: FileResourceStore
    init(directory: URL,writer: any AtomicFileWriting = AtomicFileWriter()) { files = .init(directory:directory,writer:writer) }
    func stage(_ resources: [ResourceFileReference:Data],required: [ResourceFileReference]) throws -> Set<ResourceFileReference> {
        var created = Set<ResourceFileReference>()
        do {
            for reference in Set(required) {
                if let data = resources[reference] {
                    guard reference.isValid,FileResourceStore.digest(data) == reference.digest,data.count == reference.bytes else { throw ContentFailure.invalidResponse }
                    let staged = try files.stage(data,kind:reference.kind); if staged.created { created.insert(reference) }
                } else { _ = try files.read(reference) }
            }
            return created
        } catch { files.discard(created); throw error }
    }
    func backup(_ required: Set<ResourceFileReference>) throws -> [LibraryBackup.File] {
        try required.sorted { $0.filename < $1.filename }.map { .init(path:"media/" + $0.filename,data:try files.read($0)) }
    }
}
