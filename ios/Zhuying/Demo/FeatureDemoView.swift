import SwiftUI

struct DemoNotice: View {
    var body: some View {
        Label("界面演示 · 示例数据，本页不连接外部服务", systemImage: "rectangle.dashed.badge.record")
            .font(.system(size: 10)).foregroundStyle(Palette.muted).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.green.opacity(0.05), in: .rect(cornerRadius: 10))
    }
}

struct FeatureHubView: View {
    var sourceOnly = false
    var body: some View {
        Group {
            if sourceOnly { SourceManagementView() }
            else { ToolboxView() }
        }
    }
}

struct FeatureRow: View {
    @EnvironmentObject private var library: LibraryStore
    let feature: DemoFeature
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: feature.icon).font(.system(size: 18)).foregroundStyle(Palette.green).frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(feature.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.green)
                Text(library.isDemo ? feature.summary : ProductionCapabilities.summary(for:feature)).font(.system(size: 10)).foregroundStyle(Palette.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct FeatureDemoView: View {
    let feature: DemoFeature
    var bookID: String? = nil
    var scope = "main"
    var onRead: ((Book, Int, Int, Int) -> Void)? = nil
    @EnvironmentObject private var demo: FeatureDemoStore
    @EnvironmentObject private var library: LibraryStore
    @State private var filePreview: DemoFile?
    @State private var confirmAction: String?
    private var book: Book { library.books.first { $0.id == bookID } ?? library.books[0] }
    private var outcomeKey: String { "\(feature.id):\(scope)" }

    var body: some View {
        Group {
            if feature.id == "import" || (!library.isDemo && ["epub", "txt"].contains(feature.id)) { SmartImportView() }
            else if !library.isDemo && ["details","contents","reading"].contains(feature.id) { ProductionBookToolView(feature:feature,bookID:bookID) }
            else if !library.isDemo && feature.id == "fulltext" { ProductionTextSearchView(bookID: bookID, onRead: onRead) }
            else if !library.isDemo && feature.id == "statistics" { FootprintsView(title: feature.title) }
            else if !library.isDemo && feature.id == "links" { ShareImportView() }
            else if !library.isDemo && feature.id == "pdf" { ProductionMediaLibrary(kind:.pdf) }
            else if !library.isDemo && feature.id == "comic" { ProductionMediaLibrary(kind:.comic) }
            else if !library.isDemo && feature.id == "archive" { ProductionArchiveView() }
            else if !library.isDemo && feature.id == "covers" { ProductionCoverSearchView(bookID:bookID) }
            else if !library.isDemo && feature.id == "icloud" { ProductionCloudView() }
            else if !library.isDemo && feature.id == "engine" { ProductionRuleTesterView() }
            else if !library.isDemo && feature.id == "purify" { ProductionContentRulesView() }
            else if !library.isDemo && feature.id == "browser" { ProductionBrowserView() }
            else if !library.isDemo && feature.id == "backend" { ProductionBackendView() }
            else if !library.isDemo && feature.id == "network" { ProductionNetworkView() }
            else if !library.isDemo && feature.id == "aiConfig" { ProductionAudioServiceView() }
            else if !library.isDemo && feature.id == "aiRoles" { ProductionRolesView(bookID:bookID) }
            else if !library.isDemo && ["systemTTS","onlineTTS","backgroundAudio"].contains(feature.id) { ProductionNarrationView(bookID:bookID,mode:feature.id == "backgroundAudio" ? nil : feature.id == "onlineTTS" ? .online : .system,title:feature.title) }
            else if feature.id == "themes" { ThemeLibraryView() }
            else if feature.id == "fonts" { ReadingFontManagerView() }
            else if feature.id == "typography" { ReadingTypographyPreferencesView().navigationTitle(feature.title) }
            else if feature.id == "pageStyle" { ReadingOperationPreferencesView().navigationTitle(feature.title) }
            else if feature.id == "titleDesign" { ReadingTitlePreferencesView().navigationTitle(feature.title) }
            else if feature.id == "highlight" { ReadingStyleRulesView().navigationTitle(feature.title) }
            else if feature.id == "comments" { ReadingCommentsPreferencesView().navigationTitle(feature.title) }
            else if !library.isDemo && feature.id == "sourceLogin" && scope == "shushan" { ShushanLoginView() }
            else if !library.isDemo && feature.id == "sourceLogin" { LegadoSourceLoginRoute(sourceID: scope) }
            else if !library.isDemo && feature.id == "sourceEdit" && (scope == "shushan" || (scope == "main" && library.sources.first?.id == "shushan")) { SourceConfigurationView(sourceID:"shushan") }
            else if !library.isDemo && feature.id == "sourceEdit" { ProductionSourceRuleEditor(sourceID: scope == "main" ? library.sources.first?.id ?? scope : scope) }
            else if !library.isDemo && feature.id == "sourceImport" { ProductionSourceImportView() }
            else if !library.isDemo && feature.id == "sourceSwitch" { ProductionSourceSwitchView(bookID:bookID) }
            else if !library.isDemo && feature.id == "sourceDebug" { ProductionSourceDiagnosticsView(sourceID:scope) }
            else if !library.isDemo && feature.id == "sourceBatch" { ProductionSourceDiagnosticsView(batch:true) }
            else if !library.isDemo && feature.id == "discover" { ProductionSubscriptionsView() }
            else if !library.isDemo && feature.id == "search" { DiscoverView(searchEntry: true) }
            else if !library.isDemo && feature.id == "shelf" { ProductionGroupsView() }
            else if !library.isDemo && feature.id == "bookmarks" { ProductionBookmarksView(bookID: bookID) }
            else if !library.isDemo && ["history", "progress"].contains(feature.id) { ReadingHistoryView() }
            else if !library.isDemo && feature.id == "backup" { ProductionBackupView() }
            else if !library.isDemo && feature.id == "cache" { ProductionCacheView(bookID: bookID) }
            else if !library.isDemo && feature.id == "chapterCache" { ProductionDownloadView(bookID:bookID) }
            else if !library.isDemo && feature.id == "files" { ProductionFilesView() }
            else if !library.isDemo {
                ContentUnavailableView(feature.title, systemImage: feature.icon, description: Text("当前版本暂不支持此功能。"))
                    .appPageStyle().navigationTitle(feature.title)
            }
            else { demoBody }
        }
    }

    @ViewBuilder private var demoBody: some View {
        if feature.id == "sourceImport" {
            SourceImportView()
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                AppPageHeader(title: feature.title, subtitle: feature.summary, icon: feature.icon)
                DemoNotice()
                if let source = demo.sources.first(where: { $0.id == scope }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("当前书源：\(source.name)").font(.system(size: 14, weight: .medium)).accessibilityIdentifier("currentSourceName")
                        Text(source.url).font(.system(size: 11)).foregroundStyle(Palette.muted)
                        Text("\(source.loginStatus.title) · 演示状态").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }
                if !feature.fields.isEmpty {
                    AppSettingsCard("配置与选项", icon: "slider.horizontal.3") {
                        ForEach(feature.fields) { field in fieldView(field) }
                    }
                }
                preview
                if let outcome = demo.outcomes[outcomeKey] {
                    VStack(alignment: .leading, spacing: 9) {
                        Label(outcome.title, systemImage: outcome.success ? "checkmark.circle" : "exclamationmark.circle").font(.system(size: 13, weight: .medium))
                        Text(outcome.detail).font(.system(size: 12)).lineSpacing(6).textSelection(.enabled)
                    }.foregroundStyle(outcome.success ? Palette.green : Palette.accent).padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Palette.green.opacity(0.06), in: .rect(cornerRadius: 12)).accessibilityIdentifier("demoOutcome").id("demo-result")
                }
                ForEach(feature.actions, id: \.self) { action in
                    Button(action) {
                        if action == "打开原生阅读器" || action == "切换并继续阅读" { open(book, library.progress[book.id]?.chapter ?? 0, library.progress[book.id]?.paragraph ?? 0, library.progress[book.id]?.characterOffset ?? 0) }
                        else if action == "打开示例 PDF" { filePreview = .init(name: "山海图志.pdf", detail: "12 页示例") }
                        else if action == "打开示例漫画" { filePreview = .init(name: "山间来信.cbz", detail: "原创布局预览") }
                        else if action.contains("恢复") || action.contains("清理") { confirmAction = action }
                        else { demo.execute(action, feature: feature, scope: scope, book: book, library: library) }
                    }.buttonStyle(PrimaryButtonStyle(filled: action == feature.actions.first)).accessibilityIdentifier("demo-action-\(feature.id)-\(action)")
                }
                if !feature.related.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "相关功能")
                        ForEach(feature.related, id: \.self) { id in
                            NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature(id), bookID: book.id, scope: scope, onRead: onRead) } label: { FeatureRow(feature: FeatureCatalog.feature(id)) }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(22)
        }
        .onChange(of: demo.outcomes[outcomeKey]?.detail) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("demo-result", anchor: .center) }
        }
        }
        .appPageStyle().navigationTitle(feature.title).navigationBarTitleDisplayMode(.inline)
        .onAppear { demo.prepareSource(feature, scope: scope) }
        .sheet(item: $filePreview) { item in DemoFilePreview(file: item) }
        .confirmationDialog("\(confirmAction ?? "")？", isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }), titleVisibility: .visible) {
            Button("确认演示") {
                if let action = confirmAction { demo.execute(action, feature: feature, scope: scope, book: book, library: library) }
                confirmAction = nil
            }
        } message: { Text("仅更改演示数据，不影响真实文件和阅读记录。") }
    }

    private func binding(_ field: DemoField) -> Binding<String> {
        Binding(get: { demo.value(feature, field, scope: scope) }, set: { demo.set($0, feature: feature, field: field, scope: scope) })
    }
    private func text(_ id: String) -> String { demo.text(feature, id, scope: scope) }
    @ViewBuilder private func fieldView(_ field: DemoField) -> some View {
        let value = binding(field)
        switch field.kind {
        case .toggle:
            Toggle(field.title, isOn: Binding(get: { value.wrappedValue == "true" }, set: { value.wrappedValue = String($0) })).font(.system(size: 13)).tint(Palette.green)
        case .choice(let options):
            let choices = feature.id == "shelf" && field.id == "group" ? ["全部"] + Array(Set(demo.groups + Array(library.importedGroups.values))).sorted() : options
            HStack {
                Text(field.title).font(.system(size: 12))
                Spacer(minLength: 8)
                Picker(field.title, selection: value) { ForEach(choices, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().accessibilityIdentifier("demo-field-\(field.id)").font(.system(size: 13)).tint(Palette.green)
            }
        case .slider(let min, let max, let unit):
            VStack(spacing: 6) {
                HStack { Text(field.title); Spacer(); Text("\(value.wrappedValue) \(unit)").foregroundStyle(Palette.muted) }.font(.system(size: 12))
                Slider(value: Binding(get: { Double(value.wrappedValue) ?? min }, set: { value.wrappedValue = String(format: "%.1f", $0) }), in: min...max).tint(Palette.green).accessibilityLabel(field.title)
            }
        case .code:
            VStack(alignment: .leading, spacing: 9) {
                Text(field.title).font(.system(size: 12, weight: .medium))
                TextEditor(text: value).font(.system(size: 11, design: .monospaced)).frame(height: 150).padding(8).scrollContentBackground(.hidden).background(Palette.background, in: .rect(cornerRadius: 8)).accessibilityLabel(field.title).accessibilityIdentifier("demo-field-\(field.id)")
            }
        case .text, .secret:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title).font(.system(size: 12, weight: .medium))
                if case .secret = field.kind {
                    SecureField("仅输入演示占位内容", text: value).textContentType(.none).padding(12).background(Palette.background, in: .rect(cornerRadius: 8))
                } else {
                    TextField(field.title, text: value, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).background(Palette.background, in: .rect(cornerRadius: 8)).accessibilityIdentifier("demo-field-\(field.id)")
                }
            }.font(.system(size: 12))
        }
    }

    @ViewBuilder private var preview: some View {
        switch feature.preview {
        case .books:
            let selected = feature.id == "shelf" ? library.shelf : library.books.filter { text("category").isEmpty || text("category") == "全部" || $0.category == text("category") }
            VStack(spacing: 18) {
                ForEach(selected.filter { feature.id != "shelf" || text("group") == "全部" || (library.importedGroups[$0.id] ?? demo.bookGroups[$0.id]) == text("group") }) { item in
                    HStack {
                        NavigationLink { BookDetailView(book: item) } label: { BookRow(book: item) }.buttonStyle(.plain)
                        if feature.id == "shelf" {
                            Menu { ForEach(demo.groups, id: \.self) { group in Button(group) {
                                if item.id.hasPrefix("local-") { library.moveImportedBook(item.id, group: group) }
                                else { demo.bookGroups[item.id] = group }
                            } } } label: { Image(systemName: "folder.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("移动\(item.title)分组")
                        }
                    }
                }
                if selected.filter({ feature.id != "shelf" || text("group") == "全部" || (library.importedGroups[$0.id] ?? demo.bookGroups[$0.id]) == text("group") }).isEmpty { Text("当前分组暂无作品").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        case .search:
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("\(demo.sources.filter(\.enabled).count) 个来源 · 模拟并发完成"); Spacer(); Text(text("merge") == "true" ? "已聚合去重" : "按来源展示") }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                ForEach(library.search(text("query"))) { item in
                    NavigationLink { BookDetailView(book: item) } label: { BookRow(book: item) }.buttonStyle(.plain)
                    if text("merge") == "false" {
                        ForEach(demo.sources.filter(\.enabled)) { source in Text("\(item.title) · \(source.name)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    }
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceSwitch"), bookID: item.id, onRead: onRead) } label: { Label("查看 \(demo.sources.filter(\.enabled).count) 个来源", systemImage: "square.stack").font(.system(size: 12)) }
                }
                if library.search(text("query")).isEmpty { ContentUnavailableView.search(text: text("query")) }
            }
        case .fulltext:
            let matches = demo.fulltext(text("query"), books: text("scope") == "当前书籍" ? [book] : text("scope") == "本地示例书" ? Array(library.books.prefix(2)) : library.books)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "正文命中", subtitle: "\(matches.count) 处")
                ForEach(matches.prefix(20)) { hit in
                    Button { if let item = library.books.first(where: { $0.id == hit.bookID }) { open(item, hit.chapter, hit.paragraph, hit.offset) } } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(library.books.first { $0.id == hit.bookID }!.title) · 第\(hit.chapter + 1)章").font(.system(size: 12, weight: .medium))
                            Text(highlighted(hit.text)).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).lineLimit(3)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: .rect(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityIdentifier("hit-\(hit.id)")
                }
                if matches.isEmpty { Text("没有命中，试试“地图”“风”或“信”。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        case .sourceSwitch:
            VStack(alignment: .leading, spacing: 13) {
                Text("《\(book.title)》").font(.system(size: 18, design: .serif))
                Text("切换演示来源时，保留现有章节与正文位置。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                ForEach(demo.sources) { source in
                    Button { demo.switchSource(source.id, book: book) } label: {
                        HStack { VStack(alignment: .leading, spacing: 7) { Text(source.name); Text(source.detail).font(.system(size: 10)).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName: (demo.bookSources[book.id] ?? "shanhai") == source.id ? "checkmark.circle.fill" : "circle") }.font(.system(size: 13)).padding(16).background(.white.opacity(0.7), in: .rect(cornerRadius: 10))
                    }.disabled(!source.enabled).accessibilityIdentifier("candidate-\(source.id)")
                        .accessibilityValue((demo.bookSources[book.id] ?? "shanhai") == source.id ? "当前来源" : "可选来源")
                }
                Button("使用所选来源继续阅读") { open(book, library.progress[book.id]?.chapter ?? 0, library.progress[book.id]?.paragraph ?? 0, library.progress[book.id]?.characterOffset ?? 0) }.buttonStyle(PrimaryButtonStyle())
            }
        case .sources: DemoSourceList(scope: feature.id == "sources" ? "manage" : "preview", group: feature.id == "sources" ? text("group") : "全部")
        case .contents:
            VStack(spacing: 0) {
                ForEach(text("order") == "倒序" ? Array(book.chapters.indices.reversed()) : Array(book.chapters.indices), id: \.self) { index in
                    if text("query").isEmpty || book.chapterTitle(index).contains(text("query")) {
                        Button { open(book, index) } label: {
                            HStack { Text(book.chapterTitle(index)); Spacer(); if library.progress[book.id]?.chapter == index { Text("当前").foregroundStyle(Palette.accent) } }.font(.system(size: 12)).padding(.vertical, 16)
                        }; Divider()
                    }
                }
            }
        case .bookmarks:
            VStack(spacing: 13) {
                ForEach(demo.bookmarks.filter { bookID == nil || $0.bookID == book.id }) { mark in
                    if let item = library.books.first(where: { $0.id == mark.bookID }) {
                        HStack {
                            Button { open(item, mark.chapter, mark.paragraph, mark.offset) } label: {
                                VStack(alignment: .leading, spacing: 7) { Text(item.title).font(.system(size: 15, design: .serif)); Text(item.chapterTitle(mark.chapter)).font(.system(size: 11)); Text(item.content[mark.chapter][mark.paragraph]).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { demo.bookmarks.removeAll { $0.id == mark.id } } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("删除书签")
                        }.padding(14).background(.white.opacity(0.7), in: .rect(cornerRadius: 12))
                    }
                }
                if demo.bookmarks.isEmpty { Text("暂无书签，可添加当前位置。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            }
        case .paper: feature.id == "themes" ? AnyView(ThemeLibraryView()) : AnyView(paperPreview)
        case .files:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(demo.files) { file in
                    HStack {
                        Button { filePreview = file } label: { Label { VStack(alignment: .leading, spacing: 6) { Text(file.name).font(.system(size: 13)); Text(file.detail).font(.system(size: 10)).foregroundStyle(Palette.muted) } } icon: { Image(systemName: file.name.hasSuffix("pdf") ? "doc.richtext" : "doc") }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        Button { demo.files.removeAll { $0.id == file.id } } label: { Image(systemName: "trash").frame(width: 38, height: 44) }.accessibilityLabel("删除演示文件")
                    }.padding(13).background(.white.opacity(0.7), in: .rect(cornerRadius: 10))
                }
                if feature.id == "comic" { Button("打开漫画样式预览") { filePreview = .init(name: "山间来信.cbz", detail: "原创示意漫画") }.buttonStyle(PrimaryButtonStyle(filled: false)) }
            }
        case .player: DemoPlayerCard()
        case .roles:
            VStack(spacing: 12) { ForEach(["旁白 · 温柔女声", "陆青崖 · 少年男声", "老掌柜 · 长者男声"], id: \.self) { role in Label(role, systemImage: "person.wave.2").font(.system(size: 13)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: .rect(cornerRadius: 10)) } }
        case .rules: DemoRulesPreview(feature: feature, scope: scope)
        case .canvas: DemoTitleCanvas(title: text("title"))
        case .comments: DemoCommentsPreview(skin: text("skin"), opacity: (Double(text("opacity")) ?? 90) / 100)
        case .backup:
            VStack(spacing: 13) { ForEach(demo.backups, id: \.self) { item in Label(item, systemImage: feature.id == "icloud" ? "icloud" : "archivebox").font(.system(size: 12)).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: .rect(cornerRadius: 10)) } }
        case .stats: DemoStatsPreview(period: text("period"), byBook: text("dimension") == "按书籍")
        case .cache:
            VStack(alignment: .leading, spacing: 15) {
                ForEach(["章节", "图片", "音频"], id: \.self) { type in HStack { Label(type, systemImage: type == "音频" ? "waveform" : type == "图片" ? "photo" : "doc.text"); Spacer(); Text(String(format: "%.1f MB", demo.cacheMB[type] ?? 0)) }.font(.system(size: 12)) }
                ProgressView(value: demo.downloadProgress).tint(Palette.green)
                Text(demo.downloadPaused ? "演示队列 · 已暂停" : "演示队列 · 下载完成").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(18).background(.white.opacity(0.7), in: .rect(cornerRadius: 12))
        case .browser:
            VStack(alignment: .leading, spacing: 18) {
                let source = demo.sources.first { $0.id == scope }
                Label(source.map { $0.url + "/login" } ?? (text("url").isEmpty ? "https://books.example/login" : text("url")), systemImage: "lock").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(source?.name ?? "山海书库").font(.system(size: 30, design: .serif))
                Text("这是本地网页占位预览，表单和 Cookie 状态由演示数据呈现。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                if feature.id != "sourceLogin" {
                    NavigationLink { FeatureDemoView(feature: FeatureCatalog.feature("sourceLogin"), scope: scope) } label: { Label("打开登录流程", systemImage: "person.circle") }
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.7), in: .rect(cornerRadius: 15))
        case .covers:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                ForEach(library.books.prefix(6)) { item in Button { demo.selectedCover = item.id } label: { BookCover(book: item, width: 126).overlay(alignment: .bottomTrailing) { if demo.selectedCover == item.id { Image(systemName: "checkmark.circle.fill").padding(8).foregroundStyle(.white).background(Palette.green, in: Circle()) } } }.buttonStyle(.plain) }
            }
        }
    }

    private var paperPreview: some View {
        let size = Double(text("size")) ?? 20
        let dark = text("app") == "深色" || text("paper") == "夜读"
        let font: Font.Design = text("font") == "圆体" ? .rounded : text("font") == "系统黑体" ? .default : .serif
        return VStack(alignment: .leading, spacing: CGFloat(Double(text("paragraph")) ?? 18)) {
            Text(book.title).font(.system(size: 10)).opacity(0.5)
            Text("第三章 山雨欲来").font(.system(size: 24, weight: .medium, design: .serif))
            Text((text("indent") == "false" ? "" : "　　") + book.content[2][0]).font(.system(size: size, weight: text("weight") == "粗体" ? .bold : text("weight") == "中等" ? .medium : text("weight") == "细体" ? .light : .regular, design: font)).lineSpacing(Double(text("line")) ?? 9).multilineTextAlignment(text("align") == "居中" ? .center : .leading)
            Text("第 \(demo.values["previewPage"] ?? "1") / 12 页 · 样式预览").font(.system(size: 9)).opacity(0.5)
        }.padding(CGFloat(Double(text("margin")) ?? 22)).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(dark ? Color(hex: 0xC5CCB5) : Palette.green).background(dark ? Color(hex: 0x26382E) : text("paper") == "纯白" ? .white : Color(hex: 0xEDE8D9), in: .rect(cornerRadius: 15))
    }
    private func open(_ item: Book, _ chapter: Int, _ paragraph: Int = 0, _ offset: Int = 0) {
        if let onRead { onRead(item, chapter, paragraph, offset) }
        else { library.record(item, chapter: chapter, paragraph: paragraph, characterOffset: offset); library.read(item, chapter: chapter) }
    }
    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        if let range = result.range(of: self.text("query"), options: .caseInsensitive) {
            result[range].backgroundColor = Color(hex: 0xDFE3BC)
            result[range].foregroundColor = Palette.green
        }
        return result
    }
}


private struct ProductionBookToolView: View {
    let feature: DemoFeature
    var bookID: String?
    @EnvironmentObject private var library: LibraryStore
    @State private var catalogBook: Book?
    var body: some View {
        Group {
            if feature.id == "details",let book = library.books.first(where:{$0.id == bookID}) { BookDetailView(book:book) }
            else {
                ScrollView { VStack(alignment:.leading,spacing:23) {
                    AppPageHeader(title:feature.title,subtitle:"选择已导入或已加入的作品",icon:feature.icon)
                    if library.books.isEmpty {
                        Text("尚无作品，请先导入文件或搜索书籍。").font(.system(size:13)).foregroundStyle(Palette.muted).accessibilityIdentifier("bookToolEmpty")
                        NavigationLink("智能导入") { SmartImportView() }
                    }
                    ForEach(library.books) { book in
                        if feature.id == "details" { NavigationLink { BookDetailView(book:book) } label: { entry(book) }.accessibilityIdentifier("production-book-" + book.id) }
                        else { Button { if feature.id == "contents" { catalogBook = book } else { library.read(book) } } label: { entry(book) }.accessibilityIdentifier("production-book-" + book.id) }
                    }
                }.padding(22) }.appPageStyle().navigationTitle(feature.title).navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item:$catalogBook) { book in
            ContentsView(book:book,currentChapter:library.progress[book.id]?.chapter) { chapter in
                catalogBook = nil
                Task { @MainActor in try? await Task.sleep(for:.milliseconds(350)); library.read(book,chapter:chapter) }
            }
        }
    }
    private func entry(_ book: Book) -> some View {
        HStack(spacing:14) { BookCover(book:book,width:48); VStack(alignment:.leading,spacing:6) { Text(book.title).font(.system(size:15)); Text(book.author).font(.system(size:11)).foregroundStyle(Palette.muted) }; Spacer(); Image(systemName:"chevron.right").font(.system(size:11)) }.foregroundStyle(Palette.green).padding(16).background(Palette.card,in:.rect(cornerRadius:12))
    }
}
