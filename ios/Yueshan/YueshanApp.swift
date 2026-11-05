import SwiftUI

@main
struct YueshanApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var featureDemo: FeatureDemoStore
    @StateObject private var navigation: NavigationStore
    @StateObject private var toolbox: ToolboxStore
    @StateObject private var shushan: ShushanAccountStore
    private let launchError: String?

    init() {
        let environment = AppEnvironment()
        let defaults = environment.defaults()
        let credentialService = environment.isUITesting ? "com.yueshan.shushan.ui-tests" : "com.yueshan.shushan.\(environment.mode.rawValue)"
        _shushan = StateObject(wrappedValue: ShushanAccountStore(defaults: defaults, vault: ShushanKeychain(service: credentialService)))
        _featureDemo = StateObject(wrappedValue: FeatureDemoStore(defaults: defaults, seedDemoData: environment.isDemo))
        ReadingFontLibrary.shared.reload(reset: environment.resetsTestState)
        _navigation = StateObject(wrappedValue: NavigationStore(defaults: defaults))
        _toolbox = StateObject(wrappedValue: ToolboxStore(defaults: defaults))
        do {
            let books = environment.isDemo ? try Book.load() : []
            let manager = FileManager.default
            let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
            let archive = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(environment.importsComponent).appendingPathComponent("books.json")
            let databaseDirectory = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(environment.databaseComponent)
            if environment.resetsTestState { try? manager.removeItem(at: archive) }
            if environment.resetsTestState { try? manager.removeItem(at: databaseDirectory) }
            if testing && ProcessInfo.processInfo.arguments.contains("--import-fixtures") {
                let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try manager.createDirectory(at: documents, withIntermediateDirectories: true)
                let text = "第一章 来信\n这是从系统文件选择器导入的真实正文。\n第二章 回声\n山谷里的回声来自远方。" + (environment.isDemo ? "" : "\n第三章 远山\n远山之下的真实正文，来自同一个本地文件。")
                try Data(text.utf8)
                    .write(to: documents.appendingPathComponent("导入测试.txt"))
                try Data("unsupported".utf8).write(to: documents.appendingPathComponent("不支持的格式.epub"))
            }
            if testing && !environment.isDemo && environment.resetsTestState && ProcessInfo.processInfo.arguments.contains("--legacy-library-fixtures") {
                let book = try BookImporter.prepare(data: Data("第一章 旧信\n保留的第一章正文。\n第二章 重逢\n升级前已经读到的真实段落。".utf8), name: "迁移测试.txt").book
                try manager.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode([book]).write(to: archive, options: .atomic)
                let snapshot = LibrarySnapshot(favorites: [book.id], progress: [book.id: .init(chapter: 1, paragraph: 0, updatedAt: Date(), characterOffset: 3)],
                                               settings: .init(fontSize: 24, lineSpacing: 16, theme: .dark), sort: .title, hasSeenReadingGuide: true, shelfLayout: "list", importedGroups: [book.id: "升级前分组"])
                defaults.set(try JSONEncoder().encode(snapshot), forKey: LibraryStore.storageKey)
            }
            if testing && !environment.isDemo && ProcessInfo.processInfo.arguments.contains("--corrupt-migrated-legacy-fixtures") {
                try Data("corrupt old archive".utf8).write(to: archive, options: .atomic)
                defaults.set(Data("corrupt old snapshot".utf8), forKey: LibraryStore.storageKey)
            }
            if testing && ProcessInfo.processInfo.arguments.contains("--theme-fixtures") {
                let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try manager.createDirectory(at: documents, withIntermediateDirectories: true)
                try ThemeStyleSamples.importData.write(to: documents.appendingPathComponent("阅读套装.json"))
            }
            let backend = environment.isDemo ? nil : try ProductionLibraryPersistence(directory: databaseDirectory)
            _library = StateObject(wrappedValue: LibraryStore(books: books, defaults: defaults, importsURL: archive, seedDemoData: environment.isDemo, productionPersistence: backend))
            launchError = nil
        } catch {
            _library = StateObject(wrappedValue: LibraryStore(books: [], defaults: defaults, seedDemoData: environment.isDemo))
            launchError = "书库加载失败，请保留本地数据后重试。"
        }
    }

    var body: some Scene {
        WindowGroup {
            if let launchError {
                ContentUnavailableView("暂时无法打开书库", systemImage: "books.vertical", description: Text(launchError))
            } else {
                RootView().environmentObject(library).environmentObject(featureDemo).environmentObject(navigation).environmentObject(toolbox).environmentObject(shushan)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var navigation: NavigationStore
    @EnvironmentObject private var shushan: ShushanAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = AppTab.shelf
    @State private var showPlayer = false

    var body: some View {
        navigationTabs
        .allowsHitTesting(store.loadState == .ready)
        .overlay {
            if store.loadState != .ready {
                ZStack {
                    Palette.background.ignoresSafeArea()
                    if store.loadState == .loading { ProgressView("正在打开书库") }
                    else {
                        ContentUnavailableView {
                            Label("暂时无法打开书库", systemImage: "books.vertical")
                        } description: { Text("原有记录和文件已保留，请重试。") }
                        actions: { Button("重试") { Task { await store.bootstrapProductionIfNeeded() } } }
                    }
                }
            }
        }
        .task {
            await store.bootstrapProductionIfNeeded()
            #if DEBUG
            if !store.isDemo && ProcessInfo.processInfo.arguments.contains("--validate-step-zero-source") {
                try? await SourceFeasibilityValidation.runDevelopmentProbe(credential: shushan.credentialForRequests)
            }
            #endif
        }
        .onChange(of: store.loadState) { _, state in if state == .ready { demo.connectReader(store) } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { Task { await store.saveBeforeSuspending() } } }
        .onChange(of: store.reader?.id) { _, id in if id == nil { Task { await store.flushPendingWrites() } } }
        .onAppear { demo.connectReader(store) }
        .onReceive(shushan.$credential) { demo.updateShushanAccount($0, host: shushan.hostText) }
        .tint(Palette.green)
        .preferredColorScheme(.light)
        .onReceive(NotificationCenter.default.publisher(for: .showImportedShelf)) { _ in selectedTab = .shelf }
        .onChange(of: navigation.visibleTabs) { _, _ in selectedTab = navigation.validSelection(selectedTab) }
        .sheet(isPresented: $showPlayer) {
            NavigationStack { FeatureDemoView(feature: FeatureCatalog.feature("backgroundAudio"))
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showPlayer = false } } } }
        }
        .fullScreenCover(item: $store.reader) { session in
            ReaderView(book: session.book, initialChapter: session.chapter).id(session.id).environmentObject(store)
        }
        .alert("本地记录提示", isPresented: Binding(get: { store.storageMessage != nil }, set: { if !$0 { store.storageMessage = nil } })) {
            Button("知道了") { store.storageMessage = nil }
        } message: { Text(store.storageMessage ?? "") }
    }
    @ViewBuilder private var navigationTabs: some View {
        if #available(iOS 26.0, *) {
            modernTabs.tabBarMinimizeBehavior(navigation.autoCollapse ? .onScrollDown : .never)
        } else if #available(iOS 18.0, *) {
            modernTabs
        } else {
            TabView(selection: $selectedTab) {
                ForEach(navigation.visibleTabs + [.search]) { tab in
                    tabPage(tab).tabItem { Label(tab.title, systemImage: tab.icon) }.tag(tab)
                }
            }
        }
    }
    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(navigation.visibleTabs) { tab in
                Tab(tab.title, systemImage: tab.icon, value: tab) { tabPage(tab) }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { tabPage(.search) }
        }
    }
    private func tabPage(_ tab: AppTab) -> some View {
        NavigationStack {
            switch tab {
            case .shelf: ShelfView(onDiscover: { selectedTab = .search })
            case .footprints: FootprintsView()
            case .discover: DiscoverView()
            case .sources: FeatureHubView(sourceOnly: true)
            case .tools: FeatureHubView()
            case .profile: ProfileView(onShelf: { selectedTab = .shelf })
            case .search: DiscoverView(searchEntry: true)
            }
        }.safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
    }
    @ViewBuilder private var miniPlayer: some View {
            if demo.playerVisible {
                HStack(spacing: 15) {
                    Button { showPlayer = true } label: { Label("长风渡山海 · 演示朗读", systemImage: "waveform").font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }
                    Button { demo.isPlaying.toggle() } label: { Image(systemName: demo.isPlaying ? "pause.fill" : "play.fill").frame(width: 40, height: 40) }.accessibilityLabel("切换演示朗读")
                    Button { demo.playerVisible = false; demo.isPlaying = false } label: { Image(systemName: "xmark").frame(width: 36, height: 40) }.accessibilityLabel("关闭演示播放器")
                }.foregroundStyle(Palette.green).padding(.horizontal, 17).background(.regularMaterial)
            }
    }

}
