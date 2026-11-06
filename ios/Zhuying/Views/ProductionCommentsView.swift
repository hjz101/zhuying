import SwiftUI

struct ProductionCommentsView: View {
    @Environment(\.themeAppearance) private var appAppearance
    let client: ShushanCommentsClient
    let context: ShushanCommentContext
    let paragraph: SourceParagraphCount
    let documentVersion: String
    let originalText: String
    @State private var comments: [SourceComment] = []
    @State private var cursor: String? = "0"
    @State private var busy = false
    @State private var message: String?
    @State private var loaded = false
    @State private var stale = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Text("本段评论").font(.system(size:23,weight:.medium,design:.serif))
                Text(SourceDistributionPolicy.nativeServiceName + " · 只读评论").font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
                Text(originalText).font(.system(size:14)).lineSpacing(7)
                if stale { Text("当前展示缓存，联网后可刷新。").font(.system(size:12)).foregroundStyle(appAppearance.palette.muted).accessibilityIdentifier("commentsStale") }
                ForEach(comments) { comment in
                    AppSettingsCard(comment.author,icon:"bubble.left") {
                        Text(comment.text.isEmpty ? "此条评论仅含媒体，当前支持文字展示。" : comment.text).font(.system(size:14)).textSelection(.enabled)
                        HStack { if let date = comment.createdAt { Text(date,style:.date) }; Spacer(); Text("赞 \(comment.likes)") }.font(.system(size:11)).foregroundStyle(appAppearance.palette.muted)
                    }
                }
                if loaded && comments.isEmpty && message == nil { Text("暂无评论").accessibilityIdentifier("commentsEmpty") }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("commentsMessage") }
                if busy { ProgressView("正在读取评论") }
                else {
                    if cursor != nil { Button(loaded ? "加载更多" : "重试") { Task { await load() } }.accessibilityIdentifier("commentsMore") }
                    Button("刷新") { comments = []; cursor = "0"; loaded = false; Task { await load() } }.accessibilityIdentifier("commentsRefresh")
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("本段评论").task { if !loaded { await load() } }
    }
    private func load() async {
        guard !busy,let requested = cursor else { return }; busy = true; message = nil; defer { busy = false }
        let key = SourceCommentCache.key(client:client,context:context,version:documentVersion,paragraph:paragraph.nativeID,cursor:requested)
        do {
            let page: SourceCommentPage
            do { page = try await client.page(context,paragraph:paragraph.nativeID,cursor:requested); stale = false; try? await SourceCommentCache.shared.write(page,key:key) }
            catch {
                try Task.checkCancellation()
                guard let cached = await SourceCommentCache.shared.read(SourceCommentPage.self,key:key,maximumAge:7 * 86400) else { throw error }
                page = cached; stale = true
            }
            try Task.checkCancellation()
            if requested == "0" && !page.comments.isEmpty {
                guard let quote = page.sourceQuote,ShushanCommentsClient.sameParagraph(quote,originalText) else { throw ContentFailure.invalidResponse }
            }
            // A source quote is the final identity check. Never display another
            // paragraph's comments after edits or a source-side reflow.
            if let quote = page.sourceQuote,!quote.isEmpty,!ShushanCommentsClient.sameParagraph(quote,originalText) { throw ContentFailure.invalidResponse }
            var seen = Set(comments.map(\.id)); comments += page.comments.filter{seen.insert($0.id).inserted}
            if comments.count > 2000 { cursor = nil; message = "已加载 2000 条，请刷新后查看最新内容。" } else { cursor = page.nextCursor }
            loaded = true
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
}
