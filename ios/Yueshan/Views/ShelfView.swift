import SwiftUI

struct ShelfView: View {
    @EnvironmentObject private var store: LibraryStore
    let onDiscover: () -> Void
    @State private var filter = 0
    @State private var listLayout = false
    @State private var removal: ShelfRemoval?
    @State private var managing = false
    @State private var selection = Set<String>()
    @State private var confirmRemoval = false
    @State private var showUpdates = false
    private var filteredBooks: [Book] {
        store.shelf.filter { filter == 0 || (filter == 1 ? store.progress[$0.id] != nil : store.progress[$0.id] == nil) }
    }

    var body: some View {
        GeometryReader { geo in
            let coverWidth = max(95, (geo.size.width - 65) / 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 27) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("YOUR LITTLE READING CORNER").font(.system(size: 8, weight: .medium)).tracking(1.6).foregroundStyle(Palette.muted)
                            HStack(spacing: 0) {
                                Text("我的书架").font(.system(size: 31, weight: .semibold, design: .serif)).tracking(2)
                                Text(".").font(.system(size: 35, weight: .medium, design: .serif)).foregroundStyle(Palette.accent)
                            }.foregroundStyle(Palette.green)
                            Text("生活很忙，记得给自己留一页时间。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button(action: onDiscover) {
                            Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Palette.green)
                                .frame(width: 44, height: 44).background(.white.opacity(0.7), in: Circle())
                        }.accessibilityLabel("搜索好书")
                    }

                    HStack(spacing: 17) {
                        ForEach(["shelf", "import", "fulltext"], id: \.self) { id in
                            NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id)) } label: { Label(id == "shelf" ? "书架分组" : FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon).font(.system(size: 11)).frame(minHeight: 36) }.accessibilityIdentifier("shelf-feature-\(id)")
                        }
                    }
                    if !managing {
                        if let recent = store.recent { continueCard(recent) }
                        else { welcomeCard }
                        Button { showUpdates = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "sparkles")
                                Text(store.updatedBooks.isEmpty ? "追更小报" : "\(store.updatedBooks.count) 本书有更新")
                                Text("模拟").font(.system(size: 8)).padding(.horizontal, 5).padding(.vertical, 3).background(Palette.green.opacity(0.08), in: Capsule())
                                Spacer()
                                Text("查看").font(.system(size: 10)); Image(systemName: "chevron.right").font(.system(size: 10))
                            }.font(.system(size: 12)).foregroundStyle(Palette.green).padding(15).background(Color(hex: 0xEEF0E6), in: .rect(cornerRadius: 12))
                        }.accessibilityIdentifier("shelfUpdates")
                    } else {
                        HStack {
                            Text("已选择 \(selection.count) 本").font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.green)
                            Spacer()
                            Button(selection.isSuperset(of: Set(filteredBooks.map(\.id))) ? "取消全选" : "全选") {
                                let visible = Set(filteredBooks.map(\.id))
                                if selection.isSuperset(of: visible) { selection.subtract(visible) } else { selection.formUnion(visible) }
                            }.font(.system(size: 12)).accessibilityIdentifier("selectAllBooks")
                        }
                    }
                    HStack {
                        Text(managing ? "选择要移出书架的作品" : "按\(store.sort.title)排列").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Spacer()
                        Menu {
                            Picker("书架排序", selection: $store.sort) {
                                ForEach(ShelfSort.allCases, id: \.self) { sort in Text(sort.title).tag(sort) }
                            }
                        } label: { Label("排序", systemImage: "arrow.up.arrow.down").font(.system(size: 11)).frame(minHeight: 35) }.accessibilityIdentifier("shelfSort")
                        Button(managing ? "完成" : "管理") { managing.toggle(); selection = [] }.font(.system(size: 11, weight: .medium)).frame(minWidth: 44, minHeight: 35).accessibilityIdentifier("manageShelf")
                    }

                    VStack(spacing: 20) {
                        HStack(spacing: 0) {
                            HStack(spacing: 20) {
                                filterButton("全部收藏", value: 0, count: store.favorites.count)
                                filterButton("正在阅读", value: 1, count: store.readingCount)
                                filterButton("未读", value: 2, count: store.favorites.count - store.readingCount)
                            }
                            Spacer(minLength: 8)
                            Button { withAnimation(.easeInOut(duration: 0.2)) { listLayout.toggle() } } label: {
                                Image(systemName: listLayout ? "square.grid.2x2" : "list.bullet").font(.system(size: 15)).frame(width: 37, height: 44).foregroundStyle(Palette.muted)
                            }.accessibilityLabel(listLayout ? "网格布局" : "列表布局")
                        }.overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 0.5) }

                        if filteredBooks.isEmpty {
                            ContentUnavailableView {
                                Label("这里还没有故事", systemImage: "books.vertical")
                            } description: { Text("去发现一本喜欢的书，开启下一段旅程。") } actions: {
                                Button("去发现好书", action: onDiscover).buttonStyle(.borderedProminent)
                            }.padding(.vertical, 25)
                        } else if listLayout {
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
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 21), GridItem(.flexible())], alignment: .leading, spacing: 26) {
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.background, for: .navigationBar)
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
    }

    private func filterButton(_ title: String, value: Int, count: Int) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { filter = value } } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: filter == value ? .semibold : .regular))
                Text("\(count)").font(.system(size: 9))
            }.foregroundStyle(filter == value ? Palette.green : Palette.muted)
                .frame(minHeight: 46)
                .overlay(alignment: .bottom) { if filter == value { Rectangle().fill(Palette.green).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
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

    private func bookCell(_ book: Book, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { if managing { toggleSelection(book) } else { store.read(book) } } label: { BookCover(book: book, width: width) }
                .buttonStyle(.plain).accessibilityLabel(managing ? "选择\(book.title)" : "阅读\(book.title)")
                .accessibilityIdentifier(managing ? "select-\(book.id)" : "read-\(book.id)")
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in beginManaging(book) })
                .overlay(alignment: .topLeading) {
                    if !managing && store.updateCount(book) > 0 {
                        Button { store.read(book) } label: { Text("更新 \(store.updateCount(book)) 章").font(.system(size: 9, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 7).foregroundStyle(.white).background(Palette.accent, in: .rect(cornerRadius: 5)) }.padding(7).accessibilityLabel("\(book.title)更新\(store.updateCount(book))章，继续阅读")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if managing { selectionIcon(book).padding(7) }
                    else { Menu {
                        Button("选择多本", systemImage: "checkmark.circle") { beginManaging(book) }
                        Button("开始或继续阅读", systemImage: "book") { store.read(book) }
                        Button("移出书架", systemImage: "bookmark.slash", role: .destructive) { removal = store.removeFavorites([book.id]) }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.green).frame(width: 28, height: 28).background(.regularMaterial, in: Circle()).frame(width: 44, height: 44)
                    }.accessibilityLabel("\(book.title)的更多操作") }
                }
            NavigationLink(value: book) { Text(book.title).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(Palette.green).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 13).padding(.bottom, 6) }.buttonStyle(.plain).disabled(managing).accessibilityLabel("\(book.title)详情")
            Text("\(book.author) · \(book.genre)").font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
            HStack {
                Text(store.progress[book.id] == nil ? "故事在等你翻开" : "已读 \(store.percent(book))%")
                Spacer(minLength: 2)
                if let progress = store.progress[book.id] { Text("第\(progress.chapter + 1)章") }
            }.font(.system(size: 8)).foregroundStyle(Palette.muted).padding(.top, 13)
            GeometryReader { geometry in
                Capsule().fill(Palette.line)
                Capsule().fill(Color(hex: 0x92A17B)).frame(width: geometry.size.width * Double(store.percent(book)) / 100)
            }.frame(height: 2).padding(.top, 7)
        }
    }
    private func toggleSelection(_ book: Book) {
        if selection.contains(book.id) { selection.remove(book.id) } else { selection.insert(book.id) }
    }
    private func beginManaging(_ book: Book) {
        managing = true; selection.insert(book.id)
    }
    private func selectionIcon(_ book: Book) -> some View {
        Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24)).foregroundStyle(selection.contains(book.id) ? Palette.green : Palette.muted)
            .padding(3).background(Palette.background, in: Circle()).accessibilityHidden(true)
    }

}

struct TinyDotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon.font(.system(size: 4)); configuration.title }
    }
}
