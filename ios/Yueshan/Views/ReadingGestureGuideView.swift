import SwiftUI

struct ReadingGestureGuideView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let isFirstUse: Bool
    private var theme: ReadingTheme { store.settings.theme }
    private var palette: ReaderPalette { ReaderPalette(settings: store.settings) }
    private var guideInk: Color { Color(palette.ink) }
    private var guideBackground: Color { Color(palette.background) }
    private var guideSecondary: Color { Color(palette.secondary) }
    private var isPaged: Bool { store.settings.mode.isPaged }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("阅读小提示").font(.system(size: 10)).tracking(2).foregroundStyle(guideSecondary)
                    Text("轻点之间，继续故事").font(.system(size: 23, weight: .medium, design: .serif))
                        .accessibilityIdentifier("gestureGuideTitle")
                    Text("当前模式 · \(store.settings.mode.title)").font(.system(size: 11)).foregroundStyle(guideSecondary)
                        .accessibilityIdentifier("gestureGuideMode")
                }

                HStack(spacing: 7) {
                    tapZone("左侧", symbol: "hand.tap", action: isPaged ? "前进一页" : "前进约一屏")
                    tapZone("中间", symbol: "ellipsis", action: "显示／隐藏\n工具栏", emphasis: true)
                    tapZone("右侧", symbol: "hand.tap", action: isPaged ? "前进一页" : "前进约一屏")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label(isPaged ? (store.settings.mode == .verticalPaged ? "上滑下一页 · 下滑上一页" : "左滑下一页 · 右滑上一页") : "上下滑动阅读 · 底部箭头切换章节",
                          systemImage: store.settings.mode == .paged ? "arrow.left.arrow.right" : "arrow.up.arrow.down")
                        .font(.system(size: 12)).accessibilityIdentifier("gestureGuideSwipe")
                    Text(store.settings.tapToTurn
                         ? "已开启轻触翻页，点左右任一侧都可前进。"
                         : "两侧轻触前进需在阅读设置中开启「轻触翻页」。")
                        .font(.system(size: 11)).foregroundStyle(guideSecondary).lineSpacing(4)
                        .accessibilityIdentifier("gestureGuideTapStatus")
                }

                VStack(spacing: 11) {
                    Button(isFirstUse ? "开始阅读" : "知道了") { dismiss() }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("dismissGestureGuide")
                    Text("以后可在「设置 → 查看阅读手势」再次查看。")
                        .font(.system(size: 10)).foregroundStyle(guideSecondary).frame(maxWidth: .infinity)
                }
            }.padding(.horizontal, 25).padding(.top, 29).padding(.bottom, 20)
        }
        .foregroundStyle(guideInk)
        .background(guideBackground)
        .preferredColorScheme((store.settings.preferences.colors?.dark ?? (theme == .dark)) ? .dark : .light)
        .presentationBackground(guideBackground)
        .presentationDetents([.height(430), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(26)
    }

    private func tapZone(_ title: String, symbol: String, action: String, emphasis: Bool = false) -> some View {
        VStack(spacing: 9) {
            Text(title).font(.system(size: 9)).foregroundStyle(guideSecondary)
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).frame(height: 23)
            Text(action).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).frame(minHeight: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(guideSecondary.opacity(emphasis ? 0.16 : 0.08), in: .rect(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }
}
