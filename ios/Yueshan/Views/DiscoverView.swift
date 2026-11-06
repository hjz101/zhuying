import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var online = OnlineSearchStore()
    var searchEntry = false
    @State private var query = ""
    @State private var category = "全部"
    @State private var searchPresented = false
    private var categories: [String] {
        if store.isDemo { return ["全部", "奇幻", "都市", "科幻", "古风", "悬疑", "仙侠"] }
        var seen: Set<String> = ["全部"]
        return ["全部"] + store.sources.flatMap { (try? SourcePackages.rules($0))?.categories ?? [] }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("FIND YOUR NEXT CHAPTER").font(.system(size: 8)).tracking(2).foregroundStyle(Palette.muted)
                    Text("下一段故事，\n从这里开始。").font(.system(size: 31, weight: .medium, design: .serif)).tracking(2).lineSpacing(8).foregroundStyle(Palette.green)
                    Text("在熟悉的名字里重逢，在陌生的世界里出发。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                HStack(spacing: 12) {
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("search")) } label: { Label("多源搜索", systemImage: "square.stack").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(Palette.green.opacity(0.07), in: .rect(cornerRadius: 10)) }.accessibilityIdentifier("discoverMultiSearch")
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("discover")) } label: { Label("分类与订阅", systemImage: "bell.badge").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(Palette.green.opacity(0.07), in: .rect(cornerRadius: 10)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(categories, id: \.self) { item in
                            Button { category = item } label: {
                                Text(item).font(.system(size: 12, weight: item == category ? .medium : .regular)).padding(.horizontal, 17).frame(height: 36)
                                    .foregroundStyle(item == category ? Palette.green : Palette.muted)
                                    .background(item == category ? Color(hex: 0xE5EBD9) : .clear, in: Capsule())
                            }.accessibilityAddTraits(item == category ? .isSelected : [])
                        }
                    }
                }
                if store.isDemo {
                let results = store.search(query, category: category)
                SectionHeading(title: query.isEmpty ? "故事小馆" : "搜索结果", subtitle: "\(results.count) 部示例作品")
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Button("浏览全部作品") { query = ""; category = "全部" }.buttonStyle(PrimaryButtonStyle(filled: false))
                } else {
                    LazyVStack(spacing: 23) {
                        ForEach(results) { book in
                            NavigationLink(value: book) { BookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier("result-\(book.id)")
                            if book.id != results.last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
                } else {
                    if !searchEntry && query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { SubscribedDiscoverySection(category:category) }
                    else { onlineResults }
                }
            }.padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 25)
        }
        .background(Palette.background)
        .navigationTitle(searchEntry ? "搜索" : "发现")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
        .onAppear { if searchEntry { searchPresented = true }; if !store.isDemo && !query.isEmpty { runSearch() } }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: store.onlineRevision) { _, _ in runSearch() }
        .onDisappear { online.cancel() }
        .autocorrectionDisabled()
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
    }
    private func runSearch() {
        guard !store.isDemo, let service = store.onlineService else { return }
        online.search(query, service: service)
    }
    @ViewBuilder private var onlineResults: some View {
        SectionHeading(title: query.isEmpty ? "故事小馆" : "搜索结果", subtitle: "\(online.results.count) 个来源版本")
        if online.busy && online.results.isEmpty { ProgressView("正在搜索书源").frame(maxWidth: .infinity).accessibilityIdentifier("onlineSearching") }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("搜索书名或作者", systemImage: "magnifyingglass", description: Text("搜索已启用的可运行书源；书山聚合需先登录。不同来源版本分别保留。"))
        } else if online.results.isEmpty && !online.busy && online.message == nil { ContentUnavailableView.search(text: query) }
        if let message = online.message {
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("onlineSearchError")
            Button("重试") { runSearch() }.buttonStyle(PrimaryButtonStyle(filled: false))
            NavigationLink("管理书源与登录") { SourceManagementView() }
        }
        if online.partial { Text("部分站点未返回结果，已保留可用来源版本。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
        ForEach(online.sourceReports, id: \.sourceID) { report in
            Text("\(store.sources.first(where: { $0.id == report.sourceID })?.name ?? report.sourceID) · \(report.status) · \(report.count) 个结果")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        LazyVStack(spacing: 23) {
            ForEach(BookCandidateGroup.groups(online.results)) { group in
                if group.records.count > 1 { Text("同名同作者候选 · \(group.records.count) 个版本，内容尚未确认一致").font(.system(size:11)).foregroundStyle(Palette.muted) }
                ForEach(group.records) { record in
                NavigationLink { BookDetailView(book: record.presentation(chapters: []), onlineRecord: record) } label: {
                    BookRow(book: record.presentation(chapters: []))
                }.buttonStyle(.plain).accessibilityIdentifier("online-result-\(record.id)")
                if record.id != online.results.last?.id { Divider().overlay(Palette.line) }
                }
            }
        }
        if online.nextPage != nil {
            Button(online.busy ? "正在加载" : "加载更多") { if let service = store.onlineService { online.more(service: service) } }
                .disabled(online.busy).accessibilityIdentifier("onlineSearchMore")
        }
    }

}
