import SwiftUI

@main
struct YueshanApp: App {
    @StateObject private var library: LibraryStore
    private let launchError: String?

    init() {
        let defaults: UserDefaults
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            defaults = UserDefaults(suiteName: "com.yueshan.ui-tests")!
            defaults.removePersistentDomain(forName: "com.yueshan.ui-tests")
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
                RootView().environmentObject(library)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ShelfView(onDiscover: { selectedTab = 1 }) }
                .tabItem { Label("书架", systemImage: "books.vertical") }.tag(0)
            NavigationStack { DiscoverView() }
                .tabItem { Label("发现", systemImage: "safari") }.tag(1)
            NavigationStack { ProfileView() }
                .tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(2)
        }
        .tint(Palette.green)
        .preferredColorScheme(.light)
        .fullScreenCover(item: $store.reader) { session in
            ReaderView(book: session.book, initialChapter: session.chapter).environmentObject(store)
        }
        .alert("本地记录提示", isPresented: Binding(get: { store.storageMessage != nil }, set: { if !$0 { store.storageMessage = nil } })) {
            Button("知道了") { store.storageMessage = nil }
        } message: { Text(store.storageMessage ?? "") }
    }
}
