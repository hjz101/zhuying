import SwiftUI

struct BookDetailView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    var onlineRecord: LibraryBookRecord? = nil
    @State private var loadedBook: Book?
    @State private var loading = false
    @State private var failure: String?
    private var currentBook: Book { loadedBook ?? store.books.first { $0.id == book.id } ?? book }
    @State private var showContents = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 15) {
                    BookCover(book: currentBook, width: 127).padding(.top, 23).padding(.bottom, 9)
                    Text(currentBook.title).font(.system(size: 29, weight: .semibold, design: .serif)).tracking(3).foregroundStyle(appAppearance.palette.green)
                    Text("\(currentBook.author) 著").font(.system(size: 12)).foregroundStyle(appAppearance.palette.muted)
                    Text(currentBook.subtitle).font(.system(size: 12, design: .serif)).foregroundStyle(appAppearance.palette.green.opacity(0.6)).padding(.top, 4)
                    HStack(spacing: 7) {
                        ForEach(currentBook.tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted).padding(.horizontal, 9).padding(.vertical, 6).background(appAppearance.palette.legacyCard(opacity: 0.45), in: .rect(cornerRadius: 5))
                        }
                    }
                    HStack(spacing: 0) {
                        stat(currentBook.words, label: "字数展示")
                        Rectangle().fill(appAppearance.palette.line).frame(width: 1, height: 25)
                        stat(currentBook.status, label: currentBook.genre)
                        Rectangle().fill(appAppearance.palette.line).frame(width: 1, height: 25)
                        stat("\(currentBook.chapters.count) 章", label: store.isDemo ? "示例章节" : "章节目录")
                    }.padding(.top, 6).padding(.bottom, 24)
                }.frame(maxWidth: .infinity).background(LinearGradient(colors: [appAppearance.palette.surface(0xE9EDDF), appAppearance.palette.background], startPoint: .top, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 20) {
                    if loading { ProgressView("正在读取详情与目录") }
                    if let failure {
                        Text(failure).font(.system(size: 12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("onlineDetailError")
                        Button("重试") { Task { await loadOnline() } }.accessibilityIdentifier("retryOnlineDetail")
                    }
                    SectionHeading(title: "故事简介")
                    Text(currentBook.intro).font(.system(size: 14)).lineSpacing(9).foregroundStyle(appAppearance.palette.legacyColor(0x7A856F, role: "text.secondary"))
                    Text(store.isDemo ? "原创示例小说 · 用于预览阅读体验" : (onlineRecord != nil || store.remoteMetadata(book.id) != nil ? "正文与可读状态由所选书源提供" : "本地导入正文")).font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted).padding(.bottom, 5)
                    HStack {
                        ForEach(["sourceSwitch", "chapterCache", "covers"], id: \.self) { id in
                            NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id), bookID: currentBook.id) } label: { ThemeLabel(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon).font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 40) }
                        }
                    }
                    Divider().overlay(appAppearance.palette.line)
                    Button { showContents = true } label: {
                        HStack {
                            ThemeLabel("章节目录", systemImage: "list.bullet").font(.system(size: 16, weight: .medium, design: .serif))
                            Spacer()
                            Text("共 \(currentBook.chapters.count) 章").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                            ThemeIcon(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(appAppearance.palette.muted)
                        }.foregroundStyle(appAppearance.palette.green).frame(minHeight: 42)
                    }.accessibilityIdentifier("detailContents")
                    if let progress = store.progress[currentBook.id] {
                        ThemeLabel("上次读到 · \(currentBook.chapterTitle(progress.chapter))", systemImage: "clock").font(.system(size: 10)).foregroundStyle(appAppearance.palette.muted)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 30)
            }
        }
        .appPageStyle()
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await loadOnline() } } label: { ThemeIcon(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                .accessibilityLabel("刷新作品详情").accessibilityIdentifier("refreshBookDetail")
                .disabled(loading || (store.isDemo || (onlineRecord == nil && store.remoteMetadata(book.id) == nil)))
        } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.toggleFavorite(currentBook) } label: {
                    ThemeLabel(store.isFavorite(currentBook) ? "已在书架" : "加入书架", systemImage: store.isFavorite(currentBook) ? "checkmark" : "plus")
                }.buttonStyle(PrimaryButtonStyle(filled: false)).frame(maxWidth: 132)
                Button { store.read(currentBook) } label: {
                    HStack { Text(store.progress[currentBook.id] == nil ? "开始阅读" : "继续阅读"); ThemeIcon(systemName: "arrow.right") }
                }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("detailRead")
            }.disabled(loading || currentBook.chapters.isEmpty).padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial)
        }
        .task { await loadOnline() }
        .sheet(isPresented: $showContents) {
            ContentsView(book: currentBook, currentChapter: store.progress[currentBook.id]?.chapter) { chapter in
                showContents = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    store.read(currentBook, chapter: chapter)
                }
            }
        }
    }

    @MainActor private func loadOnline() async {
        guard !store.isDemo, let record = onlineRecord ?? store.remoteMetadata(book.id), let service = store.onlineService else { return }
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let (record, catalog) = try await service.details(record)
            try Task.checkCancellation()
            loadedBook = try await store.registerRemoteBook(record, chapters: catalog)
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(spacing: 7) {
            Text(value).font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(appAppearance.palette.green)
            Text(label).font(.system(size: 9)).foregroundStyle(appAppearance.palette.muted)
        }.frame(maxWidth: .infinity)
    }
}
