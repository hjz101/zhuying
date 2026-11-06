import SwiftUI
import UniformTypeIdentifiers

struct ProductionArchiveView: View {
    var comicOnly = false
    var initialURL: URL? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var choosing = false
    @State private var members: [ArchiveMember] = []
    @State private var selection = Set<String>()
    @State private var fileName = ""
    @State private var originalPDF = true
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    @State private var message: String?
    private var supported: [ArchiveMember] { members.filter{!$0.directory && ["txt","epub","pdf"].contains($0.format)} }
    private var images: [ArchiveMember] { members.filter{!$0.directory && ["png","jpg","jpeg","webp","gif"].contains($0.format)} }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:comicOnly ? "漫画导入" : "压缩包支持",subtitle:"ZIP／RAR／7z · 内容预览 · 选择后入库",icon:"archivebox")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Button("选择归档文件") { choosing = true }.accessibilityIdentifier("archiveChoose")
                    if !fileName.isEmpty { Text(fileName).font(.system(size:12)); Text("实际解出 \(members.count) 项 · 文字文件 \(supported.count) · 图片 \(images.count)").font(.system(size:11)).accessibilityIdentifier("archiveSummary") }
                    if !comicOnly { Toggle("PDF 保留原版式",isOn:$originalPDF) }
                }
                if !comicOnly && !supported.isEmpty {
                    AppSettingsCard("导入预览",icon:"list.bullet") {
                        ForEach(supported) { item in
                            Toggle(isOn:Binding(get:{selection.contains(item.id)},set:{if $0 { selection.insert(item.id) } else { selection.remove(item.id) }})) {
                                Text(item.path).font(.system(size:12)).lineLimit(2)
                            }
                        }
                    }
                    Button("导入选中文件") { importBooks() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || selection.isEmpty).accessibilityIdentifier("archiveImportSelected")
                }
                if !images.isEmpty {
                    Text("按文件名自然排序导入 \(images.count) 张图片；仅显示支持的栅格图片首帧。").font(.system(size:12)).foregroundStyle(Palette.muted)
                    Button("将图片作为漫画导入") { importComic() }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("archiveImportComic")
                }
                if busy { ProgressView("正在处理归档"); Button("取消处理") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("archiveMessage") }
                Text("支持未加密、非分卷 ZIP／RAR／7z。单包 ≤ 20 MB，展开总量 ≤ 64 MB，最多 4000 项；禁止越界路径和链接。仅选中的 TXT／EPUB／PDF 入库，图片可按漫画导入；其他文件不会执行。取消保留已成功导入的作品，原包始终不改动。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle(comicOnly ? "漫画导入" : "压缩包支持").navigationBarTitleDisplayMode(.inline)
            .nativeFileImporter(isPresented:$choosing,allowedContentTypes:[.item]) { result in
                switch result {
                case .success(let url): load(url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
                }
            }
            .onDisappear { if !choosing { operation?.cancel(); members = [] } }
            .task { if let initialURL,members.isEmpty { load(initialURL) } }
    }
    private func load(_ url: URL) {
        operation?.cancel(); busy = true; message = nil; members = []; selection = []; fileName = url.lastPathComponent
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let worker = Task.detached { () throws -> [ArchiveMember] in
                    return try BoundedArchive.read(ImportedFileReader.read(url, maximumBytes: BookImporter.maximumBytes))
                }
                let result = try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                try Task.checkCancellation(); members = result; selection = Set(supported.prefix(20).map(\.id))
                if supported.isEmpty && images.isEmpty { message = "此归档没有支持的文字或图片文件。" }
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func importBooks() {
        guard selection.count <= 20 else { message = "一次最多导入 20 本，请分批选择。"; return }
        busy = true; message = nil
        let items = supported.filter{selection.contains($0.id)},mode = originalPDF
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            var added = 0,duplicates = 0,errors: [String] = []
            for item in items {
                do {
                    try Task.checkCancellation()
                    let prepared = try await Task.detached { try mode && item.format == "pdf" ? MediaBookImporter.originalPDF(item.data,name:(item.path as NSString).lastPathComponent) : BookImporter.prepare(data:item.data,name:(item.path as NSString).lastPathComponent) }.value
                    if try await library.importBookDurably(prepared.book,resources:prepared.resources) { added += 1 } else { duplicates += 1 }
                    selection.remove(item.id)
                } catch is CancellationError { break }
                catch { errors.append("\(item.path)：\(error.localizedDescription)") }
            }
            message = "已导入 \(added) · 重复 \(duplicates) · 失败 \(errors.count)" + (errors.isEmpty ? "" : "\n" + errors.joined(separator:"\n"))
        }
    }
    private func importComic() {
        busy = true; message = nil; let selected = images,name = fileName
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let prepared = try await Task.detached { try MediaBookImporter.comic(selected,name:name) }.value
                try Task.checkCancellation(); let added = try await library.importBookDurably(prepared.book,resources:prepared.resources)
                message = added ? "漫画已导入，共 \(prepared.book.chapters.count) 页。" : "同一漫画已在书库中。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct ProductionMediaLibrary: View {
    let kind: MediaBookReference.Kind
    @EnvironmentObject private var library: LibraryStore
    @State private var importing = false
    private var books: [Book] { library.books.filter{$0.media?.kind == kind} }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:kind == .pdf ? "PDF 阅读" : "漫画阅读",subtitle:kind == .pdf ? "原版式 · 页码／坐标 · 文档目录" : "页漫／条漫 · 本地图片 · 页面书签",icon:kind == .pdf ? "doc.richtext" : "photo.on.rectangle")
                Button(kind == .pdf ? "导入原版式 PDF" : "导入图片归档") { importing = true }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("mediaImport")
                if books.isEmpty { ContentUnavailableView("还没有页面作品",systemImage:"doc",description:Text("导入自己的文件后开始阅读。")) }
                ForEach(books) { book in Button { library.reader = .init(book:book,chapter:0,resume:true) } label: { HStack { Text(book.title); Spacer(); Text("\(book.chapters.count) 页").font(.system(size:12)) }.frame(minHeight:48) }.accessibilityIdentifier("open-media-\(book.id)") }
                Text(kind == .pdf ? "原版式保留 PDF 页面，扫描文档可浏览；需要朗读和全文搜索时，请另选文字提取导入。" : "只加载可见页面及邻页；内存警告时清理可重建图片缓存。网络漫画需要独立来源能力，当前导入本地图片归档。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle(kind == .pdf ? "PDF 阅读" : "漫画阅读").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented:$importing) { NavigationStack {
                Group { if kind == .pdf { SmartImportView(openPickerOnAppear:true,originalPDFMode:true) } else { ProductionArchiveView(comicOnly:true) } }
                    .toolbar { Button("完成") { importing = false } }
            } }
    }
}
