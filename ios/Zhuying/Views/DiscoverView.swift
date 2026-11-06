import SwiftUI

struct DiscoverView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var online = OnlineSearchStore()
    var searchEntry = false
    @State private var query = ""
    @State private var discoveryFeedback: String?
    @State private var category = "全部"
    @State private var searchPresented = false
    @AppStorage("zhuying.discovery.richMode") private var richMode = false
    @AppStorage("zhuying.search.exactMatch") private var exactMatch = false
    @AppStorage("zhuying.discovery.sourceID") private var selectedSourceID = ""
    private var isRich: Bool { richMode && !searchEntry }
    private var selectedSource: DemoSource? { store.sources.first { $0.id == selectedSourceID && $0.enabled } ?? store.sources.first { $0.enabled } }
    private var searchSourceIDs: Set<String>? { isRich ? selectedSource.map { Set([$0.id]) } : nil }
    private var categories: [String] {
        if store.isDemo { return ["全部", "奇幻", "都市", "科幻", "古风", "悬疑", "仙侠"] }
        var seen: Set<String> = ["全部"]
        return ["全部"] + store.sources.flatMap { (try? SourcePackages.rules($0))?.categories ?? [] }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if isRich { richHeader } else {
                VStack(alignment: .leading, spacing: 13) {
                    Text("FIND YOUR NEXT CHAPTER").font(.system(size: 8)).tracking(2).foregroundStyle(appAppearance.palette.muted)
                    Text("下一段故事，\n从这里开始。").font(.system(size: 31, weight: .medium, design: .serif)).tracking(2).lineSpacing(8).foregroundStyle(appAppearance.palette.green)
                    Text("在熟悉的名字里重逢，在陌生的世界里出发。").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted).lineSpacing(4)
                }
                HStack(spacing: 12) {
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("search")) } label: { ThemeLabel("多源搜索", systemImage: "square.stack").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(appAppearance.palette.primary.opacity(0.07), in: .rect(cornerRadius: 10)) }.accessibilityIdentifier("discoverMultiSearch")
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("discover")) } label: { ThemeLabel("分类与订阅", systemImage: "bell.badge").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(appAppearance.palette.primary.opacity(0.07), in: .rect(cornerRadius: 10)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(categories, id: \.self) { item in
                            Button { category = item } label: {
                                Text(item).font(.system(size: 12, weight: item == category ? .medium : .regular)).padding(.horizontal, 17).frame(height: 36)
                                    .foregroundStyle(item == category ? appAppearance.palette.green : appAppearance.palette.muted)
                                    .background(item == category ? appAppearance.palette.surface(0xE5EBD9) : .clear, in: Capsule())
                            }.accessibilityAddTraits(item == category ? .isSelected : [])
                        }
                    }
                }
                }
                if searchEntry || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { exactSearchControl }
                if store.isDemo {
                let results = store.search(query, category: category).filter { !exactMatch || query.isEmpty || BookSearchMatching.exact(query, title: $0.title, author: $0.author) }
                SectionHeading(title: query.isEmpty ? "故事小馆" : "搜索结果", subtitle: "\(results.count) 部示例作品")
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Button("浏览全部作品") { query = ""; category = "全部" }.buttonStyle(PrimaryButtonStyle(filled: false))
                } else {
                    LazyVStack(spacing: 23) {
                        ForEach(results) { book in
                            NavigationLink(value: book) { BookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier("result-\(book.id)")
                            if book.id != results.last?.id { Divider().overlay(appAppearance.palette.line) }
                        }
                    }
                }
                } else {
                    if isRich && query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                        if let selectedSource { RichDiscoverySection(sourceID: selectedSource.id, feedback: $discoveryFeedback) }
                        else { ThemeUnavailableView("先添加书源", systemImage: "externaldrive", description: Text("从书源管理导入书源，再选择来源浏览发现分类。")); NavigationLink("管理书源") { SourceManagementView() } }
                    }
                    else if !searchEntry && query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { SubscribedDiscoverySection(category:category) }
                    else { onlineResults }
                }
            }.padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 25)
        }
        .appPageStyle()
        .navigationTitle(searchEntry ? "搜索" : "发现")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
        .onAppear { if searchEntry { searchPresented = true }; if !store.isDemo && !query.isEmpty { runSearch() } }
        .onChange(of: query) { _, _ in runSearch() }
        .toolbar { if !searchEntry { ToolbarItem(placement: .topBarTrailing) { modeMenu } } }
        .onChange(of: exactMatch) { _, _ in runSearch() }
        .onChange(of: richMode) { _, _ in runSearch() }
        .onChange(of: selectedSourceID) { _, _ in category = "全部"; runSearch() }
        .onChange(of: store.onlineRevision) { _, _ in runSearch() }
        .onDisappear { online.cancel() }
        .sourceFloatingFeedback(discoveryFeedback, identifier: "discoveryFeedback")
        .autocorrectionDisabled()
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
    }
    private var exactSearchControl: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("精准搜索", isOn: $exactMatch).font(.system(size: 13)).accessibilityIdentifier("exactSearchToggle")
            if exactMatch { Text("仅显示书名或作者完全匹配的结果；可继续加载后续页。").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted) }
        }
    }
    private var modeMenu: some View {
        Menu {
            Button { richMode = false } label: { ThemeLabel("简洁模式", systemImage: richMode ? "circle" : "checkmark.circle.fill") }.accessibilityIdentifier("discoverySimpleMode")
            Button { richMode = true } label: { ThemeLabel("丰富模式", systemImage: richMode ? "checkmark.circle.fill" : "circle") }.accessibilityIdentifier("discoveryRichMode")
            NavigationLink("分类与订阅") { FeatureDemoView(feature: FeatureCatalog.feature("discover")) }
            NavigationLink("管理书源") { SourceManagementView() }
        } label: { ThemeIcon(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("发现页模式").accessibilityIdentifier("discoveryMode")
    }
    private var richHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let selectedSource {
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceLogin"), scope: selectedSource.id) } label: {
                        ThemeIcon(systemName: "key.horizontal").frame(width: 44, height: 44).background(appAppearance.palette.primary.opacity(0.07), in: Circle())
                    }.accessibilityLabel("登录当前书源").accessibilityIdentifier("discoverySourceLogin")
                }
                Menu {
                    ForEach(store.sources.filter { $0.enabled }) { source in
                        Button { selectedSourceID = source.id } label: { ThemeLabel(source.name, systemImage: source.id == selectedSource?.id ? "checkmark" : "externaldrive") }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedSource?.name ?? "选择书源").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        ThemeIcon(systemName: "chevron.down").font(.system(size: 11))
                    }.frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 12).background(appAppearance.palette.primary.opacity(0.07), in: Capsule())
                }.accessibilityLabel("选择发现书源").accessibilityIdentifier("discoverySourcePicker")
                Button { searchPresented = true } label: { ThemeIcon(systemName: "magnifyingglass").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("搜索当前书源")
            }
            if let selectedSource {
                Text("\(selectedSource.url) · \(selectedSource.kind.rawValue)").font(.system(size: 11)).lineLimit(1).foregroundStyle(appAppearance.palette.muted)
                HStack(spacing: 10) {
                    NavigationLink { DemoSourceDetail(sourceID: selectedSource.id) } label: { ThemeLabel("书源详情", systemImage: "info.circle").font(.system(size: 12)).frame(minHeight: 44).contentShape(Rectangle()) }
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceEdit"), scope: selectedSource.id) } label: { ThemeLabel("书源设置", systemImage: "gearshape").font(.system(size: 12)).frame(minHeight: 44).contentShape(Rectangle()) }
                    Spacer()
                }
            }
        }
    }
    private func runSearch() {
        guard !store.isDemo, let service = store.onlineService else { return }
        online.search(query, service: service, exactMatch: exactMatch, sourceIDs: searchSourceIDs)
    }
    @ViewBuilder private var onlineResults: some View {
        SectionHeading(title: query.isEmpty ? "故事小馆" : "搜索结果", subtitle: "\(online.results.count) 个来源版本")
        if online.busy && online.results.isEmpty { ProgressView("正在搜索书源").frame(maxWidth: .infinity).accessibilityIdentifier("onlineSearching") }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ThemeUnavailableView("搜索书名或作者", systemImage: "magnifyingglass", description: Text(SourceDistributionPolicy.searchHelp))
        } else if online.results.isEmpty && !online.busy && online.message == nil { ContentUnavailableView.search(text: query) }
        if let message = online.message {
            Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("onlineSearchError")
            Button("重试") { runSearch() }.buttonStyle(PrimaryButtonStyle(filled: false))
            NavigationLink("管理书源与登录") { SourceManagementView() }
        }
        if online.partial { Text("部分站点未返回结果，已保留可用来源版本。").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted) }
        ForEach(online.sourceReports, id: \.sourceID) { report in
            Text("\(store.sources.first(where: { $0.id == report.sourceID })?.name ?? report.sourceID) · \(report.status) · \(report.count) 个结果")
                .font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
        }
        LazyVStack(spacing: 23) {
            ForEach(BookCandidateGroup.groups(online.results)) { group in
                if group.records.count > 1 { Text("同名同作者候选 · \(group.records.count) 个版本，内容尚未确认一致").font(.system(size:11)).foregroundStyle(appAppearance.palette.muted) }
                ForEach(group.records) { record in
                NavigationLink { BookDetailView(book: record.presentation(chapters: []), onlineRecord: record) } label: {
                    if isRich { RichDiscoveryBookRow(record: record) } else { BookRow(book: record.presentation(chapters: [])) }
                }.buttonStyle(.plain).accessibilityIdentifier("online-result-\(record.id)")
                if record.id != online.results.last?.id { Divider().overlay(appAppearance.palette.line) }
                }
            }
        }
        if online.nextPage != nil {
            Button(online.busy ? "正在加载" : "加载更多") { if let service = store.onlineService { online.more(service: service) } }
                .disabled(online.busy).accessibilityIdentifier("onlineSearchMore")
        }
    }

}
