import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var showSettings = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                HStack(spacing: 18) {
                    Text("山").font(.system(size: 31, design: .serif)).foregroundStyle(Palette.green).frame(width: 70, height: 70).background(Color(hex: 0xE4EAD9), in: .rect(cornerRadius: 24))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("山间读者").font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(Palette.green)
                        Text("你的阅读，只属于你。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                }.padding(.vertical, 13)
                HStack {
                    number(store.favorites.count, label: "书架收藏")
                    Rectangle().fill(Palette.line).frame(width: 1, height: 40)
                    number(store.progress.count, label: "读过的故事")
                }.padding(.vertical, 22).background(Color(hex: 0xEDF0E4), in: .rect(cornerRadius: 17))
                Button { showSettings = true } label: {
                    HStack { Label("阅读偏好", systemImage: "textformat.size"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 12)) }.font(.system(size: 14)).foregroundStyle(Palette.green).padding(20).background(.white.opacity(0.6), in: .rect(cornerRadius: 15))
                }
                VStack(alignment: .leading, spacing: 16) {
                    Label("关于这个 Demo", systemImage: "leaf").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.green)
                    Text("阅山，一个安静的私人阅读角落。").font(.system(size: 20, design: .serif)).lineSpacing(7).foregroundStyle(Palette.green)
                    Text("这是 iOS 原生界面预览。8 本原创模拟小说，可体验搜索、收藏、选章、阅读和进度恢复。").font(.system(size: 12)).lineSpacing(7).foregroundStyle(Palette.muted)
                    Text("阅读数据保存在当前设备，不连接真实书源。演示章节包含复用段落，书籍字数与状态仅用于界面展示。").font(.system(size: 11)).lineSpacing(7).foregroundStyle(Palette.muted)
                    Text("YUESHAN FOR iOS · DESIGN PREVIEW 0.1").font(.system(size: 8)).tracking(1.3).foregroundStyle(Palette.muted).padding(.top, 5)
                }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0xEEEFE4), in: .rect(cornerRadius: 17))
            }.padding(23)
        }.background(Palette.background).navigationTitle("我的").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showSettings) { ReadingSettingsView() }
    }

    private func number(_ value: Int, label: String) -> some View {
        VStack(spacing: 8) { Text("\(value)").font(.system(size: 29, weight: .regular, design: .serif)).foregroundStyle(Palette.green); Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted) }.frame(maxWidth: .infinity)
    }
}

struct ReadingSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    private var theme: ReadingTheme { store.settings.theme }
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读主题") {
                    HStack(spacing: 12) {
                        ForEach(ReadingTheme.allCases, id: \.self) { item in
                            Button { store.settings.theme = item } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: item == .dark ? "moon" : "sun.max").font(.system(size: 20))
                                    Text(item.title).font(.system(size: 12))
                                }.frame(maxWidth: .infinity).frame(height: 84).foregroundStyle(item.ink).background(item.background, in: .rect(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme == item ? Color(hex: 0x8FA277) : Color.clear, lineWidth: 2))
                            }.buttonStyle(.plain).accessibilityLabel(item.title).accessibilityAddTraits(item == theme ? .isSelected : [])
                        }
                    }.padding(.vertical, 5).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                }
                Section {
                    Picker("字号", selection: $store.settings.fontSize) {
                        ForEach([16.0, 18, 20, 22, 24], id: \.self) { value in Text("\(Int(value))").tag(value) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("fontPicker")
                } header: { Text("文字大小 · \(Int(store.settings.fontSize)) pt") }
                Section("段落间距") {
                    Picker("行距", selection: $store.settings.lineSpacing) {
                        Text("紧凑").tag(6.0); Text("适中").tag(12.0); Text("宽松").tag(18.0)
                    }.pickerStyle(.segmented)
                }
                Section("阅读预览") {
                    Text("山海有相逢，长风自有归处。\n在字里行间，遇见另一个世界。")
                        .font(.system(size: store.settings.fontSize, design: .serif)).lineSpacing(store.settings.lineSpacing).foregroundStyle(theme.ink).padding(.vertical, 15).listRowBackground(theme.background)
                }
                Section {
                    Button("恢复默认设置") { store.settings = .init() }.foregroundStyle(Palette.green)
                } footer: { Label("偏好自动保存在当前设备", systemImage: "checkmark.circle").font(.system(size: 11)) }
            }
            .navigationTitle("阅读偏好").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }.tint(Palette.green).presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
