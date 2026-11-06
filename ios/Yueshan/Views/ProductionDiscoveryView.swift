import SwiftUI

struct ProductionSubscriptionsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"发现与订阅",subtitle:"来源订阅 · 真实书籍流 · 书架更新",icon:"safari")
                AppSettingsCard("来源订阅",icon:"bell.badge") {
                    ForEach(library.sources) { source in
                        VStack(alignment:.leading,spacing:7) {
                            Toggle(source.name,isOn:Binding(get:{library.subscribedSourceIDs.contains(source.id)},set:{library.subscribe(sourceID:source.id,enabled:$0)}))
                                .disabled(!source.enabled || (source.id != "shushan" && (try? SourcePackages.rules(source)) == nil))
                            Text((try? SourcePackages.rules(source))?.discover != nil ? "支持分类发现和书架更新" : "分类发现未支持；可用来源支持书架更新检查")
                                .font(.system(size:11)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                Button(busy ? "正在检查" : "检查已订阅书源的书架更新") {
                    operation?.cancel(); busy = true; message = nil
                    operation = Task {
                        defer { if !Task.isCancelled { busy = false } }
                        do {
                            let result = try await library.checkSubscribedUpdates(); try Task.checkCancellation()
                            message = "已检查 \(result.checked) 本 · 新增 \(result.added) 章 · 失败 \(result.failed) 本"
                        } catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                if busy { ProgressView(); Button("取消") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent) }
                Text("本版仅在你主动点击时检查，退到后台取消；不承诺系统定时后台更新。只标记实际新增章节，回读和重复检查不会重复提醒。关闭订阅保留已有作品、历史和缓存。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
                ForEach(library.updatedBooks) { book in
                    NavigationLink { BookDetailView(book:book) } label: { HStack { Text(book.title); Spacer(); Text("新增 \(library.updateCount(book)) 章") }.font(.system(size:13)) }
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("发现与订阅").navigationBarTitleDisplayMode(.inline)
            .onDisappear { operation?.cancel() }
            .onReceive(NotificationCenter.default.publisher(for:UIApplication.didEnterBackgroundNotification)) { _ in operation?.cancel(); busy = false }
    }
}

struct SubscribedDiscoverySection: View {
    let category: String
    @EnvironmentObject private var library: LibraryStore
    @State private var books: [LibraryBookRecord] = []
    @State private var nextPage: Int?
    @State private var busy = false
    @State private var message: String?
    @State private var partial = false
    private var key: String { category + library.subscribedSourceIDs.sorted().joined() + String(library.onlineRevision) }
    var body: some View {
        VStack(alignment:.leading,spacing:23) {
            SectionHeading(title:"已订阅的故事",subtitle:"\(books.count) 个来源版本")
            if busy { ProgressView("正在读取来源分类") }
            if library.subscribedSourceIDs.isEmpty {
                ContentUnavailableView("还没有订阅来源",systemImage:"bell",description:Text("订阅支持分类发现的来源后，这里显示实际书籍。"))
            }
            ForEach(books) { record in
                NavigationLink { BookDetailView(book:record.presentation(chapters:[]),onlineRecord:record) } label: { BookRow(book:record.presentation(chapters:[])) }.buttonStyle(.plain)
            }
            if partial { Text("部分来源未返回结果，已保留其他来源的书籍。").font(.system(size:11)).foregroundStyle(Palette.muted) }
            if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.muted) }
            if let nextPage { Button("加载更多") { Task { await load(page:nextPage) } }.disabled(busy) }
        }.task(id:key) { books = []; nextPage = nil; message = nil; await load(page:1) }
    }
    @MainActor private func load(page: Int) async {
        guard !library.subscribedSourceIDs.isEmpty, let service = library.onlineService else { return }
        busy = true; defer { if !Task.isCancelled { busy = false } }
        do {
            let value = try await service.discover(category:category,page:page,subscribed:library.subscribedSourceIDs)
            try Task.checkCancellation(); var seen = Set(books.map(\.id)); let additions = value.books.filter { seen.insert($0.id).inserted }
            books += additions; nextPage = page > 1 && additions.isEmpty ? nil : value.nextPage; partial = value.hasPartialFailures
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}
