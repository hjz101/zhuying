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
    @State private var mode = "分步调试"
    @State private var concurrency = 3
    @State private var timeout = 15.0
    @State private var reports: [SourceDiagnosticResult] = []
    @State private var acceptance: SourceAcceptanceReport?
    @State private var operation: Task<Void, Never>?
    @State private var revision = UUID()
    @State private var busy = false
    @State private var message: String?
    @State private var export: ExportFile?
    private var checkpointStore: SourceAcceptanceStore { SourceAcceptanceStore(directory: library.sourceDiagnosticsDirectory) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: batch ? "批量测试" : "书源调试", subtitle: "搜索 → 详情 → 目录 → 正文 · 实际请求与分步结果", icon: batch ? "checklist" : "ladybug")
                if !batch { NavigationLink("规则兼容测试") { ProductionRuleTesterView() }.accessibilityIdentifier("sourceRuleTester") }
                AppSettingsCard("配置与选项", icon: "slider.horizontal.3") {
                    if !batch {
                        Picker("书源", selection: $selection) { ForEach(library.sources) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("sourceDiagnosticSource")
                        Picker("测试模式", selection: $mode) { Text("分步调试").tag("分步调试"); Text("完整验收").tag("完整验收") }.accessibilityIdentifier("sourceDiagnosticMode")
                        if mode == "分步调试" {
                            Picker("调试步骤", selection: $step) { ForEach(SourceDiagnostics.Step.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.accessibilityIdentifier("sourceDiagnosticStep")
                        } else {
                            Text("两本书各三章。首次检查保存指纹，真正退出并重新启动竹影后，再验证同一组书籍和章节。")
                                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                    }
                    TextField("测试关键词", text: $query).accessibilityIdentifier("sourceDiagnosticQuery")
                    if batch { Picker("并发数量", selection: $concurrency) { ForEach([3, 5, 10], id: \.self) { Text("\($0)") } } }
                    Slider(value: $timeout, in: 5...60, step: 1); Text("每步超时 \(Int(timeout)) 秒").font(.system(size: 11))
                }.disabled(busy)
                Button(busy ? "正在运行" : mode == "完整验收" && !batch ? "开始完整验收" : "运行测试") { run() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("sourceDiagnosticRun")
                if busy { ProgressView(); Button("取消测试") { cancel() }.frame(minHeight: 44).accessibilityIdentifier("sourceDiagnosticCancel") }
                if !batch, mode == "完整验收", let acceptance { acceptanceCard(acceptance) }
                ForEach(reports) { report in resultRow(report) }
                if !reports.isEmpty || acceptance != nil {
                    Button("导出脱敏报告") { exportReport() }.buttonStyle(PrimaryButtonStyle(filled: false)).accessibilityIdentifier("sourceDiagnosticExport")
                }
                if let message { Text(message).font(.system(size: 12)).foregroundStyle(Palette.accent).accessibilityIdentifier("sourceDiagnosticMessage") }
            }.padding(22)
        }.appPageStyle().navigationTitle(batch ? "批量测试" : "书源调试").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if selection.isEmpty { selection = sourceID.flatMap { id in library.sources.contains(where: { $0.id == id }) ? id : nil } ?? library.sources.first?.id ?? "" }
            }
            .task(id: selection) { await loadCheckpoint() }
            .onDisappear { if busy { cancel() } }
            .sheet(item: $export) { file in NativeFileExporter(file: file) { _ in export = nil } }
    }
    private func resultRow(_ report: SourceDiagnosticResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(library.sources.first(where: { $0.id == report.sourceID })?.name ?? "来源")
                Spacer()
                Text("\(report.step) · \(report.status) · \(report.milliseconds) ms · \(report.count)")
            }.font(.system(size: 11))
            if let book = report.bookIndex { Text("第 \(book + 1) 本" + (report.chapterIndex.map { " · 第 \($0 + 1) 章" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(Palette.muted) }
            if let network = report.network {
                Text("原生请求：成功 \(network.successfulFetches) · 失败 \(network.failedFetches)")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if let issue = report.issue {
                Text(issue.message).font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("sourceDiagnosticIssue-" + issue.code.rawValue)
                if let origin = issue.origin { Text(origin).font(.system(size: 11)).textSelection(.enabled) }
                HStack(spacing: 15) {
                    ForEach(issue.recoveries, id: \.rawValue) { recovery in
                        switch recovery {
                        case .login:
                            NavigationLink("登录此书源") { FeatureDemoView(feature: FeatureCatalog.feature("sourceLogin"), scope: report.sourceID) }
                                .accessibilityIdentifier("sourceDiagnosticLogin")
                        case .network:
                            NavigationLink("网络配置") { ProductionNetworkView(initialSourceID: report.sourceID, suggestedOrigin: issue.origin.flatMap(URL.init(string:))) }
                                .accessibilityIdentifier("sourceDiagnosticNetwork")
                        case .rules:
                            NavigationLink("检查规则") { FeatureDemoView(feature: FeatureCatalog.feature("sourceEdit"), scope: report.sourceID) }
                        case .retry:
                            Button("重新调试") { run(source: report.sourceID, target: SourceDiagnostics.Step(rawValue: report.step)) }.disabled(busy)
                                .accessibilityIdentifier("sourceDiagnosticRetry")
                        }
                    }
                }.font(.system(size: 12)).frame(minHeight: 44)
            }
        }.padding(.vertical, 8)
    }
    private func acceptanceCard(_ report: SourceAcceptanceReport) -> some View {
        AppSettingsCard("验收记录", icon: "checklist") {
            Text(report.evidenceKind == .controlledFixture ? "原创测试夹具记录" : "原生网络请求记录").font(.system(size: 12))
            Text(acceptanceStatus(report)).font(.system(size: 13)).accessibilityIdentifier("sourceAcceptanceStatus")
            Text("已核对 \(report.books.count) 本 · \(report.books.reduce(0) { $0 + $1.chapters.count }) 章").font(.system(size: 11))
            if report.canVerifyRestart {
                Button("重启后验证") { run(restart: true) }
                    .buttonStyle(PrimaryButtonStyle(filled: false))
                    .disabled(busy || report.initialProcessID == SourceDiagnosticProcess.id || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("sourceAcceptanceVerifyRestart")
                if report.initialProcessID == SourceDiagnosticProcess.id { Text("请真正退出并重新启动竹影，再输入相同关键词验证。").font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }
            Text("记录只证明已检查的规则返回和原生请求；不代表其他作品或全部脚本能力均已通过。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
    private func acceptanceStatus(_ report: SourceAcceptanceReport) -> String {
        switch report.status {
        case .failed: "完整验收未完成"
        case .awaitingRestart: "首次检查完成，等待真正重启"
        case .verificationFailed: "重启复核未完成，可处理问题后重试"
        case .restartVerified: report.evidenceKind == .controlledFixture ? "测试夹具已通过跨进程重启复核" : "已通过两书六章及跨进程重启复核"
        }
    }
    private func context(_ source: DemoSource) throws -> (SourceDiagnosticScope, LegadoAuthStatus?, SourceDiagnosticEvidenceKind) {
        let profile = (library.isDemo ? "demo:" : "production:") + library.sourceDiagnosticsDirectory.path
        var scope = SourceDiagnosticScope(sourceID: source.id, libraryProfile: profile)
        var auth: LegadoAuthStatus?
        if (try? SourcePackages.legadoDefinition(source)) != nil {
            let state = try library.legadoLoginState(for: source)
            scope = .init(sourceID: source.id, accountID: state.scope.accountID, libraryProfile: state.scope.libraryProfile)
            scope.sessionEpoch = state.sessionRevision
            auth = state.authStatus
        } else if source.id == "shushan" {
            scope.accountID = shushan.credentialForRequests.map { StableContentID.make($0.host.absoluteString, $0.apiKey) } ?? "signed-out"
            auth = shushan.expired ? .expired : shushan.credentialForRequests == nil ? .signedOut : .verified
        }
        scope.configurationHash = StableContentID.make(source.configuration?.base64EncodedString() ?? "", source.url)
        var kind = SourceDiagnosticEvidenceKind.nativeNetwork
        #if DEBUG
        if LegadoDevelopmentFixtures.isEnabled(source) || SourceDiagnosticDevelopmentFixtures.isEnabled(source) { kind = .controlledFixture }
        #endif
        return (scope, auth, kind)
    }
    private func loadCheckpoint() async {
        guard !batch, !busy, let source = library.sources.first(where: { $0.id == selection }) else { return }
        acceptance = nil
        let selected = selection
        do {
            let (scope, _, _) = try context(source)
            let saved = try await checkpointStore.load(scope: scope)
            guard selection == selected, !busy else { return }
            acceptance = saved
        } catch { if selection == selected { message = SourceDiagnosticIssue.classify(error).message } }
    }
    private func cancel() {
        guard busy else { return }
        operation?.cancel(); revision = UUID(); busy = false
        let issue = SourceDiagnosticIssue(code: .cancelled)
        reports.append(SourceDiagnostics.result(sourceID: selection, step: "取消", start: ProcessInfo.processInfo.systemUptime, issue: issue))
        message = issue.message
    }
    private func run(source override: String? = nil, target: SourceDiagnostics.Step? = nil, restart: Bool = false) {
        operation?.cancel()
        if let override { selection = override }
        let token = UUID(); revision = token; busy = true; reports = []; message = nil
        let currentMode = mode, baseline = acceptance, selectedID = selection
        operation = Task { @MainActor in
            defer { if revision == token { busy = false; operation = nil } }
            var providers: [any BookSource] = [], configuration: [SourceDiagnosticResult] = []
            var authStatuses: [String: LegadoAuthStatus] = [:]
            for source in library.sources where source.enabled && (batch || source.id == selectedID) {
                do {
                    let (_, auth, _) = try context(source)
                    providers.append(try library.configuredDiagnosticBookSource(source, credential: shushan.credentialForRequests))
                    if let auth { authStatuses[source.id] = auth }
                }
                catch {
                    let auth = (try? context(source))?.1
                    configuration.append(SourceDiagnostics.result(sourceID: source.id, step: "配置", start: ProcessInfo.processInfo.systemUptime, issue: .classify(error, authStatus: auth)))
                }
            }
            reports = configuration
            do {
                if !batch && (currentMode == "完整验收" || restart) {
                    guard let source = library.sources.first(where: { $0.id == selectedID }), let provider = providers.first else { return }
                    let (scope, auth, kind) = try context(source)
                    let report = try await SourceAcceptanceRunner.run(source: provider, query: query, scope: scope, evidenceKind: kind, timeout: timeout,
                        authStatus: auth, baseline: restart ? baseline : nil) { rows in
                        await MainActor.run { if revision == token { reports = configuration + rows } }
                    }
                    try Task.checkCancellation(); guard revision == token else { return }
                    try await checkpointStore.save(report, scope: scope); acceptance = report
                    message = report.issue?.message ?? acceptanceStatus(report)
                } else {
                    let values: [SourceDiagnosticResult]
                    if batch { values = try await SourceDiagnostics.batch(sources: providers, query: query, concurrency: concurrency, timeout: timeout, authStatuses: authStatuses) }
                    else if let provider = providers.first {
                        let auth = library.sources.first(where: { $0.id == selectedID }).flatMap { (try? context($0))?.1 }
                        values = try await SourceDiagnostics.run(source: provider, query: query, through: target ?? step, timeout: timeout, authStatus: auth)
                    } else {
                        values = configuration.isEmpty ? [SourceDiagnostics.result(sourceID: selectedID, step: "配置", start: ProcessInfo.processInfo.systemUptime, issue: .init(code: .sourceDisabled))] : []
                    }
                    try Task.checkCancellation(); if revision == token { reports = configuration + values }
                }
            } catch is CancellationError {
                if revision == token { message = SourceDiagnosticIssue(code: .cancelled).message }
            } catch {
                if revision == token {
                    let issue = SourceDiagnosticIssue.classify(error)
                    reports.append(SourceDiagnostics.result(sourceID: selectedID, step: restart ? "重启复核" : "完整验收", start: ProcessInfo.processInfo.systemUptime, issue: issue))
                    message = issue.message
                }
            }
        }
    }
    private func exportReport() {
        do {
            let bytes: Data
            if mode == "完整验收", let acceptance { bytes = try SourceAcceptanceRunner.export(acceptance) }
            else { bytes = try SourceDiagnostics.export(reports) }
            export = try ExportFile.prepare(bytes, filename: "竹影书源检测报告.json")
        } catch { message = SourceDiagnosticIssue(code: .stateUnavailable).message }
    }
}
