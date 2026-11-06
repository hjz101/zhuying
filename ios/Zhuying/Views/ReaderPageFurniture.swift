import SwiftUI

struct ReaderPageFurniture: View {
    let settings: ReadingSettings
    let book: Book
    let chapter: Int
    let page: Int
    let pageCount: Int
    let overallProgress: Int

    var body: some View {
        GeometryReader { geometry in
            let layout = ReaderLayout(settings: settings, size: geometry.size)
            let palette = ReaderPalette(settings: settings)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ZStack(alignment: .topLeading) {
                    ForEach(settings.preferences.pageElements.filter(isVisible)) { item in
                        let frame = item.zone == "footer" ? layout.footerFrame : layout.headerFrame
                        let width = frame.width * item.width / 100
                        let x = min(max(item.width / 2, item.x), 100 - item.width / 2)
                        let halfHeight = min(50, max(28, item.fontSize + 12) / max(1, frame.height) * 50)
                        let y = min(max(halfHeight, item.y), 100 - halfHeight)
                        Text(label(item, date: context.date))
                            .font(.system(size: item.fontSize))
                            .foregroundStyle(Color(item.color.map { UIColor(readerHex: $0) } ?? palette.secondary))
                            .lineLimit(2).minimumScaleFactor(0.75)
                            .frame(width: width, height: min(max(28, item.fontSize + 12), max(0, frame.height))).clipped()
                            .position(x: frame.minX + frame.width * x / 100, y: frame.minY + frame.height * y / 100)
                            .accessibilityIdentifier("reader-page-element-\(item.id)")
                    }
                }
            }
        }.allowsHitTesting(false)
    }
    private func isVisible(_ item: ReaderPageElement) -> Bool {
        item.zone == "footer" ? settings.preferences.footerEnabled : settings.preferences.headerEnabled
    }
    private func label(_ item: ReaderPageElement, date: Date) -> String {
        switch item.kind {
        case "书名": book.title
        case "章节": book.chapterTitle(chapter)
        case "时间": date.formatted(date: .omitted, time: .shortened)
        case "进度": settings.mode.isPaged ? "\(page + 1) / \(max(1, pageCount)) 页" : "已读 \(overallProgress)%"
        default: item.text
        }
    }
}
