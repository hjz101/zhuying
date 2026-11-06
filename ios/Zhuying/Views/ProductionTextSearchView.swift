import SwiftUI

struct ProductionTextSearchView: View {
    @Environment(\.themeAppearance) private var appAppearance
    var bookID: String?
    var onRead: ((Book, Int, Int, Int) -> Void)?
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var currentOnly = false
    @State private var result: LibraryStore.SearchResult?
    @State private var busy = false
    @State private var message: String?
    @FocusState private var queryFocused: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "全文搜索", subtitle: "检索真实本地正文和已缓存章节 · 跳转文字位置", icon: "doc.text.magnifyingglass")
                AppSettingsCard("配置与选项", icon: "slider.horizontal.3") {
                    TextField("正文关键词", text: $query).focused($queryFocused).submitLabel(.search).onSubmit { queryFocused = false }.accessibilityIdentifier("fulltextQuery")
                    Toggle("仅当前书籍", isOn: $currentOnly).disabled(bookID == nil)
                }
                if busy { ProgressView("正在检索正文") }
                if let result {
                    Text("检索范围：\(result.indexed) 章本地／缓存正文；另有 \(result.uncached) 章未缓存。最多显示 200 个命中。")
                        .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).accessibilityIdentifier("fulltextCoverage")
                    if result.hits.isEmpty && !query.isEmpty { Text("当前检索范围内没有命中，未缓存章节尚未检索。").font(.system(size: 12)) }
                    ForEach(result.hits) { hit in
                        if let book = library.books.first(where: { $0.id == hit.bookID }) {
                            Button { Task { await open(hit, book: book) } } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(book.title).font(.system(size: 13, weight: .medium))
                                    Text(String(hit.text.prefix(180))).font(.system(size: 12)).lineSpacing(5)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(appAppearance.palette.card, in: .rect(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("fulltext-hit-\(hit.id)")
                        }
                    }
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent) }
            }.padding(22)
        }.appPageStyle().navigationTitle("全文搜索").navigationBarTitleDisplayMode(.inline)
            .task(id: query + String(currentOnly)) {
                result = nil; message = nil
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { busy = false; return }
                busy = true
                do {
                    try await Task.sleep(for: .milliseconds(300))
                    let value = try await library.searchText(query, bookID: currentOnly ? bookID : nil)
                    try Task.checkCancellation(); result = value; busy = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { message = error.localizedDescription; busy = false } }
            }
    }
    @MainActor private func open(_ hit: TextSearchHit, book: Book) async {
        do {
            if let onRead {
                _ = try await library.openSearchHit(hit,present:false)
                guard let chapter = library.chapterIndex(bookID: book.id, chapterID: hit.chapterID) else { throw ContentFailure.missingChapter }
                onRead(book, chapter, hit.paragraph, hit.offset)
            } else { _ = try await library.openSearchHit(hit) }
        } catch { message = error.localizedDescription }
    }
}
