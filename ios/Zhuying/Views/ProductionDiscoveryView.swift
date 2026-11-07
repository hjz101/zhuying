import SwiftUI

struct ProductionSubscriptionsView: View {
    @Environment(\.themeAppearance) private var appAppearance
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
                                .disabled(!source.enabled || !SourcePackages.isRunnable(source))
                            Text(((try? SourcePackages.rules(source))?.discover != nil || (try? SourcePackages.legadoDefinition(source))?.exploreURL.isEmpty == false) ? "支持分类发现和书架更新" : "分类发现未支持；可用来源支持书架更新检查")
                                .font(.system(size:11)).foregroundStyle(appAppearance.palette.muted)
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
                if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent) }
                Text("本版仅在你主动点击时检查，退到后台取消；不承诺系统定时后台更新。只标记实际新增章节，回读和重复检查不会重复提醒。关闭订阅保留已有作品、历史和缓存。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
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
    @Environment(\.themeAppearance) private var appAppearance
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
                ThemeUnavailableView("还没有订阅来源",systemImage:"bell",description:Text("订阅支持分类发现的来源后，这里显示实际书籍。"))
            }
            ForEach(books) { record in
                NavigationLink { BookDetailView(book:record.presentation(chapters:[]),onlineRecord:record) } label: { BookRow(book:record.presentation(chapters:[])) }.buttonStyle(.plain)
            }
            if partial { Text("部分来源未返回结果，已保留其他来源的书籍。").font(.system(size:11)).foregroundStyle(appAppearance.palette.muted) }
            if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.muted) }
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

/// Source-scoped discovery reuses the same detail/read destinations as search.
struct RichDiscoverySection: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var model = OnlineDiscoveryStore()
    let sourceID: String
    @Binding var feedback: String?
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var expandedFilters = true
    @State private var showCategories = false
    @State private var activeFilter: SourceDiscoveryCategory?
    private var key: String { sourceID + ":" + String(library.onlineRevision) }
    private var filters: [SourceDiscoveryCategory] { model.categories.filter(\.isFilter) }
    private var browseCategories: [SourceDiscoveryCategory] { model.categories.filter { !$0.isFilter } }
    private var routes: [SourceDiscoveryCategory] { browseCategories.filter(\.readable) }
    private var filterColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: textSize.isAccessibilitySize ? 1 : 2)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !routes.isEmpty { categoryControls }
            if !filters.isEmpty { filterControls }
            HStack {
                SectionHeading(title: model.selected?.title ?? "来源发现", subtitle: "\(model.books.count) 部作品")
                Spacer()
                Button { if let service = library.onlineService { model.refresh(service: service) } } label: {
                    ThemeIcon(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }.disabled(model.busy).accessibilityLabel("刷新发现分类").accessibilityIdentifier("refreshDiscovery")
            }
            if model.busy { ProgressView(model.books.isEmpty ? "正在读取书源发现" : "正在更新筛选结果") }
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("discoveryError")
                Button("重试") { if let service = library.onlineService { model.refresh(service: service) } }
            } else if !model.busy && model.books.isEmpty && !model.categories.isEmpty && model.feedback == nil {
                ThemeUnavailableView("此分类暂未返回作品", systemImage: "books.vertical", description: Text("可切换分类，或登录当前书源后刷新。"))
            }
            LazyVStack(spacing: 20) {
                ForEach(model.books) { record in
                    NavigationLink { BookDetailView(book: record.presentation(chapters: []), onlineRecord: record) } label: {
                        RichDiscoveryBookRow(record: record)
                    }.buttonStyle(.plain).accessibilityIdentifier("discovery-book-" + record.id)
                    if record.id != model.books.last?.id { Divider().overlay(appAppearance.palette.line) }
                }
            }
            if model.partial { Text("部分来源读取失败，可刷新重试。").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted) }
            if model.nextPage != nil {
                Button(model.busy ? "正在加载" : "加载更多") { if let service = library.onlineService { model.more(service: service) } }
                    .disabled(model.busy).accessibilityIdentifier("discoveryMore")
            }
        }
        .task(id: key) { if let service = library.onlineService { model.open(sourceID: sourceID, service: service) } }
        .onChange(of: model.feedback) { _, message in feedback = message }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $showCategories) { categoriesPanel }
        .sheet(item: $activeFilter) { category in filterPanel(category) }
        .onChange(of: sourceID) { _, _ in activeFilter = nil; showCategories = false; expandedFilters = true }
    }

    private var categoryControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("浏览分类").font(.subheadline.weight(.semibold))
                Spacer()
                Button { showCategories = true } label: {
                    HStack(spacing: 5) {
                        Text("全部分类（\(routes.count)）")
                        ThemeIcon(systemName: "square.grid.2x2")
                    }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("discoveryAllCategories")
            }
            DiscoveryFlowLayout(spacing: 8) {
                ForEach(Array(routes.prefix(6))) { category in categoryButton(category) }
            }
            if let selected = model.selected, !routes.prefix(6).contains(where: { $0.id == selected.id }) {
                Text("当前：" + selected.title).font(.footnote).foregroundStyle(appAppearance.palette.muted)
                    .accessibilityIdentifier("discoveryCurrentCategory")
            }
        }.foregroundStyle(appAppearance.palette.green)
    }
    private func categoryButton(_ category: SourceDiscoveryCategory) -> some View {
        Button { chooseCategory(category) } label: {
            Text(category.title).font(.subheadline.weight(model.selected?.id == category.id ? .semibold : .regular))
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44)
                .background(appAppearance.palette.primary.opacity(model.selected?.id == category.id ? 0.17 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }.disabled(model.busy).accessibilityAddTraits(model.selected?.id == category.id ? .isSelected : [])
            .accessibilityIdentifier("discovery-category-" + category.title)
    }
    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { expandedFilters.toggle() } label: {
                HStack(spacing: 8) {
                    ThemeIcon(systemName: "line.3.horizontal.decrease")
                    Text("筛选").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(expandedFilters ? "收起" : "展开").font(.footnote)
                    ThemeIcon(systemName: expandedFilters ? "chevron.up" : "chevron.down").font(.footnote)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("discoveryFiltersToggle").accessibilityValue(expandedFilters ? "已展开" : "已收起")
            if expandedFilters {
                LazyVGrid(columns: filterColumns, alignment: .leading, spacing: 10) {
                    ForEach(filters) { category in
                        Button { activeFilter = category } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.title).font(.caption).foregroundStyle(appAppearance.palette.muted)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(category.filter?.choices.isEmpty == true ? "暂无选项" : (category.filter?.selectedValue.isEmpty == false ? category.filter!.selectedValue : "请选择"))
                                        .font(.subheadline.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    ThemeIcon(systemName: "chevron.down").font(.caption)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(12).background(appAppearance.palette.primary.opacity(0.06), in: .rect(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.disabled(model.busy || category.filter?.choices.isEmpty == true).accessibilityLabel(category.title)
                            .accessibilityValue(category.filter?.selectedValue ?? "请选择")
                            .accessibilityIdentifier("discovery-filter-" + category.title)
                    }
                }
            } else {
                Text(filters.compactMap { item in item.filter.map { item.title + "：" + $0.selectedValue } }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(appAppearance.palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(16).foregroundStyle(appAppearance.palette.green)
            .background(appAppearance.palette.card, in: .rect(cornerRadius: 16))
    }
    private var categoriesPanel: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(browseCategories) { category in
                        if category.isHeader {
                            Text(category.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(appAppearance.palette.muted).padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
                        } else {
                            Button { chooseCategory(category); showCategories = false } label: {
                                HStack(spacing: 12) {
                                    Text(category.title).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if model.selected?.id == category.id { ThemeIcon(systemName: "checkmark") }
                                }.font(.body).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(12).background(appAppearance.palette.primary.opacity(model.selected?.id == category.id ? 0.14 : 0.05), in: .rect(cornerRadius: 12))
                                    .contentShape(Rectangle())
                            }.disabled(model.busy).accessibilityIdentifier("discovery-category-" + category.title)
                                .accessibilityAddTraits(model.selected?.id == category.id ? .isSelected : [])
                        }
                    }
                }.padding(20)
            }.appPageStyle().navigationTitle("全部分类").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showCategories = false } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .presentationBackground(appAppearance.palette.background)
    }
    private func filterPanel(_ category: SourceDiscoveryCategory) -> some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(category.filter?.choices ?? [], id: \.self) { value in
                        Button {
                            activeFilter = nil
                            if let service = library.onlineService { model.applyFilter(category, value: value, service: service) }
                        } label: {
                            HStack(spacing: 12) {
                                Text(value).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if value == category.filter?.selectedValue { ThemeIcon(systemName: "checkmark.circle.fill") }
                            }.font(.body).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(12).background(appAppearance.palette.primary.opacity(value == category.filter?.selectedValue ? 0.14 : 0.05), in: .rect(cornerRadius: 12))
                                .contentShape(Rectangle())
                        }.accessibilityIdentifier("discovery-option-" + value)
                            .accessibilityAddTraits(value == category.filter?.selectedValue ? .isSelected : [])
                    }
                }.padding(20)
            }.appPageStyle().navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { activeFilter = nil } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .presentationBackground(appAppearance.palette.background)
    }
    private func chooseCategory(_ category: SourceDiscoveryCategory) {
        if let service = library.onlineService { model.select(category, service: service) }
    }
}

/// Category labels wrap to the available width, including larger text sizes.
private struct DiscoveryFlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let limit = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var frames: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            size.width = min(size.width, limit)
            if x > 0 && x + size.width > limit { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: limit, height: y + rowHeight), frames)
    }
}

struct RichDiscoveryBookRow: View {
    @Environment(\.themeAppearance) private var appAppearance
    let record: LibraryBookRecord
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SourceBookCover(record: record, width: 77, height: 107)
            VStack(alignment: .leading, spacing: 10) {
                Text(record.title).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(appAppearance.palette.green).lineLimit(3)
                Text("\(record.author.isEmpty ? "作者未提供" : record.author) · \(record.source?.provider ?? "在线来源")")
                    .font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted).lineLimit(2)
                if !record.summary.isEmpty { Text(record.summary).font(.system(size: 12)).lineSpacing(4).foregroundStyle(appAppearance.palette.muted).lineLimit(3) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ThemeIcon(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted).padding(.top, 35)
        }.frame(maxWidth: .infinity, minHeight: 107, alignment: .leading).contentShape(Rectangle())
    }
}
