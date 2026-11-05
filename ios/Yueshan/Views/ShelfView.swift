import SwiftUI

private enum ShelfCategory: String, CaseIterable {
    case novel, comic, audio

    var title: String {
        switch self { case .novel: "小说"; case .comic: "漫画"; case .audio: "听书" }
    }
    var icon: String {
        switch self { case .novel: "book.closed"; case .comic: "photo.on.rectangle"; case .audio: "headphones" }
    }
}

struct ShelfView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var titleSize = 28
    let onDiscover: () -> Void
    @State private var category: ShelfCategory = .novel
    @State private var filter = 0
    @State private var removal: ShelfRemoval?
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var confirmRemoval = false
    @State private var showUpdates = false
    @State private var showLocalImport = false
    // The bundled library currently contains novels only.
    private var categoryBooks: [Book] { category == .novel ? store.shelf : [] }
    private var categoryReadingCount: Int { categoryBooks.filter { store.progress[$0.id] != nil }.count }
    private var filteredBooks: [Book] {
        categoryBooks.filter { filter == 0 || (filter == 1 ? store.progress[$0.id] != nil : store.progress[$0.id] == nil) }
    }

    var body: some View {
        GeometryReader { geo in
            let columns = store.shelfLayout.columns
            let gap: CGFloat = store.shelfLayout == .spacious ? 21 : 12
            let coverWidth = max(1, (geo.size.width - 44 - gap * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("YOUR LITTLE READING CORNER").font(.system(size: 8, weight: .medium)).tracking(1.6).foregroundStyle(Palette.muted)
                            Spacer(minLength: 8)
                            Menu {
                                Button("本地导入", systemImage: "folder.badge.plus") { showLocalImport = true }
                                NavigationLink { SmartImportView() } label: { Label("智能导入", systemImage: "square.and.arrow.down") }
                            } label: {
                                Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(Palette.green)
                                    .frame(width: 44, height: 44).background(.white.opacity(0.7), in: Circle())
                            }.accessibilityLabel("添加书籍").accessibilityIdentifier("shelfAddBook")
                            Button(action: onDiscover) {
                                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Palette.green)
                                    .frame(width: 44, height: 44).background(.white.opacity(0.7), in: Circle())
                            }.accessibilityLabel("搜索好书")
                        }
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 14) { shelfTitle; categoryPicker }
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { shelfTitle; Spacer(minLength: 0); categoryPicker }
                                VStack(alignment: .leading, spacing: 14) { shelfTitle; categoryPicker }
                            }
                        }
                        Text("生活很忙，记得给自己留一页时间。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }

                    HStack(spacing: 17) {
                        ForEach(["shelf", "import", "fulltext"], id: \.self) { id in
                            NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id)) } label: { Label(id == "shelf" ? "书架分组" : FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon).font(.system(size: 11)).frame(minHeight: 36) }.accessibilityIdentifier("shelf-feature-\(id)")
                        }
                    }
                    if !managing && category == .novel {
                        if store.shelfLayout != .spines {
                            if let recent = store.recent { continueCard(recent) }
                            else { welcomeCard }
                        }
                        Button { showUpdates = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkles")
                                Text(store.updatedBooks.isEmpty ? "追更小报" : "\(store.updatedBooks.count) 本书有更新")
                                Text("模拟").font(.system(size: 8)).padding(.horizontal, 5).padding(.vertical, 3).background(Palette.green.opacity(0.08), in: Capsule())
                                Spacer()
                                Text("查看").font(.system(size: 10)); Image(systemName: "chevron.right").font(.system(size: 10))
                            }.font(.system(size: 12)).foregroundStyle(Palette.green).padding(15).background(Color(hex: 0xEEF0E6), in: .rect(cornerRadius: 12))
                        }.accessibilityIdentifier("shelfUpdates")
                    } else if managing {
                        HStack {
                            Text("已选择 \(selection.count) 本").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.green)
                            Spacer()
                            Button(selection.isSuperset(of: Set(filteredBooks.map(\.id))) ? "取消全选" : "全选") {
                                let visible = Set(filteredBooks.map(\.id))
                                if selection.isSuperset(of: visible) { selection.subtract(visible) } else { selection.formUnion(visible) }
                            }.font(.system(size: 12)).accessibilityIdentifier("selectAllBooks")
                        }
                    }
                    VStack(spacing: 20) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { statusFilters; Spacer(minLength: 0); shelfControls }
                            VStack(alignment: .leading, spacing: 4) {
                                statusFilters
                                HStack { Spacer(); shelfControls }
                            }
                        }

                        if filteredBooks.isEmpty {
                            ContentUnavailableView {
                                Label(category == .novel ? "这里还没有故事" : "还没有收藏的\(category.title)", systemImage: category.icon)
                            } description: {
                                Text(category == .novel ? "去发现一本喜欢的书，开启下一段旅程。" : "收藏的\(category.title)会显示在这里。")
                            } actions: {
                                if category == .novel {
                                    Button("去发现好书", action: onDiscover).buttonStyle(.borderedProminent)
                                }
                            }.padding(.vertical, 25).accessibilityIdentifier("shelfEmptyState")
                        } else if store.shelfLayout == .spines {
                            spineShelf(width: max(1, geo.size.width - 44))
                        } else if store.shelfLayout == .list {
                            LazyVStack(spacing: 21) {
                                ForEach(filteredBooks) { book in
                                    HStack {
                                        if managing { selectionIcon(book) }
                                        Button { if managing { toggleSelection(book) } else { store.read(book) } } label: { BookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier(managing ? "select-\(book.id)" : "list-read-\(book.id)")
                                    }.onLongPressGesture { beginManaging(book) }
                                    if book.id != filteredBooks.last?.id { Divider().overlay(Palette.line) }
                                }
                            }
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: columns), alignment: .leading, spacing: store.shelfLayout == .spacious ? 26 : 20) {
                                ForEach(filteredBooks) { book in bookCell(book, width: coverWidth) }
                            }
                        }
                    }
                    HStack { Spacer(); Text("阅山 · 让故事，继续发生").font(.system(size: 9)).tracking(2).foregroundStyle(Palette.muted.opacity(0.8)); Spacer() }.padding(.top, 4)
                }
                .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 24)
            }
            .background(Palette.background)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if managing {
                    HStack {
                        Text("移出后保留阅读历史与进度").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("移出书架 (\(selection.count))", role: .destructive) { confirmRemoval = true }.font(.system(size: 12, weight: .medium)).frame(minHeight: 44).disabled(selection.isEmpty).accessibilityIdentifier("removeSelected")
                    }.padding(.horizontal, 22).padding(.vertical, 7).background(.regularMaterial)
                } else if let removal {
                    HStack {
                        Text("已移出 \(removal.count) 本，进度仍然保留").font(.system(size: 11))
                        Spacer()
                        Button("撤销") { store.undoRemoval(removal); self.removal = nil }.font(.system(size: 12, weight: .semibold))
                        Button { self.removal = nil } label: { Image(systemName: "xmark").frame(width: 30, height: 34) }.accessibilityLabel("关闭提示")
                    }.foregroundStyle(.white).padding(.horizontal, 17).padding(.vertical, 7).background(Palette.green, in: .rect(cornerRadius: 12)).padding(.horizontal, 22).padding(.bottom, 10)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 7) {
                    Image(systemName: "mountain.2").font(.system(size: 13)).foregroundStyle(.white).frame(width: 25, height: 26).background(Palette.green, in: .rect(cornerRadius: 7))
                    Text("阅山").font(.system(size: 16, weight: .medium, design: .serif)).tracking(3).foregroundStyle(Palette.green)
                }.fixedSize().accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) { Text("在字里行间，遇见山海").font(.system(size: 9)).foregroundStyle(Palette.muted) }
        }
        .confirmationDialog("移出选中的 \(selection.count) 本书？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移出收藏，保留阅读进度", role: .destructive) {
                removal = store.removeFavorites(selection)
                selection = []; managing = false
            }
        } message: { Text("仍可在阅读历史里找到，或使用撤销恢复收藏。") }
        .sheet(isPresented: $showUpdates) { UpdatesView() }
        .sheet(isPresented: $showLocalImport) {
            NavigationStack {
                SmartImportView(openPickerOnAppear: true)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { showLocalImport = false } } }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
    }

    private var shelfTitle: some View {
        HStack(spacing: 0) {
            Text("我的书架").font(.system(size: titleSize, weight: .semibold, design: .serif)).tracking(1)
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier("shelfTitle")
            Text(".").font(.system(size: titleSize + 4, weight: .medium, design: .serif)).foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
        }.foregroundStyle(Palette.green).fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }

    private var categoryPicker: some View {
        HStack(spacing: 2) {
            ForEach(ShelfCategory.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        category = item
                        filter = 0
                        selection = []
                    }
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: category == item ? .semibold : .regular))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(category == item ? Palette.background : Palette.green.opacity(0.72))
                        .background(category == item ? Palette.green : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("shelf-category-\(item.rawValue)")
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
        }
        .padding(3).background(Palette.soft, in: .rect(cornerRadius: 11))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain).accessibilityLabel("书架栏目")
        .accessibilityIdentifier("shelfCategories")
    }

    private var statusFilters: some View {
        HStack(spacing: 8) {
            filterButton("全部", value: 0, count: categoryBooks.count)
            filterButton("在读", value: 1, count: categoryReadingCount)
            filterButton("未读", value: 2, count: categoryBooks.count - categoryReadingCount)
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var shelfControls: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("书架排序", selection: $store.sort) {
                    ForEach(ShelfSort.allCases, id: \.self) { sort in Text(sort.title).tag(sort) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13)).frame(width: 44, height: 44)
            }.accessibilityLabel("书架排序").accessibilityValue(store.sort.title).accessibilityIdentifier("shelfSort")
            Menu {
                Picker("书架布局", selection: $store.shelfLayout) {
                    ForEach(ShelfLayout.allCases, id: \.self) { layout in Text(layout.title).tag(layout) }
                }
            } label: {
                Image(systemName: store.shelfLayout == .list ? "list.bullet" : store.shelfLayout == .spines ? "books.vertical" : "square.grid.3x3")
                    .font(.system(size: 15)).frame(width: 44, height: 44)
            }.accessibilityLabel("书架布局").accessibilityValue(store.shelfLayout.title).accessibilityIdentifier("shelfLayout")
            Button(managing ? "完成" : "管理") { managing.toggle(); selection = [] }
                .font(.system(size: 11, weight: .medium)).frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(Palette.green).accessibilityIdentifier("manageShelf")
        }.foregroundStyle(Palette.muted).fixedSize(horizontal: true, vertical: false)
    }

    private func filterButton(_ title: String, value: Int, count: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { filter = value } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: filter == value ? .semibold : .regular))
                Text("\(count)").font(.system(size: 9))
            }.foregroundStyle(filter == value ? Palette.green : Palette.muted)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("shelf-filter-\(value)").accessibilityAddTraits(filter == value ? .isSelected : [])
    }

    private func continueCard(_ book: Book) -> some View {
        Button { store.read(book) } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Label("把时间，留给好故事", systemImage: "circle.fill").font(.system(size: 8)).foregroundStyle(Color(hex: 0x8F9A7D)).labelStyle(TinyDotLabel())
                    Text("翻开书，\n继续你的山海。").font(.system(size: 25, weight: .medium, design: .serif)).tracking(1).lineSpacing(8).foregroundStyle(Palette.green).padding(.top, 17)
                    Text("《\(book.title)》").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.green.opacity(0.8)).padding(.top, 14)
                    Text("上次读到 · \(book.chapterTitle(store.progress[book.id]?.chapter ?? 0))").font(.system(size: 8)).foregroundStyle(Palette.muted).lineLimit(1).padding(.top, 7)
                    HStack(spacing: 10) {
                        HStack(spacing: 13) { Text("继续阅读"); Image(systemName: "arrow.right") }.font(.system(size: 10, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 12).foregroundStyle(.white).background(Palette.green, in: .rect(cornerRadius: 8))
                        Text("已读 \(store.percent(book))%").font(.system(size: 8)).foregroundStyle(Palette.muted)
                    }.padding(.top, 20)
                }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                BookCover(book: book, width: 92).rotationEffect(.degrees(9)).padding(.leading, -8).padding(.trailing, 1)
                    .background { Circle().stroke(Palette.green.opacity(0.07), lineWidth: 1).frame(width: 175) }
                    .overlay(alignment: .topTrailing) { Text("✦").font(.system(size: 18)).foregroundStyle(Color(hex: 0x90A17D)).offset(x: 8, y: -27) }
            }.padding(.horizontal, 20).padding(.vertical, 25)
                .background(Color(hex: 0xEAEEDE), in: .rect(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(hex: 0xE0E6D4), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityIdentifier("continueReading").accessibilityLabel("继续阅读\(book.title)")
    }

    private var welcomeCard: some View {
        Button(action: onDiscover) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "mountain.2").font(.system(size: 30, weight: .ultraLight))
                Text("故事的起点，就在这一页。").font(.system(size: 24, design: .serif))
                Label("去发现好书", systemImage: "arrow.right").font(.system(size: 12))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(25).foregroundStyle(Palette.green).background(Color(hex: 0xEAEEDE), in: .rect(cornerRadius: 18))
        }.buttonStyle(.plain)
    }

    private func spineShelf(width: CGFloat) -> some View {
        let gap: CGFloat = 8
        let columns = max(3, Int((width + gap) / (dynamicTypeSize.isAccessibilitySize ? 100 : 64)))
        let spineWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = store.spineRows(for: filteredBooks, columns: columns)
        return LazyVStack(alignment: .leading, spacing: 26) {
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(row.books) { book in
                            let featured = row.featuredID == book.id
                            spineCell(book, width: featured ? spineWidth * 2 + gap : spineWidth, featured: featured)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Palette.line).frame(height: 4)
                        .shadow(color: Palette.green.opacity(0.06), radius: 3, y: 4)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("shelf-spine-row-\(row.id)")
            }
        }
    }

    private func spineCell(_ book: Book, width: CGFloat, featured: Bool) -> some View {
        VStack(spacing: 0) {
            Button { if managing { toggleSelection(book) } else { store.read(book) } } label: {
                Group {
                    if featured {
                        BookCover(book: book, width: width, titleLineLimit: 3)
                            .accessibilityElement(children: .ignore)
                            .overlay(alignment: .bottom) {
                                Text(store.progress[book.id] == nil ? "尚未开始" : "最近阅读").font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .foregroundStyle(Palette.green).background(Palette.background.opacity(0.95), in: Capsule())
                                    .padding(.bottom, 10)
                                    .accessibilityHidden(true).allowsHitTesting(false)
                            }
                    } else {
                        BookSpine(book: book, width: width, progress: store.percent(book), hasUpdates: store.updateCount(book) > 0)
                    }
                }
                .frame(width: width, height: featured ? width * 1.38 : 184)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(managing ? "选择\(book.title)" : "阅读\(book.title)，\(book.author)")
            .accessibilityValue("\(store.progress[book.id] == nil ? "尚未开始" : "已读 \(store.percent(book))%")\(store.updateCount(book) > 0 ? "，更新 \(store.updateCount(book)) 章" : "")")
            .accessibilityIdentifier(managing ? "select-\(book.id)" : "read-\(book.id)")
            .contextMenu { if !managing { bookActions(book) } }
            .overlay(alignment: .topLeading) {
                if featured && store.updateCount(book) > 0 {
                    Image(systemName: "bookmark.fill").font(.system(size: 15))
                        .foregroundStyle(Palette.accent).padding(.leading, 9).padding(.top, 3)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if managing { selectionIcon(book).scaleEffect(featured ? 1 : 0.8).padding(3).allowsHitTesting(false) }
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(featured ? "shelf-spine-cover-\(book.id)" : "shelf-spine-\(book.id)")
    }

    private func bookCell(_ book: Book, width: CGFloat) -> some View {
        let spacious = store.shelfLayout == .spacious
        let compact = store.shelfLayout == .compact
        return VStack(alignment: .leading, spacing: 0) {
            Button { if managing { toggleSelection(book) } else { store.read(book) } } label: {
                BookCover(book: book, width: width)
                    .frame(width: width, height: width * 1.38)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain).accessibilityLabel(managing ? "选择\(book.title)" : "阅读\(book.title)")
                .accessibilityValue(store.updateCount(book) > 0 ? "更新 \(store.updateCount(book)) 章" : "")
                .accessibilityIdentifier(managing ? "select-\(book.id)" : "read-\(book.id)")
                .contextMenu { if !managing { bookActions(book) } }
                .overlay(alignment: .topLeading) {
                    if !managing && store.updateCount(book) > 0 {
                        if spacious {
                            Text("更新 \(store.updateCount(book)) 章").font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 7).foregroundStyle(.white)
                                .background(Palette.accent, in: .rect(cornerRadius: 5)).padding(7).allowsHitTesting(false)
                        } else {
                            Circle().fill(Palette.accent).frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Palette.background, lineWidth: 2)).padding(6)
                                .accessibilityHidden(true).allowsHitTesting(false)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if managing { selectionIcon(book).padding(compact ? 2 : 7) }
                    else if spacious {
                        Menu { bookActions(book) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green)
                                .frame(width: 28, height: 28).background(.regularMaterial, in: Circle()).frame(width: 44, height: 44)
                        }.accessibilityLabel("\(book.title)的更多操作")
                    }
                }
            NavigationLink(value: book) {
                Text(book.title).font(.system(size: spacious ? 15 : compact ? 11 : 13, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.green).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, spacious ? 13 : 9).padding(.bottom, 6)
            }.buttonStyle(.plain).disabled(managing).accessibilityLabel("\(book.title)详情")
            if spacious {
                Text("\(book.author) · \(book.genre)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                    .accessibilityIdentifier("shelf-author-\(book.id)")
            }
            if !compact {
                HStack {
                    Text(store.progress[book.id] == nil ? "尚未开始" : "已读 \(store.percent(book))%")
                    if spacious {
                        Spacer(minLength: 2)
                        if let progress = store.progress[book.id] { Text("第\(progress.chapter + 1)章") }
                    }
                }.font(.system(size: spacious ? 8 : 9)).foregroundStyle(Palette.muted).padding(.top, spacious ? 13 : 0)
                    .accessibilityIdentifier("shelf-progress-\(book.id)")
            }
            if spacious {
                GeometryReader { geometry in
                    Capsule().fill(Palette.line)
                    Capsule().fill(Color(hex: 0x92A17B)).frame(width: geometry.size.width * Double(store.percent(book)) / 100)
                }.frame(height: 2).padding(.top, 7)
            }
        }.frame(width: width, alignment: .leading)
    }

    @ViewBuilder private func bookActions(_ book: Book) -> some View {
        Button("选择多本", systemImage: "checkmark.circle") { beginManaging(book) }
        Button("开始或继续阅读", systemImage: "book") { store.read(book) }
        Button("移出书架", systemImage: "bookmark.slash", role: .destructive) { removal = store.removeFavorites([book.id]) }
    }
    private func toggleSelection(_ book: Book) {
        if selection.contains(book.id) { selection.remove(book.id) } else { selection.insert(book.id) }
    }
    private func beginManaging(_ book: Book) {
        managing = true; selection.insert(book.id)
    }
    private func selectionIcon(_ book: Book) -> some View {
        Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: store.shelfLayout == .compact ? 20 : 24)).foregroundStyle(selection.contains(book.id) ? Palette.green : Palette.muted)
            .padding(3).background(Palette.background, in: Circle()).accessibilityHidden(true)
    }

}

struct TinyDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 4)); configuration.title }
    }
}
