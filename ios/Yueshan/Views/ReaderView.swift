import SwiftUI
import UIKit

extension ReadingTheme {
    var background: Color { switch self { case .paper: Color(hex: 0xF4EEDF); case .light: Color(hex: 0xFCFCF8); case .dark: Color(hex: 0x222E28) } }
    var ink: Color { switch self { case .paper: Color(hex: 0x4F4B3D); case .light: Color(hex: 0x3D493D); case .dark: Color(hex: 0xBDC5B0) } }
    var secondary: Color { switch self { case .paper: Color(hex: 0xAAA18A); case .light: Color(hex: 0x9BA591); case .dark: Color(hex: 0x809078) } }
}

struct ReaderView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var shushan: ShushanAccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: Book
    private let resume: Bool
    private let startingAnchor: ReadingAnchor?
    @State private var showBookmarks = false
    @StateObject private var loading: ReadingSessionController
    @State private var loaded: ChapterDocument?
    @State private var rendered: ReaderDocument?
    @State private var chapterTask: Task<Void, Never>?
    @State private var requestedChapter: Int?
    @State private var requestedResume = false
    @State private var requestedAtEnd = false
    @State private var requestedLocation: ReadingAnchor?
    @State private var chapter: Int
    @State private var anchor = ReaderAnchor()
    @State private var restoreID = 0
    @State private var narrationRestoreID = 0
    @State private var showContents = false
    @State private var showSettings = false
    @State private var showGestureGuide = false
    @State private var demoFeature: DemoFeature?
    @State private var controlsVisible = true
    @State private var sliderValue: Double
    @State private var sliderEditing = false
    @State private var ranges: [NSRange] = []
    @State private var page = 0
    @State private var reflowing = false
    @State private var turn = 0
    @State private var message: String?
    @State private var initialized = false
    @State private var commentParagraph: Int?
    @StateObject private var comments = ReaderCommentsModel()

    init(book: Book, initialChapter: Int, resume: Bool = true, startingAnchor: ReadingAnchor? = nil, repository: (any ChapterDocumentLoading)? = nil) {
        self.book = book; self.resume = resume
        self.startingAnchor = startingAnchor
        _loading = StateObject(wrappedValue: ReadingSessionController(repository: repository ?? EmbeddedChapterRepository(book: book)))
        _chapter = State(initialValue: initialChapter)
        _sliderValue = State(initialValue: Double(initialChapter))
    }
    private var theme: ReadingTheme { store.settings.theme }
    private var palette: ReaderPalette { ReaderPalette(settings: store.settings) }
    private var readerBackground: Color { Color(palette.background) }
    private var readerInk: Color { Color(palette.ink) }
    private var readerSecondary: Color { Color(palette.secondary) }
    private var document: ReaderDocument { rendered ?? ReaderDocument(book: book, chapter: chapter, settings: store.settings, paragraphs: [], isDemo: store.isDemo) }
    private var commentContext: ShushanCommentContext? {
        guard !store.isDemo,let metadata = store.remoteMetadata(book.id),let record = store.chapterRecord(bookID:book.id,index:chapter),let context = ShushanCommentContext(book:metadata,chapter:record),context.source == "fq" else { return nil }; return context
    }
    private var commentTaskID: String { StableContentID.make(loaded?.chapterID ?? "",loaded?.version ?? "",loaded?.originVersion ?? "",String(restoreID),String(store.onlineRevision),shushan.credentialForRequests.map{ShushanCommentsClient(credential:$0).cacheScope} ?? "signed-out",String(store.settings.preferences.showCommentBubbles),String(store.settings.preferences.showGodComments)) }
    private var paragraphCounts: [Int:Int] {
        guard let loaded else { return [:] }
        return Dictionary(uniqueKeysWithValues:loaded.paragraphs.enumerated().compactMap { index,paragraph in guard let count = comments.counts[paragraph.id]?.count,count > 0 else { return nil }; return (index,count) })
    }

    private var paragraphHotComments: [Int:SourceComment] {
        guard let loaded else { return [:] }; return Dictionary(uniqueKeysWithValues:loaded.paragraphs.enumerated().compactMap{index,paragraph in comments.hotComments[paragraph.id].map{(index,$0)} })
    }

    var body: some View {
        GeometryReader { geo in
            let key = layoutKey(geo.size)
            let layout = ReaderLayout(settings: store.settings, size: geo.size)
            ZStack(alignment: .topLeading) {
                if initialized && rendered != nil && store.settings.mode == .scroll {
                    ContinuousReaderText(document: document, anchor: anchor, layoutID: key, restoreID: restoreID + narrationRestoreID, turn: turn, onAnchor: updateAnchor, onTap: handleTap, onBoundary: { goChapter(chapter + ($0 ? 1 : -1), atEnd: !$0) }, insets: layout.scrollInsets, onComment: { commentParagraph = $0 })
                        .frame(width: layout.scrollFrame.width, height: layout.scrollFrame.height)
                        .position(x: layout.scrollFrame.midX, y: layout.scrollFrame.midY)
                } else if initialized && !ranges.isEmpty {
                    if ranges.indices.contains(page) {
                        PagedReaderText(text: document.pageText(in: ranges[page]), onTap: handleTap, onSwipe: { flip(forward: $0) },
                                        mode: store.settings.mode, effect: store.settings.preferences.effect(for: store.settings.mode),
                                        pageID: chapter * 100_000 + page, layoutID: key, paperColor: palette.background,
                                        onComment: { commentParagraph = $0 }, documentFrame: layout.textFrame)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .frame(width:geo.size.width,height:geo.size.height,alignment:.topLeading)
            .overlay {
                ReaderPageFurniture(settings: store.settings, book: book, chapter: chapter, page: page, pageCount: ranges.count, overallProgress: store.percent(book))
            }
            .overlay {
                if loading.phase == .loading || !initialized && loading.phase == .idle { ProgressView("正在打开章节").accessibilityIdentifier("chapterLoading") }
                else if case let .failed(reason) = loading.phase {
                    ContentUnavailableView {
                        Label("章节暂时无法打开", systemImage: "doc.text.magnifyingglass")
                    } description: { Text(reason) }
                    actions: {
                        Button("重试") { goChapter(requestedChapter ?? chapter, resume: requestedResume, atEnd: requestedAtEnd, location: requestedLocation) }.accessibilityIdentifier("retryChapter")
                        if !store.isDemo { Button("从本章开头打开") { goChapter(requestedChapter ?? chapter,resume:false) } }
                    }
                    .background(readerBackground.opacity(0.97))
                }
            }
            .task(id: key) {
                guard initialized, let loaded else { return }
                reflowing = true
                let nextDocument = ReaderDocument(book: book, chapter: chapter, settings: store.settings, paragraphs: loaded.paragraphs.map(\.text), isDemo: store.isDemo,sourceID:store.remoteMetadata(book.id)?.source?.sourceID,commentCounts:paragraphCounts,hotComments:paragraphHotComments)
                rendered = nextDocument
                if store.settings.mode.isPaged {
                    let newRanges = ReaderPaginator.ranges(document: nextDocument, size: layout.textFrame.size)
                    let newPage = ReaderPaginator.page(containing: anchor, document: nextDocument, ranges: newRanges)
                    ranges = newRanges
                    page = min(newPage, max(0, newRanges.count - 1))
                }
                await Task.yield()
                reflowing = false
            }
        }
        // Controls never participate in text layout, so hiding them reveals the
        // full page without repagination or changing the current scroll position.
        .overlay(alignment: .top) {
            if controlsVisible { header }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let message {
                    Text(message).font(.system(size: 11)).padding(13).foregroundStyle(readerInk).background(.regularMaterial, in: Capsule()).padding(.bottom, 9)
                }
                if controlsVisible {
                    footer
                }
            }
        }
        .background(readerBackground.ignoresSafeArea())
        .foregroundStyle(readerInk)
        .preferredColorScheme((store.settings.preferences.colors?.dark ?? (theme == .dark)) ? .dark : .light)
        .task { await loadChapter(chapter, resume: resume, atEnd: false, location: startingAnchor) }
        .onChange(of: page) { _, target in
            guard !reflowing, ranges.indices.contains(target) else { return }
            updateAnchor(document.anchor(at: ranges[target].location))
            haptic()
        }
        .onChange(of: scenePhase) { _, phase in store.readingHeartbeat(foreground: phase == .active); if phase != .active { save() } }
        .onChange(of:store.followingNarrationAnchor) { _,location in
            guard let location,location.bookID == book.id,let index = store.chapterIndex(bookID:book.id,chapterID:location.chapterID) else { return }
            if index != chapter { if requestedChapter != index { goChapter(index,location:location) }; return }
            guard loaded?.version == location.contentVersion,initialized else { return }
            let target = ReaderAnchor(paragraph:location.paragraphIndex,offset:location.utf16Offset)
            if store.settings.mode.isPaged { page = ReaderPaginator.page(containing:target,document:document,ranges:ranges) }
            else if target.paragraph != anchor.paragraph || abs(target.offset - anchor.offset) > 120 { anchor = target; narrationRestoreID += 1; save() }
        }
        .onDisappear { store.trackReading(nil); save(); chapterTask?.cancel(); loading.cancel(); Task { await store.flushPendingWrites() } }
        .onReceive(NotificationCenter.default.publisher(for:.contentProcessingChanged)) { _ in
            guard !store.isDemo,let loaded else { return }
            let location = try? ReadingAnchor(bookID:book.id,document:loaded,paragraph:anchor.paragraph,offset:anchor.offset)
            goChapter(chapter,location:location)
        }
        .onReceive(NotificationCenter.default.publisher(for:.contentProcessingFailed)) { event in
            if event.userInfo?["bookID"] as? String == book.id { showMessage("净化处理未完成，已保留有效正文。") }
        }
        .onChange(of: showSettings || showContents || showGestureGuide || showBookmarks || demoFeature != nil) { _, covered in
            store.trackReading(covered ? nil : (initialized ? book.id : nil),interacted:!covered)
        }
        .sheet(isPresented: $showContents) {
            ContentsView(book: book, currentChapter: chapter) { target in goChapter(target); showContents = false }
        }
        .sheet(isPresented: $showSettings, onDismiss: { restoreID += 1 }) { ReadingSettingsView() }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack {
                ProductionBookmarksView(bookID: book.id) { mark in
                    guard let index = store.chapterIndex(bookID: book.id, chapterID: mark.anchor.chapterID) else { return }
                    showBookmarks = false; goChapter(index, location: mark.anchor)
                }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showBookmarks = false } } }
            }
        }
        .sheet(item: $demoFeature) { feature in
            NavigationStack {
                FeatureDemoView(feature: feature, bookID: book.id) { item, chapter, paragraph, offset in
                    if item.id == book.id {
                        Task {
                            do {
                                let request = try store.chapterRequest(for:book,chapter:chapter)
                                guard let content = try await store.chapterRepository(for:book).document(chapterID:request.chapter.id) else { throw ContentFailure.missingChapter }
                                let target = try ReadingAnchor(bookID:book.id,document:content,paragraph:paragraph,offset:offset)
                                demoFeature = nil; goChapter(chapter,location:target)
                            } catch { message = error.localizedDescription }
                        }
                    } else {
                        demoFeature = nil
                        store.record(item, chapter: chapter, paragraph: paragraph, characterOffset: offset)
                        store.read(item, chapter: chapter)
                    }
                }.toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { demoFeature = nil } } }
            }
        }
        .task(id:commentTaskID) {
            comments.reset()
            if store.settings.preferences.showCommentBubbles || store.settings.preferences.showGodComments,let credential = shushan.credentialForRequests,let client = store.commentClient(credential:credential),let context = commentContext,let loaded {
                let processed = await store.contentProcessor.context(bookID:book.id,document:loaded)
                if loaded.originVersion != nil && processed == nil { return }
                await comments.load(client:client,context:context,document:processed?.raw ?? loaded,includeHot:store.settings.preferences.showGodComments)
                if !Task.isCancelled,let processed { comments.remap(processed.origins) }
            }
        }
        .sheet(isPresented: Binding(get: { commentParagraph != nil }, set: { if !$0 { commentParagraph = nil } })) {
            NavigationStack {
                if !store.isDemo,let credential = shushan.credentialForRequests,let client = store.commentClient(credential:credential),let context = commentContext,let loaded,let paragraph = loaded.paragraphs[safe:commentParagraph ?? -1],let count = comments.counts[paragraph.id] {
                    ProductionCommentsView(client:client,context:context,paragraph:count,documentVersion:loaded.originVersion ?? loaded.version,originalText:comments.originalTexts[paragraph.id] ?? paragraph.text)
                        .id(commentTaskID + paragraph.id)
                        .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("完成") { commentParagraph = nil } } }
                } else if store.isDemo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("本地示例评论").font(.system(size: 23, weight: .medium, design: .serif))
                        Text("第 \((commentParagraph ?? 0) + 1) 段 · 本次只展示本地示例，不连接评论服务。")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Text(loaded?.paragraphs[safe: commentParagraph ?? 0]?.text ?? "")
                            .font(.system(size: 14)).lineSpacing(7)
                        AppSettingsCard("神人评论 · 示例", icon: "bubble.left") {
                            Text("这盏茶，怕不是等了整整一章。").font(.system(size: 14))
                        }
                    }.padding(22)
                }.appPageStyle().navigationTitle("本段评论")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { commentParagraph = nil } } }
                } else { ContentUnavailableView("段评暂不可用",systemImage:"bubble.left",description:Text("请确认书源登录与当前段落数据。")) }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showGestureGuide, onDismiss: { store.completeReadingGuide() }) {
            ReadingGestureGuideView(isFirstUse: true)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { save(); dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 17, weight: .medium)).frame(width: 44, height: 44) }.accessibilityLabel("返回书架")
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                Text(book.title).font(.system(size: 13, weight: .medium, design: .serif)).tracking(2)
                Text(book.chapterTitle(chapter)).font(.system(size: 9)).foregroundStyle(readerSecondary).accessibilityIdentifier("chapterTitle")
            }
            Spacer(minLength: 0)
            Menu {
                Section {
                    Button {
                        let added = store.toggleFavorite(book)
                        haptic()
                        showMessage(added ? "已加入书架" : "已移出书架，阅读进度已保留")
                    } label: {
                        Label(store.isFavorite(book) ? "取消收藏" : "加入书架", systemImage: store.isFavorite(book) ? "bookmark.slash" : "bookmark")
                    }.accessibilityIdentifier("readerFavoriteAction")
                }
                Section {
                    ForEach(["fulltext", "sourceSwitch", "bookmarks", "chapterCache", "purify", "highlight"], id: \.self) { id in
                        Button(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon) { openFeature(id) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
            }.accessibilityLabel("更多阅读工具").accessibilityIdentifier("readerMoreTools")
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .frame(maxWidth: 520)
        .readerFloatingSurface()
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerTopToolbar")
        .padding(.horizontal, 18).padding(.top, 8)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Button { flip(forward: false) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(chapter == 0 && (store.settings.mode == .scroll || page == 0)).accessibilityLabel(store.settings.mode.isPaged ? "上一页" : "上一章").accessibilityIdentifier("previousChapter")
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text(sliderEditing ? "跳至 · \(book.chapterTitle(Int(sliderValue)))" : "第 \(chapter + 1) / \(book.chapters.count) 章").font(.system(size: 10)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(store.settings.mode.isPaged ? "本章 \(page + 1) / \(max(1, ranges.count)) 页" : "已读 \(store.percent(book))%").font(.system(size: 9)).foregroundStyle(readerSecondary).accessibilityIdentifier("readerPageStatus")
                    }
                    Slider(value: $sliderValue, in: 0...Double(max(1, book.chapters.count - 1)), step: 1) { editing in
                        sliderEditing = editing
                        if !editing { goChapter(min(book.chapters.count - 1, Int(sliderValue))) }
                    }.tint(readerInk.opacity(0.65)).accessibilityLabel("章节进度").accessibilityValue(book.chapterTitle(Int(sliderValue))).accessibilityIdentifier("chapterSlider")
                }
                Button { flip(forward: true) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(chapter == book.chapters.count - 1 && (store.settings.mode == .scroll || page == ranges.count - 1)).accessibilityLabel(store.settings.mode.isPaged ? "下一页" : "下一章").accessibilityIdentifier("nextChapter")
            }
            .padding(.horizontal, 5).padding(.vertical, 8)
            .readerFloatingSurface()
            HStack {
                tool("目录", icon: "list.bullet") { save(); showContents = true }.accessibilityIdentifier("readerContents")
                Spacer()
                tool("设置", icon: "textformat.size") { save(); showSettings = true }.accessibilityIdentifier("readerSettings")
                Spacer()
                featureMenu("朗读", icon: "headphones", features: ["systemTTS", "onlineTTS", "aiRoles"])
                    .accessibilityIdentifier("readerNarration")
                Spacer()
                featureMenu("皮肤", icon: "tshirt", features: ["themes", "comments"])
                    .accessibilityIdentifier("readerSkins")
            }
            .padding(.horizontal, 18).frame(height: 64)
            .readerFloatingSurface()
            .accessibilityElement(children: .contain).accessibilityIdentifier("readerFloatingToolbar")
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 18).padding(.bottom, 8)
    }

    private func tool(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, icon: icon) }
    }
    private func featureMenu(_ title: String, icon: String, features: [String]) -> some View {
        Menu {
            ForEach(features, id: \.self) { id in
                Button(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon) { openFeature(id) }
            }
        } label: { toolLabel(title, icon: icon) }.accessibilityLabel(title)
    }
    private func toolLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium)).frame(height: 24)
            Text(title).font(.system(size: 10))
        }.frame(width: 55, height: 48).foregroundStyle(readerInk.opacity(0.9))
    }
    private func openFeature(_ id: String) {
        save()
        if !store.isDemo && id == "bookmarks" { showBookmarks = true }
        else { demoFeature = FeatureCatalog.feature(id) }
    }
    private func layoutKey(_ size: CGSize) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let preferences = (try? encoder.encode(store.settings.preferences)).map { String($0.hashValue) } ?? ""
        let countsVersion = StableContentID.list(paragraphCounts.keys.sorted().map{"\($0):\(paragraphCounts[$0]!)"} + paragraphHotComments.keys.sorted().map{"\($0):\(paragraphHotComments[$0]!.id):\(paragraphHotComments[$0]!.text)"})
        return "\(chapter)-\(Int(size.width))-\(Int(size.height))-\(store.settings.fontSize)-\(store.settings.lineSpacing)-\(theme.rawValue)-\(store.settings.mode.rawValue)-\(preferences)-\(restoreID)-\(initialized)-\(loaded?.version ?? "")-\(countsVersion)"
    }
    private func updateAnchor(_ value: ReaderAnchor) {
        guard initialized, !reflowing, loading.phase == .readable else { return }
        if value != anchor { store.trackReading(book.id, interacted: true) }
        anchor = value; save()
    }
    private func save() {
        guard initialized, loading.phase == .readable else { return }
        store.record(book, chapter: chapter, paragraph: anchor.paragraph, characterOffset: anchor.offset)
    }
    private func goChapter(_ target: Int, resume: Bool = false, atEnd: Bool = false, location: ReadingAnchor? = nil) {
        guard book.chapters.indices.contains(target) else { showMessage(target < 0 ? "已经是第一章" : (store.isDemo ? "已读完全部示例章节" : "已经是最后一章")); return }
        chapterTask?.cancel()
        chapterTask = Task { await loadChapter(target, resume: resume, atEnd: atEnd, location: location) }
    }
    private func loadChapter(_ target: Int, resume: Bool, atEnd: Bool, location: ReadingAnchor? = nil) async {
        store.trackReading(nil)
        requestedChapter = target; requestedResume = resume; requestedAtEnd = atEnd
        requestedLocation = location
        guard var request = try? store.chapterRequest(for: book, chapter: target, resume: resume, atEnd: atEnd) else { return }
        if let location { request.anchor = location }
        guard await loading.load(request), let content = loading.document, let location = loading.confirmed else { return }
        reflowing = true
        loaded = content; chapter = target
        anchor = .init(paragraph: location.paragraphIndex, offset: location.utf16Offset)
        sliderValue = Double(target); ranges = []; page = 0
        initialized = true; restoreID += 1; requestedChapter = nil
        _ = store.confirmChapter(book, chapter: target, document: content, anchor: anchor)
        store.trackReading(book.id, interacted: true)
        showGestureGuide = !store.hasSeenReadingGuide
        haptic()
    }
    private func flip(forward: Bool) {
        if store.settings.mode == .scroll { goChapter((requestedChapter ?? chapter) + (forward ? 1 : -1)); return }
        let target = page + (forward ? 1 : -1)
        if ranges.indices.contains(target) {
            page = target
        } else { goChapter(chapter + (forward ? 1 : -1), atEnd: !forward) }
    }
    private func handleTap(_ fraction: Double) {
        if initialized && loading.phase == .readable { store.trackReading(book.id,interacted:true) }
        switch ReaderInteraction.action(at: fraction, settings: store.settings) {
        case .controls: controlsVisible.toggle(); haptic()
        case .next, .previous:
            let forward = ReaderInteraction.action(at: fraction, settings: store.settings) == .next
            if store.settings.mode.isPaged { flip(forward: forward) }
            else { turn += forward ? 1 : -1; haptic() }
        }
    }
    private func haptic() { if store.settings.haptics { UISelectionFeedbackGenerator().selectionChanged() } }
    private func showMessage(_ value: String) {
        message = value
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); if message == value { message = nil } }
    }
}

private extension View {
    @ViewBuilder func readerFloatingSurface() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
        }
    }
}

struct ContentsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let currentChapter: Int?
    let onSelect: (Int) -> Void
    @State private var query = ""
    @State private var reversed = false
    private var visibleChapters: [Int] {
        (reversed ? Array(book.chapters.indices.reversed()) : Array(book.chapters.indices))
            .filter { query.isEmpty || book.chapterTitle($0).contains(query) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        AppPageHeader(title: book.title, subtitle: "共 \(book.chapters.count) 章 · 选择章节继续故事。", icon: "list.bullet")
                        if visibleChapters.isEmpty { ContentUnavailableView.search(text: query) }
                        LazyVStack(spacing: 0) {
                            ForEach(visibleChapters, id: \.self) { index in
                                Button { onSelect(index) } label: {
                                    HStack(spacing: 12) {
                                        Text(book.chapterTitle(index)).font(.system(size: 14))
                                        Spacer()
                                        if library.chapterAccess(book, chapter: index) != .readable {
                                            Text(library.chapterAccess(book, chapter: index) == .volume ? "分卷" : "受限").font(.system(size: 10))
                                        }
                                        if index == currentChapter { Text("正在阅读").font(.system(size: 10)); Image(systemName: "waveform").font(.system(size: 12)) }
                                        else { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                                    }.foregroundStyle(Palette.green).padding(.horizontal, 16).frame(minHeight: 56)
                                        .background(index == currentChapter ? Palette.soft : Color.clear)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(library.chapterAccess(book, chapter: index) != .readable).id(index).accessibilityIdentifier("chapter-\(index)")
                                if index != visibleChapters.last { Divider().overlay(Palette.line).padding(.horizontal, 16) }
                            }
                        }
                        .background(Palette.card, in: .rect(cornerRadius: 18)).clipShape(.rect(cornerRadius: 18))
                    }.padding(22)
                }
                .appPageStyle()
                .onAppear { if let currentChapter { proxy.scrollTo(currentChapter, anchor: .center) } }
            }
            .navigationTitle("章节目录").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索章节")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down") { reversed.toggle() } } }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.appPageStyle().presentationBackground(Palette.background).presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(26)
    }
}
