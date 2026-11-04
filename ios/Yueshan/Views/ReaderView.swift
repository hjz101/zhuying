import SwiftUI

extension ReadingTheme {
    var background: Color { switch self { case .paper: Color(hex: 0xF4EEDF); case .light: Color(hex: 0xFCFCF8); case .dark: Color(hex: 0x222E28) } }
    var ink: Color { switch self { case .paper: Color(hex: 0x4F4B3D); case .light: Color(hex: 0x3D493D); case .dark: Color(hex: 0xBDC5B0) } }
    var secondary: Color { switch self { case .paper: Color(hex: 0xAAA18A); case .light: Color(hex: 0x9BA591); case .dark: Color(hex: 0x809078) } }
}

struct ReaderView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let book: Book
    @State private var chapter: Int
    @State private var position: String?
    @State private var showContents = false
    @State private var showSettings = false
    @State private var controlsVisible = true
    @State private var isRestoring = true

    init(book: Book, initialChapter: Int) {
        self.book = book
        _chapter = State(initialValue: initialChapter)
    }

    private var theme: ReadingTheme { store.settings.theme }
    var body: some View {
        VStack(spacing: 0) {
            if controlsVisible {
                HStack(spacing: 13) {
                    Button { save(); dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44) }.accessibilityLabel("返回书架")
                    Spacer(minLength: 0)
                    VStack(spacing: 4) {
                        Text(book.title).font(.system(size: 13, weight: .medium, design: .serif)).tracking(2)
                        Text("\(book.author) 著").font(.system(size: 9)).foregroundStyle(theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { store.toggleFavorite(book) } label: { Image(systemName: store.isFavorite(book) ? "bookmark.fill" : "bookmark").font(.system(size: 16)).frame(width: 44, height: 44) }.accessibilityLabel(store.isFavorite(book) ? "已收藏" : "加入书架")
                }.padding(.horizontal, 9).foregroundStyle(theme.ink).padding(.bottom, 8)
                Rectangle().fill(theme.secondary.opacity(0.2)).frame(height: 0.5)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("\(book.genre)  /  \(String(format: "%02d", chapter + 1)) OF \(String(format: "%02d", book.chapters.count))").font(.system(size: 9)).tracking(1.5).foregroundStyle(theme.secondary)
                            Text(book.chapterTitle(chapter)).font(.system(size: 27, weight: .medium, design: .serif)).tracking(1.5).lineSpacing(6).accessibilityIdentifier("chapterTitle")
                            HStack(spacing: 15) { Text("\(book.author) 著"); Text("原创示例章节") }.font(.system(size: 9)).foregroundStyle(theme.secondary)
                        }.padding(.top, 29).padding(.bottom, 35).id("heading")

                        ForEach(Array(book.content[chapter].enumerated()), id: \.offset) { index, text in
                            Text("　　" + text)
                                .font(.system(size: store.settings.fontSize, design: .serif))
                                .lineSpacing(store.settings.lineSpacing)
                                .tracking(0.6)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, 22)
                                .id("\(chapter):\(index)")
                                .accessibilityIdentifier("paragraph-\(index)")
                                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() } }
                        }

                        VStack(spacing: 23) {
                            HStack(spacing: 17) { Rectangle().frame(width: 35, height: 0.5); Image(systemName: "leaf"); Rectangle().frame(width: 35, height: 0.5) }.foregroundStyle(theme.secondary).font(.system(size: 14)).frame(maxWidth: .infinity).padding(.top, 25)
                            Text(chapter == book.chapters.count - 1 ? "你已读完全部示例章节，感谢同行。" : "故事还在继续，不妨再读一章。").font(.system(size: 11)).foregroundStyle(theme.secondary).frame(maxWidth: .infinity)
                            HStack(spacing: 15) {
                                Button { changeChapter(chapter - 1, proxy: proxy) } label: { Label("上一章", systemImage: "chevron.left") }.disabled(chapter == 0).accessibilityIdentifier("previousChapter")
                                Button { changeChapter(chapter + 1, proxy: proxy) } label: { HStack { Text(chapter == book.chapters.count - 1 ? "已是最后一章" : "下一章"); Image(systemName: "chevron.right") } }.disabled(chapter == book.chapters.count - 1).accessibilityIdentifier("nextChapter")
                            }.buttonStyle(ReaderChapterButtonStyle(theme: theme))
                            Text("阅山 · 在字里行间，遇见山海").font(.system(size: 9)).tracking(2).foregroundStyle(theme.secondary).frame(maxWidth: .infinity).padding(.top, 8)
                        }.padding(.bottom, 40)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 25)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: $position, anchor: .top)
                .task {
                    let paragraph = store.progress[book.id]?.chapter == chapter ? store.progress[book.id]?.paragraph ?? 0 : 0
                    try? await Task.sleep(for: .milliseconds(150))
                    if paragraph > 0 { proxy.scrollTo("\(chapter):\(paragraph)", anchor: .top) }
                    isRestoring = false
                }
                .onChange(of: chapter) { _, _ in
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        proxy.scrollTo("heading", anchor: .top)
                    }
                }
            }
            if controlsVisible {
                VStack(spacing: 13) {
                    HStack {
                        Text("第 \(chapter + 1) / \(book.chapters.count) 章")
                        Spacer()
                        Text("已读 \(store.percent(book))% · 自动保存进度")
                    }.font(.system(size: 8)).foregroundStyle(theme.secondary).padding(.horizontal, 25)
                    HStack {
                        tool("目录", icon: "list.bullet") { save(); showContents = true }.accessibilityIdentifier("readerContents")
                        Spacer()
                        tool("设置", icon: "textformat.size") { save(); showSettings = true }.accessibilityIdentifier("readerSettings")
                        Spacer()
                        tool(store.isFavorite(book) ? "已收藏" : "收藏", icon: store.isFavorite(book) ? "bookmark.fill" : "bookmark") { store.toggleFavorite(book) }
                    }.padding(.horizontal, 32)
                }.padding(.top, 14).padding(.bottom, 5).background(theme.background)
                    .overlay(alignment: .top) { Rectangle().fill(theme.secondary.opacity(0.2)).frame(height: 0.5) }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .foregroundStyle(theme.ink)
        .preferredColorScheme(theme == .dark ? .dark : .light)
        .statusBarHidden(!controlsVisible)
        .onChange(of: position) { _, _ in if !isRestoring { save() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { save() } }
        .onDisappear { save() }
        .sheet(isPresented: $showContents) {
            ContentsView(book: book, currentChapter: chapter) { target in
                isRestoring = true
                chapter = target
                position = nil
                store.record(book, chapter: target)
                showContents = false
                Task { @MainActor in try? await Task.sleep(for: .milliseconds(250)); isRestoring = false }
            }
        }
        .sheet(isPresented: $showSettings) { ReadingSettingsView() }
    }

    private func tool(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) { Image(systemName: icon).font(.system(size: 18)); Text(title).font(.system(size: 10)) }.frame(width: 55, height: 48)
        }.foregroundStyle(theme.ink.opacity(0.8))
    }

    private func changeChapter(_ target: Int, proxy: ScrollViewProxy) {
        guard book.chapters.indices.contains(target) else { return }
        isRestoring = true
        chapter = target
        position = nil
        store.record(book, chapter: target)
        proxy.scrollTo("heading", anchor: .top)
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); isRestoring = false }
    }

    private func save() {
        guard !isRestoring else { return }
        let parts = position?.split(separator: ":") ?? []
        let paragraph = parts.count == 2 && Int(parts[0]) == chapter ? Int(parts[1]) ?? 0 : store.progress[book.id]?.paragraph ?? 0
        store.record(book, chapter: chapter, paragraph: paragraph)
    }
}

struct ReaderChapterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    let theme: ReadingTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(theme.ink).background(theme.secondary.opacity(0.1), in: .rect(cornerRadius: 10))
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
    }
}

struct ContentsView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let currentChapter: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section {
                        ForEach(book.chapters.indices, id: \.self) { index in
                            Button { onSelect(index) } label: {
                                HStack {
                                    Text(book.chapterTitle(index)).font(.system(size: 14))
                                    Spacer()
                                    if index == currentChapter { Text("正在阅读").font(.system(size: 10)); Image(systemName: "waveform").font(.system(size: 12)) }
                                }.foregroundStyle(index == currentChapter ? Palette.green : Palette.green.opacity(0.7)).padding(.vertical, 8)
                            }.listRowBackground(index == currentChapter ? Color(hex: 0xE7EEDC) : Palette.background).id(index).accessibilityIdentifier("chapter-\(index)")
                        }
                    } header: { Text("\(book.title) · 共 \(book.chapters.count) 章示例").font(.system(size: 11)) }
                }
                .scrollContentBackground(.hidden).background(Palette.background)
                .onAppear { if let currentChapter { proxy.scrollTo(currentChapter, anchor: .center) } }
            }
            .navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.tint(Palette.green).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
