import SwiftUI
import AVFoundation

struct ProductionNarrationView: View {
    var bookID: String? = nil
    var mode: NarrationMode? = .system
    var title: String? = nil
    @EnvironmentObject private var library: LibraryStore
    var body: some View { NarrationPanel(audio:library.audio,bookID:bookID,mode:mode ?? library.audio.mode,title:title) }
}

private struct NarrationPanel: View {
    @Environment(\.themeAppearance) private var appAppearance
    @ObservedObject var audio: LibraryAudioCoordinator
    let bookID: String?
    let mode: NarrationMode
    let title: String?
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var profiles: [AudioServiceProfile] = []
    @State private var message: String?
    private var isCurrent: Bool { audio.state.bookID == selection && audio.mode == mode }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:title ?? mode.rawValue,subtitle:"真实发声 · 暂停继续 · 跨章 · 正文跟随",icon:"speaker.wave.2")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("作品",selection:$selection) { Text("请选择作品").tag(""); ForEach(library.books) { Text($0.title).tag($0.id) } }
                    if mode == .system {
                        Picker("声音",selection:$library.narrationSettings.voiceID) { Text("自动选择当前语言").tag(""); ForEach(voices,id:\.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) } }
                    } else {
                        Picker("兼容服务",selection:$library.narrationSettings.profileID) { Text("请选择已保存服务").tag(String?.none); ForEach(profiles) { Text($0.name).tag(Optional($0.id)) } }
                        NavigationLink { ProductionAudioServiceView() } label: { ThemeLabel("配置在线服务",systemImage:"key") }
                    }
                    Slider(value:$library.narrationSettings.speed,in:0.5...2,step:0.1)
                    Text("语速 \(library.narrationSettings.speed, specifier:"%.1f")×").font(.system(size:12))
                    Toggle("跟随正文位置",isOn:$library.narrationSettings.followsReader)
                }
                AppSettingsCard("播放器",icon:"waveform") {
                    ThemeIcon(systemName:"waveform").font(.system(size:38,weight:.ultraLight)).frame(maxWidth:.infinity)
                    Text(audio.state.title.isEmpty ? "还没有开始朗读" : audio.state.title).font(.system(size:23,design:.serif)).frame(maxWidth:.infinity)
                    Text(audio.state.chapterTitle).font(.system(size:12)).foregroundStyle(appAppearance.palette.muted).frame(maxWidth:.infinity)
                    ProgressView(value:audio.state.fraction).tint(appAppearance.palette.primary)
                    Text(phase(audio.state.phase)).font(.system(size:12)).frame(maxWidth:.infinity).accessibilityIdentifier("narrationStatus")
                    HStack(spacing:24) {
                        Button { audio.previous() } label: { ThemeIcon(systemName:"backward.end.fill") }.accessibilityLabel("上一章朗读")
                        Button { toggle() } label: { ThemeIcon(systemName:isCurrent && audio.state.phase == .playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size:42)) }
                            .accessibilityLabel(isCurrent && audio.state.phase == .playing ? "暂停朗读" : "开始或继续朗读").accessibilityIdentifier("narrationPlay").disabled(selection.isEmpty)
                        Button { audio.next() } label: { ThemeIcon(systemName:"forward.end.fill") }.accessibilityLabel("下一章朗读")
                    }.frame(maxWidth:.infinity).frame(minHeight:60)
                    Button("停止朗读") { audio.stop() }.frame(maxWidth:.infinity,minHeight:44).accessibilityIdentifier("narrationStop")
                    if let quote = audio.state.anchor?.quote { Text(quote).font(.system(size:12)).lineSpacing(5) }
                }
                if library.books.isEmpty { ThemeUnavailableView("还没有可朗读的作品",systemImage:"book",description:Text("先导入作品，或打开可阅读的网络章节。")) }
                if let error = audio.state.message ?? message { Text(error).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("narrationMessage") }
                Text(mode == .system ? "暂停保留当前词位置，退出阅读页后可继续。手动阅读与朗读位置分别保存；开启跟随时更新当前正文。朗读单独计时，播放中不重复累计阅读时长。" : "在线音频按短片段缓冲与恢复，重启会重放当前片段；缓冲不计为播放。跨章需要可读正文和有效服务额度。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
                if mode == .roles { NavigationLink { ProductionRolesView(bookID:selection) } label: { FeatureRow(feature:FeatureCatalog.feature("aiRoles")) } }
            }.padding(22)
        }.appPageStyle().navigationTitle(title ?? mode.rawValue).navigationBarTitleDisplayMode(.inline)
            .onAppear { selection = bookID ?? library.history.first?.id ?? library.books.first?.id ?? ""; if mode == .system { voices = AVSpeechSynthesisVoice.speechVoices().sorted { $0.language + $0.name < $1.language + $1.name } }; refreshProfiles() }
    }
    private func refreshProfiles() { do { profiles = try audio.services().profiles } catch { message = error.localizedDescription } }
    private func toggle() {
        do {
            if isCurrent && audio.state.phase == .playing { audio.pause() }
            else if isCurrent && audio.state.phase == .paused { audio.resume() }
            else if isCurrent && audio.state.phase == .buffering { audio.pause() }
            else { try audio.start(bookID:selection,mode:mode) }
        } catch { message = error.localizedDescription }
    }
    private func phase(_ phase: NarrationPhase) -> String {
        switch phase { case .idle:"尚未播放";case .buffering:"正在缓冲，尚未播放";case .playing:"\(audio.mode.rawValue) · 正在播放";case .paused:"已暂停，位置保留";case .failed:"播放未完成，位置保留";case .completed:"已朗读完全部章节" }
    }
}

struct ProductionMiniPlayer: View {
    @Environment(\.themeAppearance) private var appAppearance
    @ObservedObject var audio: LibraryAudioCoordinator
    let open: () -> Void
    var reader = false
    var readerBookID: String? = nil
    var follow: (() -> Void)? = nil
    var body: some View {
        if ![.idle,.completed].contains(audio.state.phase) {
            HStack(spacing:15) {
                Button(action:open) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(audio.state.title).lineLimit(1)
                            Text(audio.state.phase == .playing ? "正在朗读 · " + audio.state.chapterTitle : audio.state.phase == .buffering ? "正在缓冲" : audio.state.phase == .paused ? "朗读已暂停" : "朗读未完成，点击查看")
                                .lineLimit(1).font(.system(size: 10))
                        }
                    } icon: { ThemeIcon(systemName:"waveform") }
                        .font(.system(size:11)).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                }.accessibilityLabel("打开朗读播放器，" + audio.state.title).accessibilityIdentifier("miniPlayerOpen")
                if reader && readerBookID == audio.state.bookID && audio.readerDetached {
                    Button { audio.returnToNarration(); follow?() } label: { ThemeIcon(systemName:"text.line.first.and.arrowtriangle.forward").frame(width:44,height:44) }
                        .accessibilityLabel("返回朗读位置").accessibilityIdentifier("miniPlayerFollow")
                }
                Button { audio.state.phase == .playing || audio.state.phase == .buffering ? audio.pause() : audio.resume() } label: { ThemeIcon(systemName:audio.state.phase == .playing || audio.state.phase == .buffering ? "pause.fill" : "play.fill").frame(width:44,height:44) }
                    .accessibilityLabel(audio.state.phase == .playing || audio.state.phase == .buffering ? "暂停朗读" : "继续朗读").accessibilityIdentifier("miniPlayerToggle")
                Button { audio.stop() } label: { ThemeIcon(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("关闭播放器")
            }.foregroundStyle(reader ? Color(ReaderPalette(settings: readerSettings).ink) : appAppearance.palette.green)
                .padding(.horizontal, reader ? 10 : 17).background { if !reader { Rectangle().fill(.regularMaterial) } }
                .accessibilityElement(children: .contain).accessibilityIdentifier("productionMiniPlayer")
        }
    }
    @EnvironmentObject private var library: LibraryStore
    private var readerSettings: ReadingSettings { library.settings }
}

struct ProductionAudioServiceView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var store: AudioServiceStore?
    @State private var message: String?
    var body: some View {
        Group {
            if let store { AudioServiceEditor(store:store) }
            else { ThemeUnavailableView("服务配置暂时无法读取",systemImage:"key",description:Text(message ?? "正在读取")) }
        }.task { do { store = try library.audio.services() } catch { message = error.localizedDescription } }
    }
}

private struct AudioServiceEditor: View {
    @Environment(\.themeAppearance) private var appAppearance
    private enum Field: Hashable { case name,url,tts,analysis,voice,socket,key }
    @FocusState private var focused: Field?
    @ObservedObject var store: AudioServiceStore
    @EnvironmentObject private var library: LibraryStore
    @State private var draft = AudioServiceProfile()
    @State private var selection = ""
    @State private var key = ""
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"AI 服务配置",subtitle:"自定义兼容服务 · 模型 · 设备钥匙串",icon:"sparkles")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("已保存服务",selection:$selection) { Text("新建服务").tag(""); ForEach(store.profiles) { Text($0.name).tag($0.id) } }.accessibilityIdentifier("audioServiceSelection")
                    TextField("服务名称",text:$draft.name).focused($focused,equals:.name).accessibilityIdentifier("audioServiceName")
                    TextField("HTTPS Base URL，例如 https://你的服务/v1",text:$draft.baseURL).focused($focused,equals:.url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityIdentifier("audioServiceURL")
                    TextField("语音模型",text:$draft.ttsModel).focused($focused,equals:.tts).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("audioTTSModel")
                    TextField("角色分析模型",text:$draft.analysisModel).focused($focused,equals:.analysis).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("audioAnalysisModel")
                    TextField("默认声音 ID",text:$draft.voice).focused($focused,equals:.voice).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("协议",selection:$draft.transport) { ForEach(AudioServiceProfile.Transport.allCases,id:\.self) { Text($0.rawValue).tag($0) } }
                    if draft.transport == .webSocket { TextField("wss 地址",text:$draft.webSocketURL).focused($focused,equals:.socket).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }
                    Toggle("服务需要访问密钥",isOn:$draft.usesKey)
                    if draft.usesKey { SecureField("访问密钥；留空保留同一主机的已保存密钥",text:$key).focused($focused,equals:.key).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("audioServiceKey") }
                }.disabled(busy)
                Text("只填写你自己的客户端访问密钥；服务端凭据由你的网关保管。密钥不会显示、写入日志或进入备份。改变服务地址后需重新保存密钥。服务配置保存在本机，换设备需重新配置。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
                Button("保存配置") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("audioServiceSave")
                Button("测试已保存配置") { test() }.buttonStyle(PrimaryButtonStyle(filled:false)).disabled(busy || !store.profiles.contains(where:{$0.id == selection})).accessibilityIdentifier("audioServiceTest")
                if !selection.isEmpty { Button("删除服务与密钥",role:.destructive) { do { library.audio.stop(); try store.remove(selection); if library.narrationSettings.profileID == selection { library.narrationSettings.profileID = nil }; selection = ""; message = "已删除服务；密钥清理状态：\(store.cleanupPending ? "待重试" : "完成")。" } catch { message = error.localizedDescription } } }
                if busy { ProgressView("正在连接，不会自动播放"); Button("取消") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent).textSelection(.enabled).accessibilityIdentifier("audioServiceMessage") }
                if store.cleanupPending { Button("重试清理旧密钥") { store.retryCleanup() } }
            }.padding(22)
        }.appPageStyle().navigationTitle("AI 服务配置").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItemGroup(placement:.keyboard) { Spacer(); Button("完成输入") { focused = nil } } }
            .onChange(of:selection) { _,id in draft = store.profiles.first(where:{$0.id == id}) ?? .init(); key = "" }
            .onDisappear { operation?.cancel(); key = "" }
    }
    private func save() {
        do {
            library.audio.stop(); try store.save(draft,key:key.isEmpty ? nil : key)
            selection = draft.id; library.narrationSettings.profileID = draft.id; key = ""
            message = store.cleanupPending ? "配置已保存，旧密钥清理待重试。" : "配置已保存；尚未测试连接。"
        } catch { message = "未保存：\(error.localizedDescription)" }
    }
    private func test() {
        operation?.cancel(); busy = true; message = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do {
                let data = try await library.audio.testConnection(profileID:selection)
                if let data { let decoded = try AVAudioPlayer(data:data); guard decoded.duration > 0 else { throw NarrationError.invalidAudio } }
                try Task.checkCancellation(); message = data == nil ? "角色分析接口已返回可验证结果，未启动播放。" : "已收到可解码的音频，未启动播放。"
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}

struct ProductionRolesView: View {
    @Environment(\.themeAppearance) private var appAppearance
    var bookID: String? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var selection = ""
    @State private var analysis: RoleAnalysis?
    @State private var message: String?
    @State private var busy = false
    @State private var operation: Task<Void,Never>?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"AI 多角色朗读",subtitle:"角色分析 · 名称编辑 · 声音映射 · 正文版本校验",icon:"person.2.wave.2")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Picker("作品",selection:$selection) { Text("请选择作品").tag(""); ForEach(library.books) { Text($0.title).tag($0.id) } }
                    Stepper("本次最多 \(library.narrationSettings.maximumAnalysisRequests) 次分析请求",value:$library.narrationSettings.maximumAnalysisRequests,in:1...20)
                    Toggle("跨章时自动分析（使用服务额度）",isOn:$library.narrationSettings.analyzesNextChapter)
                    NavigationLink { ProductionAudioServiceView() } label: { ThemeLabel("配置兼容服务与模型",systemImage:"key") }
                }
                Button("分析当前章节") { analyze(force:false) }.buttonStyle(PrimaryButtonStyle()).disabled(selection.isEmpty || busy)
                if let current = analysis {
                    AppSettingsCard("角色与声音",icon:"person.2") {
                        Text("已对应 \(current.assignments.count) 个正文片段；未识别角色使用旁白。").font(.system(size:11)).foregroundStyle(appAppearance.palette.muted)
                        ForEach(Array(current.roles.enumerated()),id:\.element.id) { index,role in
                            TextField("角色名称",text:Binding(get:{analysis?.roles[safe:index]?.name ?? role.name},set:{if analysis?.roles.indices.contains(index) == true { analysis?.roles[index].name = String($0.prefix(80)) }}))
                            TextField("声音 ID；留空使用服务默认声音",text:voice(role.id)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    Button("保存角色编辑") { Task { do { if let analysis { try await library.audio.saveAnalysis(analysis); message = "角色编辑已保存。" } } catch { message = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle(filled:false))
                    Button("重新分析（使用服务额度）") { analyze(force:true) }.buttonStyle(PrimaryButtonStyle(filled:false)).disabled(busy)
                    NavigationLink { ProductionNarrationView(bookID:selection,mode:.roles) } label: { ThemeLabel("打开多角色播放器",systemImage:"play.circle") }.font(.system(size:13))
                }
                if busy { ProgressView("正在分析本章"); Button("取消分析") { operation?.cancel(); busy = false } }
                if let message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent) }
                Text("每次只分析当前章，最多 40000 UTF-16 单元，按不超过 6000 单元分批。缓存按正文版本与服务模型区分；未知角色使用默认声音。角色和分析结果需要你核对，未确认的第三方服务不视为已验收。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("AI 多角色朗读").navigationBarTitleDisplayMode(.inline)
            .onAppear { selection = bookID ?? library.history.first?.id ?? library.books.first?.id ?? "" }
            .onChange(of:selection) { _,_ in operation?.cancel(); analysis = nil; busy = false }
            .onDisappear { operation?.cancel() }
    }
    private func voice(_ roleID: String) -> Binding<String> {
        let key = LibraryAudioCoordinator.voiceKey(bookID:selection,profileID:library.narrationSettings.profileID ?? "",roleID:roleID)
        return Binding(get:{library.narrationSettings.roleVoices[key] ?? ""},set:{ library.narrationSettings.roleVoices[key] = $0.isEmpty ? nil : String($0.prefix(200)) })
    }
    private func analyze(force: Bool) {
        operation?.cancel(); busy = true; message = nil
        operation = Task {
            defer { if !Task.isCancelled { busy = false } }
            do { let value = try await library.audio.analyze(bookID:selection,force:force); try Task.checkCancellation(); analysis = value; message = "分析完成，尚未启动播放。" }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
}
