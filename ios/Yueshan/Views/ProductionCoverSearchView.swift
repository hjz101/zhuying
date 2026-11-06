import SwiftUI

struct ProductionCoverSearchView: View {
    var bookID: String? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var selected = ""
    @State private var query = ""
    @State private var results: [CoverSearchResult] = []
    @State private var preview: Data?
    @State private var previewResult: CoverSearchResult?
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void,Never>?
    private let client = CoverSearchClient()
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"封面搜索",subtitle:"搜索 · 预览选择 · 保存到当前作品",icon:"photo")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("目标作品",selection:$selected) { Text("选择作品").tag(""); ForEach(library.books) { Text($0.title).tag($0.id) } }.accessibilityIdentifier("coverBook")
                    TextField("书名",text:$query).textInputAutocapitalization(.never).accessibilityIdentifier("coverQuery")
                    Button("搜索封面") { search() }.disabled(selected.isEmpty || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || busy).accessibilityIdentifier("coverSearch")
                }
                ForEach(results) { result in
                    Button { preview(result) } label: { HStack { VStack(alignment:.leading,spacing:6) { Text(result.title); Text(result.author).font(.system(size:11)).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName:"photo") }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Palette.card,in:.rect(cornerRadius:10)) }.disabled(busy).accessibilityIdentifier("cover-result-" + result.id)
                }
                if let preview,let image = UIImage(data:preview) {
                    Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:260).accessibilityIdentifier("coverPreview")
                    Text(previewResult?.title ?? "").font(.system(size:12))
                    HStack { Button("取消选择") { self.preview = nil; previewResult = nil }; Spacer(); Button("保存封面") { save() }.disabled(selected.isEmpty || busy).accessibilityIdentifier("coverSave") }
                }
                if busy { ProgressView("正在处理封面"); Button("取消") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent).accessibilityIdentifier("coverMessage") }
                Text("服务：Open Library。点击搜索时发送输入的书名；选择结果后才下载图片。保存后的封面随本地备份保留；取消或失败保留已有封面。服务未收录时可调整书名，或继续使用默认封面。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
                Link("Open Library 封面服务",destination:URL(string:"https://openlibrary.org/dev/docs/api/covers")!).font(.system(size:12))
            }.padding(22)
        }.appPageStyle().navigationTitle("封面搜索").navigationBarTitleDisplayMode(.inline)
            .onAppear { if let book = library.books.first(where:{$0.id == bookID}) ?? library.recent ?? library.books.first { selected = book.id; query = book.title } }
            .onChange(of:selected) { _,id in operation?.cancel(); busy = false; preview = nil; previewResult = nil; results = []; query = library.books.first(where:{$0.id == id})?.title ?? "" }
            .onDisappear { operation?.cancel() }
    }
    private func search() { perform { results = try await client.search(query); if results.isEmpty { message = "没有找到可用封面，可调整书名。" } } }
    private func preview(_ result: CoverSearchResult) { perform { let bytes = try await client.download(result); try Task.checkCancellation(); preview = bytes; previewResult = result } }
    private func save() { guard let preview else { return }; let id = selected; perform { try await library.saveCover(bookID:id,data:preview); message = "封面已保存。"; self.preview = nil; previewResult = nil } }
    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        operation?.cancel(); busy = true; message = nil
        operation = Task { defer { if !Task.isCancelled { busy = false } }; do { try await body() } catch { if !Task.isCancelled { message = "操作未完成，已有封面保留：\(error.localizedDescription)" } } }
    }
}
