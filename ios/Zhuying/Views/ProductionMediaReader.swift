import SwiftUI
import PDFKit
import ImageIO

@MainActor final class MediaImageCache {
    static let shared = MediaImageCache()
    private var cache: [String:UIImage] = [:]
    private var order: [String] = []
    private(set) var bytes = 0
    private var costs: [String:Int] = [:]
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName:UIApplication.didReceiveMemoryWarningNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.clear() } }
    }
    func image(_ reference: ResourceFileReference) -> UIImage? {
        guard let image = cache[reference.digest] else { return nil }; order.removeAll{$0 == reference.digest}; order.append(reference.digest); return image
    }
    func save(_ image: UIImage,reference: ResourceFileReference) {
        guard let cg = image.cgImage else { return }; let cost = cg.bytesPerRow * cg.height
        guard cost > 0,cost <= 16 * 1024 * 1024 else { return }
        bytes -= costs[reference.digest] ?? 0; costs[reference.digest] = cost; bytes += cost
        cache[reference.digest] = image; order.removeAll{$0 == reference.digest}; order.append(reference.digest)
        while order.count > 8 || bytes > 16 * 1024 * 1024 { let key = order.removeFirst(); bytes -= costs.removeValue(forKey:key) ?? 0; cache.removeValue(forKey:key) }
    }
    func clear() { cache = [:]; order = []; costs = [:]; bytes = 0 }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

struct ProductionMediaReader: View {
    @Environment(\.themeAppearance) private var appAppearance
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var continuous = true
    @State private var pdfURL: URL?
    @State private var error: String?
    @State private var bookmarkList = false
    @State private var restore = MediaReadingLocation(page:0)
    @State private var restoreID = 0
    @State private var readyPages = Set<Int>()
    @State private var outline: [PDFOutlineItem] = []
    @State private var stripRestorePage: Int?
    private var media: MediaBookReference { book.media! }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                if let error { ThemeUnavailableView("页面暂时无法打开",systemImage:"doc",description:Text(error)) }
                else if media.kind == .pdf {
                    if let pdfURL { NativePDFPages(url:pdfURL,continuous:continuous,restore:restore,revision:restoreID,onLocation:record).accessibilityIdentifier("nativePDFPages") }
                    else { ProgressView("正在校验 PDF") }
                } else { comic }
                VStack(spacing:10) {
                    HStack {
                        Button { jump(page - 1) } label: { ThemeIcon(systemName:"chevron.left").frame(width:44,height:44) }.disabled(page == 0).accessibilityIdentifier("mediaPreviousPage")
                        Text("第 \(page + 1) / \(media.pageCount) 页").font(.system(size:12)).frame(maxWidth:.infinity).accessibilityIdentifier("mediaPageStatus")
                        Button { jump(page + 1) } label: { ThemeIcon(systemName:"chevron.right").frame(width:44,height:44) }.disabled(page + 1 >= media.pageCount).accessibilityIdentifier("mediaNextPage")
                    }
                    HStack {
                        Picker("页面浏览",selection:$continuous) { Text(media.kind == .comic ? "条漫" : "连续").tag(true); Text("分页").tag(false) }.pickerStyle(.segmented).accessibilityIdentifier("mediaDisplayMode")
                        Button { library.saveMediaBookmark(book) } label: { ThemeIcon(systemName:"bookmark.badge.plus").frame(width:44,height:44) }.accessibilityIdentifier("mediaAddBookmark")
                        Button { bookmarkList = true } label: { ThemeIcon(systemName:"list.bullet").frame(width:44,height:44) }.accessibilityIdentifier("mediaBookmarks")
                    }
                }.padding(.horizontal,18).background(.regularMaterial)
            }.navigationTitle(book.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarLeading) { Button("返回书架") { dismiss() } } }
                .background(ThemeSurface()).tint(appAppearance.palette.primary)
                .task {
                    restore = (library.mediaLocations[book.id] ?? .init(page:0)).validated(pages:media.pageCount); page = restore.page; continuous = media.kind == .pdf
                    if media.kind == .pdf { do { let url = try await library.mediaURL(media.resources[0]); outline = await Task.detached { PDFOutlineItem.load(url) }.value; pdfURL = url } catch { self.error = error.localizedDescription } }
                }
                .onChange(of:continuous) { _,_ in restoreID += 1 }
                .onDisappear { library.trackReading(nil); Task { _ = await library.flushPendingWrites() } }
                .sheet(isPresented:$bookmarkList) {
                    NavigationStack {
                        List {
                            if !outline.isEmpty { Section("文档目录") { ForEach(outline) { item in Button(item.title) { jump(item.page); bookmarkList = false }.padding(.leading,CGFloat(max(0,item.depth - 1)) * 12) } } }
                            Section("页面书签") {
                            ForEach(library.mediaBookmarks.filter{$0.bookID == book.id}) { mark in
                                Button(mark.title) { restore = mark.location; page = restore.page; restoreID += 1; bookmarkList = false }
                                    .swipeActions { Button("删除",role:.destructive) { library.removeMediaBookmark(mark.id) } }
                            }
                            }
                        }.navigationTitle("页面书签").toolbar { Button("完成") { bookmarkList = false } }
                    }
                }
        }
    }
    private var comic: some View {
        GeometryReader { geometry in
            if continuous {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing:8) {
                            ForEach(media.resources.indices,id:\.self) { index in
                                NativeComicImage(reference:media.resources[index],library:library,onReady:{ readyPages.insert(index); if index == page { record(restore) } })
                                    .id(index).background(GeometryReader { item in Color.clear.preference(key:ComicPageFrames.self,value:[index:item.frame(in:.named("comicViewport"))]) })
                            }
                        }
                    }.coordinateSpace(name:"comicViewport")
                        .onPreferenceChange(ComicPageFrames.self) { frames in
                            guard stripRestorePage == nil else { return }
                            if let visible = frames.filter({readyPages.contains($0.key) && $0.value.maxY > 0 && $0.value.minY < geometry.size.height}).min(by:{abs($0.value.minY) < abs($1.value.minY)}) {
                                let y = max(0,-visible.value.minY / max(1,visible.value.height))
                                if visible.key != page || abs(y - restore.y) > 0.03 { record(.init(page:visible.key,y:y)) }
                            }
                        }
                        .onAppear { stripRestorePage = page }
                        .onChange(of:restoreID) { _,_ in stripRestorePage = page }
                        .task(id:"\(stripRestorePage ?? -1)-\(readyPages.sorted())") {
                            guard let target = stripRestorePage,readyPages.contains(target) else { return }
                            await Task.yield(); proxy.scrollTo(target,anchor:.top)
                            // Decoding replaces the initial placeholder height.
                            // Let that layout settle before tracking visible pages.
                            try? await Task.sleep(for:.milliseconds(150))
                            guard !Task.isCancelled else { return }; proxy.scrollTo(target,anchor:.top); stripRestorePage = nil
                        }
                }
            } else {
                TabView(selection:Binding(get:{page},set:{page = $0; restore = .init(page:$0); if readyPages.contains($0) { record(restore) } })) {
                    ForEach(media.resources.indices,id:\.self) { index in
                        NativeComicImage(reference:media.resources[index],library:library,onReady:{ readyPages.insert(index); if index == page { record(.init(page:index)) } }).tag(index).padding(.horizontal,4)
                    }
                }.tabViewStyle(.page(indexDisplayMode:.never)).accessibilityIdentifier("comicPagedReader")
            }
        }.accessibilityIdentifier("nativeComicPages")
    }
    private func record(_ location: MediaReadingLocation) { let location = location.validated(pages:media.pageCount); page = location.page; restore = location; library.recordMedia(book,location:location) }
    private func jump(_ index: Int) {
        guard (0..<media.pageCount).contains(index) else { return }
        restore = .init(page:index); page = index; restoreID += 1
        if media.kind == .comic && readyPages.contains(index) { record(restore) }
    }
}

private struct ComicPageFrames: PreferenceKey {
    static var defaultValue: [Int:CGRect] = [:]
    static func reduce(value: inout [Int:CGRect],nextValue: () -> [Int:CGRect]) { value.merge(nextValue(),uniquingKeysWith:{$1}) }
}
private struct NativeComicImage: View {
    let reference: ResourceFileReference
    let library: LibraryStore
    let onReady: () -> Void
    @State private var image: UIImage?
    @State private var error: String?
    var body: some View {
        Group {
            if let image { Image(uiImage:image).resizable().scaledToFit().accessibilityLabel("漫画页面") }
            else if let error { Text(error).font(.system(size:12)).frame(minHeight:160) }
            else { ProgressView().frame(minHeight:200) }
        }.task(id:reference.digest) {
            if let cached = MediaImageCache.shared.image(reference) { image = cached; onReady(); return }
            do {
                let url = try await library.mediaURL(reference)
                let decoded = try await Task.detached { () -> CGImage in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw ContentFailure.storageFailure }; return image
                }.value
                try Task.checkCancellation(); let result = UIImage(cgImage:decoded); MediaImageCache.shared.save(result,reference:reference); image = result; onReady()
            } catch { if !Task.isCancelled { self.error = "图片缺失或损坏，请从备份恢复。" } }
        }
    }
}

private final class LayoutAwarePDFView: PDFView {
    var willChangeSize: (() -> Void)?
    var didChangeSize: (() -> Void)?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        let changed = bounds.size != previousSize; if changed { previousSize = bounds.size; willChangeSize?() }
        super.layoutSubviews()
        if changed { didChangeSize?() }
    }
}
private struct NativePDFPages: UIViewRepresentable {
    @Environment(\.themeAppearance) private var appAppearance
    let url: URL
    let continuous: Bool
    let restore: MediaReadingLocation
    let revision: Int
    let onLocation: (MediaReadingLocation) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let view = LayoutAwarePDFView(); view.backgroundColor = UIColor(appAppearance.palette.background); view.autoScales = true; view.document = PDFDocument(url:url)
        view.willChangeSize = { [weak coordinator = context.coordinator] in coordinator?.beginResize() }
        view.didChangeSize = { [weak coordinator = context.coordinator] in DispatchQueue.main.async { coordinator?.finishResize() } }
        context.coordinator.view = view; context.coordinator.observe(); context.coordinator.configure(self,force:true); return view
    }
    func updateUIView(_ view: PDFView,context: Context) { context.coordinator.configure(self,force:false) }
    final class Coordinator: NSObject {
        var parent: NativePDFPages
        weak var view: PDFView?
        private var revision = -1
        private var updating = false
        private var observers: [NSObjectProtocol] = []
        private var locationTimer: Timer?
        private var lastReported: MediaReadingLocation?
        init(_ parent: NativePDFPages) { self.parent = parent }
        func observe() {
            for name in [Notification.Name.PDFViewPageChanged,.PDFViewScaleChanged,.PDFViewVisiblePagesChanged] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:view,queue:.main) { [weak self] _ in self?.changed() })
            }
            // PDFKit's page notifications do not fire for every pan within a page.
            // Sample the visible destination while this reader exists; persist only changes.
            locationTimer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in self?.changed() }
        }
        func configure(_ parent: NativePDFPages,force: Bool) {
            let modeChanged = self.parent.continuous != parent.continuous; self.parent = parent
            guard let view,let pdf = view.document else { return }
            guard view.bounds.width > 0,view.bounds.height > 0 else { return }
            guard force || modeChanged || revision != parent.revision else { return }; updating = true
            if force || modeChanged { view.displayMode = parent.continuous ? .singlePageContinuous : .singlePage; view.displayDirection = .vertical; view.autoScales = true }
            revision = parent.revision
            if let page = pdf.page(at:min(max(0,parent.restore.page),pdf.pageCount - 1)) {
                let bounds = page.bounds(for:.cropBox)
                view.go(to:page)
                if view.scaleFactorForSizeToFit > 0 { view.scaleFactor = view.scaleFactorForSizeToFit * parent.restore.zoom }
                if parent.restore.zoom > 1.01 || (parent.restore.y > 0.05 && parent.restore.y < 0.95) {
                    view.go(to:PDFDestination(page:page,at:.init(x:bounds.minX + parent.restore.x * bounds.width,y:bounds.minY + parent.restore.y * bounds.height)))
                }
            }
            updating = false; DispatchQueue.main.async { [weak self] in self?.changed() }
        }
        func changed() {
            guard !updating,revision >= 0,let view,view.window != nil,let pdf = view.document,let page = view.currentPage else { return }
            let bounds = page.bounds(for:.cropBox),point = view.convert(CGPoint(x:view.bounds.minX + 1,y:view.bounds.minY + 1),to:page)
            let location = MediaReadingLocation(page:pdf.index(for:page),x:(point.x - bounds.minX) / max(1,bounds.width),y:(point.y - bounds.minY) / max(1,bounds.height),zoom:view.scaleFactor / max(0.01,view.scaleFactorForSizeToFit)).validated(pages:pdf.pageCount)
            if let last = lastReported, last.page == location.page,abs(last.x - location.x) < 0.002,abs(last.y - location.y) < 0.002,abs(last.zoom - location.zoom) < 0.002 { return }
            lastReported = location; parent.onLocation(location)
        }
        func beginResize() { updating = true }
        func finishResize() { configure(parent,force:true) }
        deinit { locationTimer?.invalidate(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
