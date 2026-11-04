import SwiftUI

@main
struct YueshanApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var featureDemo = FeatureDemoStore()
    @StateObject private var navigation: NavigationStore
    private let launchError: String?

    init() {
        let defaults: UserDefaults
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            defaults = UserDefaults(suiteName: "com.yueshan.ui-tests")!
            if !ProcessInfo.processInfo.arguments.contains("--preserve-ui-test-state") {
                defaults.removePersistentDomain(forName: "com.yueshan.ui-tests")
            }
        } else { defaults = .standard }
        _navigation = StateObject(wrappedValue: NavigationStore(defaults: defaults))
        do {
            let books = try Book.load()
            _library = StateObject(wrappedValue: LibraryStore(books: books, defaults: defaults))
            launchError = nil
        } catch {
            _library = StateObject(wrappedValue: LibraryStore(books: [], defaults: defaults))
            launchError = "示例书库加载失败，请重新安装 Demo。"
        }
    }

    var body: some Scene {
        WindowGroup {
            if let launchError {
                ContentUnavailableView("暂时无法打开书库", systemImage: "books.vertical", description: Text(launchError))
            } else {
                RootView().environmentObject(library).environmentObject(featureDemo).environmentObject(navigation)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var navigation: NavigationStore
    @State private var selectedTab = AppTab.shelf
    @State private var showPlayer = false

    var body: some View {
        navigationTabs
        .tint(Palette.green)
        .preferredColorScheme(.light)
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
