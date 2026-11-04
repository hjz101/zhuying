import SwiftUI

struct BookDetailView: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    @State private var showContents = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 15) {
                    BookCover(book: book, width: 127).padding(.top, 23).padding(.bottom, 9)
                    Text(book.title).font(.system(size: 29, weight: .semibold, design: .serif)).tracking(3).foregroundStyle(Palette.green)
                    Text("\(book.author) 著").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text(book.subtitle).font(.system(size: 12, design: .serif)).foregroundStyle(Palette.green.opacity(0.6)).padding(.top, 4)
                    HStack(spacing: 7) {
                        ForEach(book.tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.horizontal, 9).padding(.vertical, 6).background(.white.opacity(0.45), in: .rect(cornerRadius: 5))
                        }
                    }
                    HStack(spacing: 0) {
                        stat(book.words, label: "字数展示")
                        Rectangle().fill(Palette.line).frame(width: 1, height: 25)
                        stat(book.status, label: book.genre)
                        Rectangle().fill(Palette.line).frame(width: 1, height: 25)
                        stat("\(book.chapters.count) 章", label: "示例章节")
                    }.padding(.top, 6).padding(.bottom, 24)
                }.frame(maxWidth: .infinity).background(LinearGradient(colors: [Color(hex: 0xE9EDDF), Palette.background], startPoint: .top, endPoint: .bottom))

                VStack(alignment: .leading, spacing: 20) {
                    SectionHeading(title: "故事简介")
                    Text(book.intro).font(.system(size: 14)).lineSpacing(9).foregroundStyle(Color(hex: 0x7A856F))
                    Text("原创示例小说 · 用于预览阅读体验").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.bottom, 5)
                    HStack {
                        ForEach(["sourceSwitch", "chapterCache", "covers"], id: \.self) { id in
                            NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id), bookID: book.id) } label: { Label(FeatureCatalog.feature(id).title, systemImage: FeatureCatalog.feature(id).icon).font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 40) }
                        }
                    }
                    Divider().overlay(Palette.line)
                    Button { showContents = true } label: {
                        HStack {
                            Label("章节目录", systemImage: "list.bullet").font(.system(size: 16, weight: .medium, design: .serif))
                            Spacer()
                            Text("共 \(book.chapters.count) 章").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.foregroundStyle(Palette.green).frame(minHeight: 42)
                    }.accessibilityIdentifier("detailContents")
                    if let progress = store.progress[book.id] {
                        Label("上次读到 · \(book.chapterTitle(progress.chapter))", systemImage: "clock").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 30)
            }
        }
        .background(Palette.background)
        .navigationTitle("作品详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { store.toggleFavorite(book) } label: { Image(systemName: store.isFavorite(book) ? "bookmark.fill" : "bookmark") }.accessibilityLabel(store.isFavorite(book) ? "移出书架" : "加入书架")
        } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.toggleFavorite(book) } label: {
                    Label(store.isFavorite(book) ? "已在书架" : "加入书架", systemImage: store.isFavorite(book) ? "checkmark" : "plus")
                }.buttonStyle(PrimaryButtonStyle(filled: false)).frame(maxWidth: 132)
                Button { store.read(book) } label: {
                    HStack { Text(store.progress[book.id] == nil ? "开始阅读" : "继续阅读"); Image(systemName: "arrow.right") }
                }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("detailRead")
            }.padding(.horizontal, 22).padding(.vertical, 12).background(.regularMaterial)
        }
        .sheet(isPresented: $showContents) {
            ContentsView(book: book, currentChapter: store.progress[book.id]?.chapter) { chapter in
                showContents = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    store.read(book, chapter: chapter)
                }
            }
        }
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(spacing: 7) {
            Text(value).font(.system(size: 16, weight: .medium, design: .serif)).foregroundStyle(Palette.green)
            Text(label).font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.frame(maxWidth: .infinity)
    }
}
