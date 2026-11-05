import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ReadingAppearanceView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var demo: FeatureDemoStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ReadingSettingsPreview(settings: store.settings)
                AppSettingsCard("纸色", icon: "paintpalette") {
                    HStack(spacing: 10) {
                        ForEach(ReadingTheme.allCases, id: \.self) { item in
                            Button {
                                store.settings.theme = item
                                store.settings.preferences.colors = nil
                                demo.refreshReaderBubbles()
                            } label: {
                                VStack(spacing: 6) {
                                    Text("阅").font(.system(size: 25, design: .serif))
                                    Text(item.title).font(.system(size: 12))
                                }.foregroundStyle(item.ink).frame(maxWidth: .infinity, minHeight: 80)
                                    .background(item.background, in: .rect(cornerRadius: 11))
                                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(store.settings.preferences.colors == nil && item == store.settings.theme ? Palette.green : Palette.line, lineWidth: 1.5))
                            }.buttonStyle(.plain).accessibilityIdentifier("reading-paper-\(item.rawValue)")
                        }
                    }
                }
                AppSettingsCard("主题与字体", icon: "textformat") {
                    NavigationLink { ThemeLibraryView() } label: {
                        ReadingAppearanceRow(title: "我的主题库", detail: store.settings.preferences.colors?.name ?? store.settings.theme.title)
                    }.buttonStyle(.plain).accessibilityIdentifier("readingThemeLibrary")
                    NavigationLink { ReadingFontManagerView() } label: {
                        ReadingAppearanceRow(title: "字体管理", detail: ReadingPreferencePresentation.fontDisplayName(store.settings.preferences.fontName, entries: ReadingFontLibrary.shared.entries))
                    }.buttonStyle(.plain).accessibilityIdentifier("readingFontLibrary")
                }
                Text("主题应用后更新真实阅读配色；独立自定义的章节标题会保留。主题内不受原生渲染支持的 CSS 装饰会单独提示。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("主题与字体").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
    }
}
private struct ReadingAppearanceRow: View {
    let title: String
    let detail: String
    var body: some View {
        HStack { Text(title).font(.system(size: 14)); Spacer(); Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1); Image(systemName: "chevron.right").font(.system(size: 10)) }.frame(minHeight: 46)
    }
}

struct ReadingFontManagerView: View {
    @EnvironmentObject private var store: LibraryStore
    @StateObject private var fonts = ReadingFontLibrary.shared
    @State private var sample = "山海有相逢，长风自有归处。Aa 0123，。！？"
    @State private var showingFiles = false
    @State private var error: String?
    private var samples: [(String, String?)] {
        [("系统黑体", nil), ("系统衬线", "__serif__")] + fonts.entries.map { ($0.displayName, Optional($0.postScriptName)) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReadingSettingsPreview(settings: store.settings)
                TextField("输入你想比较的文字", text: $sample, axis: .vertical).font(.system(size: 16)).padding(12)
                    .background(Palette.card, in: .rect(cornerRadius: 10)).accessibilityIdentifier("readingFontSample")
                Button("导入本地字体", systemImage: "square.and.arrow.down") { showingFiles = true }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("readingFontImport")
                ForEach(Array(samples.enumerated()), id: \.offset) { _, entry in
                    Button { store.settings.preferences.fontName = entry.1 } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(entry.0).font(.system(size: 12)); Spacer()
                                if store.settings.preferences.fontName == entry.1 { Image(systemName: "checkmark.circle.fill") }
                            }
                            Text(sample.isEmpty ? "山海有相逢，长风自有归处。" : sample).font(previewFont(entry.1)).lineSpacing(8)
                        }.foregroundStyle(Palette.green).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(Palette.card, in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("reading-font-\(entry.1 ?? "system")")
                }
                Text("每张卡片直接使用对应字体排字。导入文件保存在本机；字体未包含的字符会使用系统回退字形。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                if let name = store.settings.preferences.fontName, name != "__serif__", UIFont(name: name, size: 20) == nil {
                    Text("当前字体文件不可用，正文暂用系统字体。请重新导入。 ").font(.system(size: 12)).foregroundStyle(Palette.accent)
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("字体管理").navigationBarTitleDisplayMode(.inline).readingPreferenceDoneToolbar()
            .fileImporter(isPresented: $showingFiles, allowedContentTypes: ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }, allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let added = try fonts.importFont(at: url)
                    store.settings.preferences.fontName = added.first?.postScriptName
                } catch { self.error = error.localizedDescription }
            }
            .alert("字体导入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了") { error = nil } } message: { Text(error ?? "") }
    }
    private func previewFont(_ name: String?) -> Font {
        Font(ReadingPreferencePresentation.sampleFont(name, settings: store.settings))
    }
}
