import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var store: LibraryStore
    var searchEntry = false
    @State private var query = ""
    @State private var category = "全部"
    @State private var searchPresented = false
    private let categories = ["全部", "奇幻", "都市", "科幻", "古风", "悬疑", "仙侠"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                VStack(alignment: .leading, spacing: 13) {
                    Text("FIND YOUR NEXT CHAPTER").font(.system(size: 8)).tracking(2).foregroundStyle(Palette.muted)
                    Text("下一段故事，\n从这里开始。").font(.system(size: 31, weight: .medium, design: .serif)).tracking(2).lineSpacing(8).foregroundStyle(Palette.green)
                    Text("在熟悉的名字里重逢，在陌生的世界里出发。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
                HStack(spacing: 12) {
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("search")) } label: { Label("多源搜索", systemImage: "square.stack").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(Palette.green.opacity(0.07), in: .rect(cornerRadius: 10)) }.accessibilityIdentifier("discoverMultiSearch")
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("discover")) } label: { Label("分类与订阅", systemImage: "bell.badge").font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 45).background(Palette.green.opacity(0.07), in: .rect(cornerRadius: 10)) }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(categories, id: \.self) { item in
                            Button { category = item } label: {
                                Text(item).font(.system(size: 12, weight: item == category ? .medium : .regular)).padding(.horizontal, 17).frame(height: 36)
                                    .foregroundStyle(item == category ? Palette.green : Palette.muted)
                                    .background(item == category ? Color(hex: 0xE5EBD9) : .clear, in: Capsule())
                            }.accessibilityAddTraits(item == category ? .isSelected : [])
                        }
                    }
                }
                let results = store.search(query, category: category)
                SectionHeading(title: query.isEmpty ? "故事小馆" : "搜索结果", subtitle: "\(results.count) 部示例作品")
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                    Button("浏览全部作品") { query = ""; category = "全部" }.buttonStyle(PrimaryButtonStyle(filled: false))
                } else {
                    LazyVStack(spacing: 23) {
                        ForEach(results) { book in
                            NavigationLink(value: book) { BookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier("result-\(book.id)")
                            if book.id != results.last?.id { Divider().overlay(Palette.line) }
                        }
                    }
                }
            }.padding(.horizontal, 22).padding(.top, 19).padding(.bottom, 25)
        }
        .background(Palette.background)
        .navigationTitle(searchEntry ? "搜索" : "发现")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索书名或作者")
        .onAppear { if searchEntry { searchPresented = true } }
        .autocorrectionDisabled()
        .navigationDestination(for: Book.self) { BookDetailView(book: $0) }
    }
}
