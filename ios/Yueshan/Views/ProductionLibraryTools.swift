import SwiftUI

struct ProductionBookmarksView: View {
    var bookID: String? = nil
    var onOpen: ((LibraryBookmarkRecord) -> Void)? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var message: String?
    private var selectedBook: Book? { library.books.first { $0.id == bookID } ?? library.history.first }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书签", subtitle: "位置列表 · 跳转书签 · 删除书签", icon: "bookmark")
                VStack(spacing: 13) {
                    let marks = library.bookmarks.filter { bookID == nil || $0.anchor.bookID == bookID }
                    ForEach(marks) { mark in
                        HStack {
                            Button {
                                if library.chapterIndex(bookID: mark.anchor.bookID, chapterID: mark.anchor.chapterID) == nil { message = "原章节已不可用，书签保留。" }
                                else if let onOpen { onOpen(mark) } else { library.openBookmark(mark) }
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(library.books.first { $0.id == mark.anchor.bookID }?.title ?? mark.title).font(.system(size: 15, design: .serif))
                                    Text(mark.title).font(.system(size: 11))
                                    Text(mark.anchor.quote).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("bookmark-open-\(mark.id)")
                            Button { Task { do { try await library.removeBookmark(id: mark.id) } catch { message = error.localizedDescription } } } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .accessibilityLabel("删除书签").accessibilityIdentifier("bookmark-delete-\(mark.id)")
                        }.padding(14).background(.white.opacity(0.7), in: .rect(cornerRadius: 12))
                    }
                    if marks.isEmpty { Text("暂无书签，可添加当前位置。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("bookmarkMessage") }
                Button("添加当前进度书签") {
                    Task {
                        guard let book = selectedBook, let value = library.progress[book.id] else { message = "请先打开一章正文。"; return }
                        do {
                            try await library.saveCurrentBookmark(book, progress: value)
                            message = "已保存当前位置。"
                        } catch { message = error.localizedDescription }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(selectedBook == nil).accessibilityIdentifier("bookmarkAdd")
            }.padding(22)
        }.appPageStyle().navigationTitle("书签").navigationBarTitleDisplayMode(.inline)
    }
}

struct ProductionGroupsView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedGroup = "全部"
    @State private var newGroup = ""
    @State private var selection = Set<String>()
    @State private var removal: ShelfRemoval?
    @State private var renaming = false
    @State private var renamedGroup = ""
    @State private var message: String?
    private var groups: [String] { Array(Set(library.groupNames + Array(library.importedGroups.values) + ["未分组"])).sorted() }
    private var books: [Book] { library.shelf.filter { selectedGroup == "全部" || (library.importedGroups[$0.id] ?? "未分组") == selectedGroup } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: "书架管理", subtitle: "添加移除 · 分组 · 最近阅读 · 继续阅读", icon: "books.vertical")
                AppSettingsCard("配置与选项", icon: "slider.horizontal.3") {
                    Picker("当前分组", selection: $selectedGroup) { ForEach(["全部"] + groups, id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("shelfGroupPicker")
                    TextField("新分组名称", text: $newGroup).accessibilityIdentifier("shelfNewGroup")
                    if selectedGroup != "全部" && selectedGroup != "未分组" {
                        Button("重命名分组") { renamedGroup = selectedGroup; renaming = true }
                        Button("删除分组，保留作品") { library.removeGroup(selectedGroup); selectedGroup = "全部" }
                    }
                }
                ForEach(books) { book in
                    Button { if selection.contains(book.id) { selection.remove(book.id) } else { selection.insert(book.id) } } label: {
                        HStack {
                            Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            BookRow(book: book)
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("group-select-\(book.id)")
                }
                if books.isEmpty { Text("此分组还没有作品。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                if let removal {
                    HStack { Text("已移出 \(removal.count) 本，历史保留。"); Spacer(); Button("撤销") { library.undoRemoval(removal); self.removal = nil } }.font(.system(size: 12))
                }
                if let message { Text(message).font(.system(size: 12)).accessibilityIdentifier("groupMessage") }
                Button("新建分组") { Task {
                    guard library.createGroup(newGroup) else { message = "分组名称须为 1～100 字，不能使用保留名称或重复名称。"; return }
                    if await library.flushPendingWrites() { newGroup = ""; message = "分组已保存。" }
                    else { message = "保存失败，请重试。" }
                } }.buttonStyle(PrimaryButtonStyle()).disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("createShelfGroup")
            }.padding(22)
        }.appPageStyle().navigationTitle("书架管理").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("已选 \(selection.count)").font(.system(size: 12))
                    Menu("移入分组") { ForEach(groups, id: \.self) { group in Button(group) { library.moveBooks(selection, toGroup: group); selection.removeAll() } } }.disabled(selection.isEmpty)
                    Spacer()
                    Button("移出书架") { removal = library.removeFavorites(selection); selection.removeAll() }.disabled(selection.isEmpty)
                }.padding(18).background(.regularMaterial)
            }
            .onChange(of: selectedGroup) { _, _ in selection.removeAll() }
            .alert("重命名分组", isPresented: $renaming) {
                TextField("分组名称", text: $renamedGroup)
                Button("保存") {
                    if library.renameGroup(selectedGroup, to: renamedGroup) { selectedGroup = "全部" }
                    else { message = "分组名称须为 1～100 字，不能使用保留名称或重复名称。" }
                }
                Button("取消", role: .cancel) {}
            }
    }
}
