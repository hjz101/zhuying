import SwiftUI

struct ProductionDownloadView: View {
    var bookID: String?
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedBook = ""
    @State private var count = "后续 10 章"
    @State private var wifiOnly = true
    @State private var tasks: [OfflineDownloadTask] = []
    @State private var bytes = 0
    @State private var message: String?
    @State private var deleting: String?
    private var books: [Book] { library.books.filter { library.remoteMetadata($0.id) != nil } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"章节缓存",subtitle:"主动下载 · 已完成内容保留 · 暂停和重启续传",icon:"arrow.down.circle")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("作品",selection:$selectedBook) { Text("选择在线作品").tag(""); ForEach(books) { Text($0.title).tag($0.id) } }
                    Picker("缓存范围",selection:$count) { ForEach(["后续 10 章","后续 50 章","全部章节"],id:\.self) { Text($0) } }
                    Toggle("仅 Wi-Fi 下载",isOn:$wifiOnly)
                }
                Button("开始下载") { Task { await perform { try await library.enqueueDownload(bookID:selectedBook,count:count == "全部章节" ? nil : count == "后续 10 章" ? 10 : 50,wifiOnly:wifiOnly) } } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(selectedBook.isEmpty).accessibilityIdentifier("enqueueDownload")
                AppSettingsCard("下载队列",icon:"list.bullet") {
                    Text("\(ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file)) / 256 MiB · 最多同时下载 2 章").font(.system(size:11)).foregroundStyle(Palette.muted)
                    ForEach(tasks) { task in
                        VStack(alignment:.leading,spacing:10) {
                            HStack { Text(task.book.title); Spacer(); Text(status(task.status)).font(.system(size:11)) }
                            ProgressView(value:Double(task.completed.count),total:Double(max(1,task.chapters.count)))
                            Text("\(task.completed.count) / \(task.chapters.count) 章").font(.system(size:11))
                            if let message = task.message { Text(message).font(.system(size:11)).foregroundStyle(Palette.accent) }
                            HStack {
                                if task.status == .running || task.status == .queued { Button("暂停") { Task { await perform { try await library.onlineService?.downloads?.pause(task.id) } } } }
                                else if task.status != .completed { Button("继续／重试") { Task { await perform { try await library.onlineService?.downloads?.resume(task.id) } } } }
                                Spacer(); Button("删除任务与下载",role:.destructive) { deleting = task.id }
                            }.font(.system(size:12))
                        }.padding(.vertical,10)
                    }
                    if tasks.isEmpty { Text("没有下载任务").font(.system(size:12)) }
                }
                Text("主动下载独立于近期缓存；清理近期缓存会保留下载。退出到后台时暂停，回到前台可继续。Wi-Fi 条件未满足时等待；原生备份不包含可重新下载的网络正文。")
                    .font(.system(size:12)).foregroundStyle(Palette.muted)
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent) }
            }.padding(22)
        }.appPageStyle().navigationTitle("章节缓存").navigationBarTitleDisplayMode(.inline)
            .task {
                selectedBook = bookID ?? books.first?.id ?? ""
                while !Task.isCancelled { await refresh(); do { try await Task.sleep(for:.seconds(1)) } catch { break } }
            }
            .confirmationDialog("删除任务及已下载章节？阅读进度和书签保留。",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting = nil}}),titleVisibility:.visible) {
                Button("删除下载",role:.destructive) { let id = deleting; deleting = nil; if let id { Task { await perform { try await library.onlineService?.downloads?.remove(id) } } } }
                Button("取消",role:.cancel) {}
            }
    }
    private func status(_ value: OfflineDownloadTask.Status) -> String { switch value { case .queued:"等待下载"; case .running:"正在下载";case .paused:"已暂停";case .failed:"部分失败";case .completed:"已完成" } }
    @MainActor private func refresh() async {
        tasks = await library.onlineService?.downloads?.list() ?? []; bytes = (try? await library.onlineService?.downloads?.usage()) ?? 0
        if message == nil { message = await library.onlineService?.downloads?.warning }
        if library.onlineService?.downloads == nil { message = "下载队列暂时无法打开，原下载文件保留；其他阅读功能仍可使用，请稍后重启重试。" }
    }
    @MainActor private func perform(_ body: () async throws -> Void) async { do { try await body(); message = nil } catch { message = error.localizedDescription }; await refresh() }
}

struct ProductionSourceSwitchView: View {
    var bookID: String?
    @EnvironmentObject private var library: LibraryStore
    @State private var candidates: [LibraryBookRecord] = []
    @State private var selection: LibraryBookRecord?
    @State private var catalog: [ChapterRecord] = []
    @State private var chapter = -1
    @State private var fromStart = false
    @State private var busy = false
    @State private var message: String?
    private var original: Book? { library.books.first { $0.id == bookID } ?? library.history.first }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"换源",subtitle:"候选来源 · 章节映射 · 正文验证后继续阅读",icon:"arrow.triangle.swap")
                if let original {
                    Text("当前作品：\(original.title) · \(original.author)").font(.system(size:13))
                    Button("查找候选来源") { Task { await load(original) } }.buttonStyle(PrimaryButtonStyle(filled:false)).disabled(busy)
                    ForEach(candidates) { candidate in
                        Button { Task { await choose(candidate,original:original) } } label: {
                            HStack { VStack(alignment:.leading) { Text(candidate.title + " · " + candidate.author); Text(candidate.source?.provider ?? "来源").font(.system(size:11)) }; Spacer(); Image(systemName:selection?.id == candidate.id ? "checkmark.circle.fill" : "circle") }
                                .font(.system(size:13)).padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.7),in:.rect(cornerRadius:10))
                        }.buttonStyle(.plain).disabled(busy)
                    }
                    if selection != nil {
                        AppSettingsCard("确认新位置",icon:"list.bullet") {
                            Picker("章节",selection:$chapter) { Text("请选择章节").tag(-1); ForEach(Array(catalog.enumerated()),id:\.element.id) { index,item in if item.access == .readable { Text(item.title).tag(index) } } }
                            Toggle("位置无法确认时，从所选章首继续",isOn:$fromStart)
                            Text("章名及顺序只用于建议，正文上下文必须唯一匹配。不同来源作为独立版本保留，原来源的历史和书签不会删除。")
                                .font(.system(size:11)).foregroundStyle(Palette.muted)
                        }
                        Button("切换并继续阅读") { Task { await apply(original) } }.buttonStyle(PrimaryButtonStyle()).disabled(chapter < 0 || busy)
                    }
                } else { ContentUnavailableView("请先打开一本作品",systemImage:"book") }
                if busy { ProgressView("正在验证书源") }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent) }
            }.padding(22)
        }.appPageStyle().navigationTitle("换源").navigationBarTitleDisplayMode(.inline)
    }
    @MainActor private func load(_ original: Book) async {
        busy = true; defer { busy = false }; selection = nil; message = nil
        do { candidates = try await library.onlineService?.search(query:original.title,page:1).books.filter { $0.id != original.id } ?? [] }
        catch { message = error.localizedDescription }
    }
    @MainActor private func choose(_ candidate: LibraryBookRecord,original: Book) async {
        busy = true; defer { busy = false }; message = nil
        do {
            guard let (details,chapters) = try await library.onlineService?.details(candidate) else { throw ContentFailure.sourceDisabled }
            selection = details; catalog = chapters; chapter = library.sourceSwitchSuggestion(bookID:original.id,catalog:chapters) ?? -1
            fromStart = false; if chapter < 0 { message = "章节存在拆分、合并或同名，无法自动确认。请选择章节，并确认是否接受从章首继续。" }
        } catch { message = error.localizedDescription }
    }
    @MainActor private func apply(_ original: Book) async {
        guard let selection else { return }; busy = true; defer { busy = false }
        do { try await library.switchSource(from:original.id,to:selection,catalog:catalog,chapter:chapter,allowChapterStart:fromStart) }
        catch { message = error.localizedDescription }
    }
}

struct ProductionSourceDiagnosticsView: View {
    var sourceID: String?
    var batch = false
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var shushan: ShushanAccountStore
    @State private var query = ""
    @State private var selection = ""
    @State private var step = SourceDiagnostics.Step.search
    @State private var concurrency = 3
    @State private var timeout = 15.0
    @State private var reports: [SourceDiagnosticResult] = []
    @State private var operation: Task<Void,Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var export: ExportFile?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:batch ? "批量测试" : "书源调试",subtitle:"搜索 → 详情 → 目录 → 正文 · 实际请求与分步结果",icon:batch ? "checklist" : "ladybug")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    if !batch { Picker("书源",selection:$selection) { ForEach(library.sources) { Text($0.name).tag($0.id) } }; Picker("调试步骤",selection:$step) { ForEach(SourceDiagnostics.Step.allCases,id:\.self) { Text($0.rawValue).tag($0) } } }
                    TextField("测试关键词",text:$query).accessibilityIdentifier("sourceDiagnosticQuery")
                    if batch { Picker("并发数量",selection:$concurrency) { ForEach([3,5,10],id:\.self) { Text("\($0)") } } }
                    Slider(value:$timeout,in:5...60,step:1); Text("每步超时 \(Int(timeout)) 秒").font(.system(size:11))
                }
                Button(busy ? "正在运行" : "运行测试") { run() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                if busy { ProgressView(); Button("取消测试") { operation?.cancel(); busy = false } }
                ForEach(reports) { report in
                    HStack { Text(library.sources.first(where:{$0.id == report.sourceID})?.name ?? "来源"); Spacer(); Text("\(report.step) · \(report.status) · \(report.milliseconds) ms · \(report.count)") }.font(.system(size:11)).padding(.vertical,8)
                }
                if !reports.isEmpty { Button("导出脱敏报告") { do { export = try ExportFile.prepare(JSONEncoder().encode(reports),filename:"书源检测报告.json") } catch { message = error.localizedDescription } }.buttonStyle(PrimaryButtonStyle(filled:false)) }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(Palette.accent) }
            }.padding(22)
        }.appPageStyle().navigationTitle(batch ? "批量测试" : "书源调试").navigationBarTitleDisplayMode(.inline)
            .onAppear { selection = library.sources.contains(where: { $0.id == sourceID }) ? sourceID! : library.sources.first?.id ?? "" }
            .onDisappear { operation?.cancel() }
            .sheet(item:$export) { file in NativeFileExporter(file:file) { _ in export = nil } }
    }
    private func run() {
        operation?.cancel(); busy = true; reports = []; message = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            var providers: [any BookSource] = []
            for source in library.sources where source.enabled && (batch || source.id == selection) {
                if source.id == "shushan", let credential = shushan.credentialForRequests { providers.append(ShushanBookSource(credential:credential)) }
                else if let provider = try? ConfigurableBookSource(source:source) { providers.append(provider) }
                else { reports.append(.init(sourceID:source.id,step:"配置",status:"未运行：需登录或规则未支持",milliseconds:0,count:0)) }
            }
            do {
                let values: [SourceDiagnosticResult]
                if batch { values = try await SourceDiagnostics.batch(sources:providers,query:query,concurrency:concurrency,timeout:timeout) }
                else if let provider = providers.first { values = try await SourceDiagnostics.run(source:provider,query:query,through:step,timeout:timeout) }
                else { values = [] }
                try Task.checkCancellation(); reports += values
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
