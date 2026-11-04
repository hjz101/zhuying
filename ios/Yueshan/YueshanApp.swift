import SwiftUI

@main
struct YueshanApp: App {
    @StateObject private var library: LibraryStore
    @StateObject private var featureDemo = FeatureDemoStore()
    private let launchError: String?

    init() {
        let defaults: UserDefaults
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            defaults = UserDefaults(suiteName: "com.yueshan.ui-tests")!
            if !ProcessInfo.processInfo.arguments.contains("--preserve-ui-test-state") {
                defaults.removePersistentDomain(forName: "com.yueshan.ui-tests")
            }
        } else { defaults = .standard }
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
                RootView().environmentObject(library).environmentObject(featureDemo)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    @State private var selectedTab = 0
    @State private var showPlayer = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ShelfView(onDiscover: { selectedTab = 1 }) }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
            NavigationStack { DiscoverView() }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("发现", systemImage: "safari") }.tag(1)
            NavigationStack { FeatureHubView(sourceOnly: true) }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("书源", systemImage: "externaldrive") }.tag(2)
            NavigationStack { ProfileView(onShelf: { selectedTab = 0 }) }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(Palette.green)
        .preferredColorScheme(.light)
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
