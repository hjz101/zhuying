import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject private var store: LibraryStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("每一次翻开，都有迹可循。").font(.system(size: 12, design: .serif)).foregroundStyle(Palette.muted)
                if store.history.isEmpty {
                    ContentUnavailableView("还没有阅读记录", systemImage: "clock", description: Text("开始阅读后，会自动为你留下位置。"))
                }
                ForEach(store.history) { book in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { store.read(book) } label: { BookRow(book: book) }.buttonStyle(.plain).accessibilityIdentifier("history-\(book.id)")
                        if let progress = store.progress[book.id] {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(book.chapterTitle(progress.chapter)).font(.system(size: 11)).foregroundStyle(Palette.green)
                                    Text(progress.updatedAt, style: .relative).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if !store.isFavorite(book) {
                                    Button { store.toggleFavorite(book) } label: { Label("加入书架", systemImage: "plus").font(.system(size: 11)).padding(11).background(Palette.green.opacity(0.07), in: Capsule()) }.accessibilityIdentifier("history-save-\(book.id)")
                                } else { Text("已在书架").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                            }
                        }
                    }
                    Divider().overlay(Palette.line)
                }
            }.padding(23)
        }.background(Palette.background).navigationTitle("阅读历史").navigationBarTitleDisplayMode(.inline)
    }
}

struct UpdatesView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var simulated = false
    @State private var pendingBook: Book?
    @State private var pendingChapter: Int?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("追更小报", systemImage: "sparkles").font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Palette.green)
                        Text(store.isDemo ? "模拟更新提醒 · 展示连载作品的末尾样章，不访问网络，也不发送系统通知。" : "查看连载作品的章节更新。").font(.system(size: 11)).lineSpacing(5).foregroundStyle(Palette.muted)
                    }
                    if store.updatedBooks.isEmpty {
                        ContentUnavailableView("暂时没有待读更新", systemImage: "checkmark.circle", description: Text(store.isDemo ? "可以模拟一次更新，看看追更的体验。" : "当前还没有可展示的章节更新。"))
                    }
                    ForEach(store.updatedBooks) { book in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 16) {
                                BookCover(book: book, width: 62)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(book.title).font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(Palette.green)
                                    Text("更新 \(store.updateCount(book)) 章").font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                                    Text("最新 · \(book.chapterTitle(book.chapters.count - 1))").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }.padding(.top, 3)
                            }
                            HStack(spacing: 12) {
                                Button("从上次继续") { open(book, chapter: nil) }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("update-resume-\(book.id)")
                                Button("读更新首章") {
                                    let notice = store.updates[book.id]
                                    open(book, chapter: min(book.chapters.count - 1, max(notice?.firstChapter ?? 0, (notice?.readThrough ?? -1) + 1)))
                                }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("update-read-\(book.id)")
                            }
                        }.padding(17).background(.white.opacity(0.6), in: .rect(cornerRadius: 15))
                    }
                    Button { if store.isDemo { store.simulateUpdates() }; simulated = true } label: { Label(store.isDemo ? "模拟一次更新" : "检查更新", systemImage: "arrow.clockwise") }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("simulateUpdates")
                    if simulated { Text(store.isDemo ? "已重置连载作品末尾 3 章的演示更新标记。" : "当前版本暂不支持更新检查。").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                }.padding(23)
            }.background(Palette.background).navigationTitle("作品更新").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .appPageStyle().presentationBackground(Palette.background).presentationDragIndicator(.visible).presentationCornerRadius(26)
        .onDisappear {
            guard let book = pendingBook else { return }
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(300)); store.read(book, chapter: pendingChapter) }
        }
    }
    private func open(_ book: Book, chapter: Int?) { pendingBook = book; pendingChapter = chapter; dismiss() }
}
