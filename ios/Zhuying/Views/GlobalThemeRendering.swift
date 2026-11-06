import SwiftUI

struct AppThemePalette {
    var appearance: AppThemeAppearance
    func color(_ role: String, fallback: UInt32 = 0x354F40) -> Color { Color(hex: appearance.colors[role].flatMap(GlobalThemePackage.hex) ?? fallback) }
    var background: Color { color("background.page") }
    var green: Color { color("text.primary") }
    var muted: Color { color("text.secondary") }
    var line: Color { color("border") }
    var accent: Color { color("accent") }
    var card: Color { appearance == .original ? Color.white.opacity(0.72) : color("background.card") }
    var soft: Color { color("background.soft") }
    var primary: Color { color("action.primary.background") }
    var onPrimary: Color { color("action.primary.foreground", fallback: 0xFFFFFF) }
    var onAccent: Color {
        if appearance == .original { return .white }
        if appearance.colors["text.on-accent"] != nil { return color("text.on-accent") }
        let hex = appearance.colors["accent"].flatMap(GlobalThemePackage.hex) ?? 0
        func component(_ value: UInt32) -> Double { let c = Double(value) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * component(hex >> 16) + 0.7152 * component((hex >> 8) & 255) + 0.0722 * component(hex & 255)
        return luminance > 0.179 ? .black : .white
    }
    func legacyCard(opacity: Double) -> Color { appearance == .original ? Color.white.opacity(opacity) : card }
    /// Former fixed decorative surfaces inherit the new surface palette. Default theme keeps original values.
    func surface(_ original: UInt32) -> Color {
        if let custom = appearance.colors[String(format: "surface.%06X", original)].flatMap(GlobalThemePackage.hex) { return Color(hex: custom) }
        return appearance == .original ? Color(hex: original) : soft
    }
    func legacyColor(_ original: UInt32, role: String) -> Color {
        appearance == .original ? Color(hex: original) : color(role, fallback: original)
    }
}
struct ThemeAppearanceContext: Equatable {
    var bundle = GlobalThemeBundle.originals[0]
    var palette: AppThemePalette { .init(appearance: bundle.document.app) }
    func image(_ path: String) -> UIImage? {
        ThemeImageCache.image(path: path, bundle: bundle)
    }
    func iconImage(_ path: String, scale: CGFloat) -> UIImage? {
        ThemeImageCache.icon(path: path, bundle: bundle, scale: scale)
    }
}
private enum ThemeImageCache {
    static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 64; cache.totalCostLimit = 32 * 1024 * 1024; return cache
    }()
    static func image(path: String, bundle: GlobalThemeBundle) -> UIImage? {
        guard let data = bundle.resources[path] else { return nil }
        let key = (bundle.id + ":" + path) as NSString
        if let value = cache.object(forKey: key) { return value }
        guard let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }
    static func icon(path: String, bundle: GlobalThemeBundle, scale: CGFloat) -> UIImage? {
        let scale = scale.isFinite ? min(4, max(1, scale)) : 1
        let key = (bundle.id + ":icon:" + String(Double(scale)) + ":" + path) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let original = image(path: path, bundle: bundle) else { return nil }
        let size = CGSize(width: 20, height: 20)
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = false
        let factor = min(size.width / original.size.width, size.height / original.size.height)
        let fitted = CGSize(width: original.size.width * factor, height: original.size.height * factor)
        let result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2, width: fitted.width, height: fitted.height))
        }
        // Native Tab labels extract the UIImage and ignore SwiftUI frame/resizable
        // modifiers. Give the bitmap a real point size while keeping Retina pixels.
        cache.setObject(result, forKey: key, cost: Int(20 * 20 * scale * scale * 4))
        return result
    }
}
private struct ThemeAppearanceKey: EnvironmentKey { static let defaultValue = ThemeAppearanceContext() }
private struct ThemeControlStateKey: EnvironmentKey { static let defaultValue = "normal" }
extension EnvironmentValues {
    var themeAppearance: ThemeAppearanceContext { get { self[ThemeAppearanceKey.self] } set { self[ThemeAppearanceKey.self] = newValue } }
    var themeControlState: String { get { self[ThemeControlStateKey.self] } set { self[ThemeControlStateKey.self] = newValue } }
}

struct ThemeIcon: View {
    @Environment(\.themeAppearance) private var appearance
    @Environment(\.displayScale) private var displayScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.themeControlState) private var state
    let systemName: String
    var role: String? = nil
    var selected = false
    private var asset: ThemeIconResource? {
        let resources = appearance.bundle.document.app.icons
        return role.flatMap { resources[$0] } ?? resources["symbol." + systemName]
    }
    private var path: String? {
        guard let asset else { return nil }
        if !enabled { return asset.disabled ?? asset.path }
        if state == "pressed" { return asset.pressed ?? asset.path }
        if state == "loading" { return asset.loading ?? asset.path }
        if focused { return asset.focused ?? asset.path }
        return selected ? asset.selected ?? asset.path : asset.path
    }
    var body: some View {
        if let path, let uiImage = appearance.iconImage(path, scale: displayScale) {
            Image(uiImage: uiImage).renderingMode(asset?.template == false ? .original : .template)
                .resizable().scaledToFit().frame(width: 20, height: 20).accessibilityHidden(true)
        } else { Image(systemName: asset?.symbol ?? systemName) }
    }
}

struct ThemeLabel: View {
    let title: String
    let systemImage: String
    var role: String? = nil
    var selected = false
    init(_ title: String, systemImage: String, role: String? = nil, selected: Bool = false) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.selected = selected
    }
    var body: some View { Label { Text(title) } icon: { ThemeIcon(systemName: systemImage, role: role, selected: selected) } }
}

struct ThemeButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void
    init(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.role = role; self.action = action
    }
    var body: some View { Button(role: role, action: action) { ThemeLabel(title, systemImage: systemImage) } }
}

struct ThemeUnavailableView: View {
    let title: String
    let systemImage: String
    var description: Text?
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.title = title; self.systemImage = systemImage; self.description = description
    }
    var body: some View { ContentUnavailableView { ThemeLabel(title, systemImage: systemImage) } description: { description } }
}

struct ThemeProgressStyle: ProgressViewStyle {
    @Environment(\.themeAppearance) private var appearance
    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            ProgressView(value: fraction) { configuration.label }.progressViewStyle(.linear).tint(appearance.palette.primary)
        } else {
            VStack(spacing: 8) {
                if appearance.bundle.document.app.icons["state.loading"] != nil {
                    ThemeIcon(systemName: "hourglass", role: "state.loading").environment(\.themeControlState, "loading")
                } else { ProgressView().progressViewStyle(.circular).tint(appearance.palette.primary) }
                configuration.label
            }
        }
    }
}

struct ThemeSurface: View {
    @Environment(\.themeAppearance) private var appearance
    var role = "page"
    var body: some View {
        let app = appearance.bundle.document.app
        let background = app.backgrounds[role] ?? (["page", "card"].contains(role) ? nil : app.backgrounds["page"])
        ZStack {
            if role == "card" { appearance.palette.card } else { appearance.palette.background }
            if let background, let image = appearance.image(background.path) {
                GeometryReader { size in
                    Group {
                        if background.mode == "tile" { Image(uiImage: image).resizable(resizingMode: .tile) }
                        else if background.mode == "fit" { Image(uiImage: image).resizable().scaledToFit() }
                        else { Image(uiImage: image).resizable().scaledToFill() }
                    }.frame(width: size.size.width, height: size.size.height).clipped().opacity(background.opacity)
                }
                appearance.palette.background.opacity(background.overlayOpacity)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ThemePageStyle: ViewModifier {
    @Environment(\.themeAppearance) private var appearance
    var role: String
    func body(content: Content) -> some View {
        content.background(ThemeSurface(role: role).ignoresSafeArea()).background(ThemeNavigationAppearance().frame(width: 0, height: 0)).foregroundStyle(appearance.palette.green)
            .tint(appearance.palette.primary)
            .toolbarBackground(appearance.palette.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .toolbarColorScheme(appearance.bundle.document.app.dark ? .dark : .light, for: .navigationBar, .tabBar)
            .preferredColorScheme(appearance.bundle.document.app.dark ? .dark : .light)
    }
}

/// Native chrome shares the page palette, including scroll-edge and compact states.
@MainActor
enum ThemeNativeBarAppearance {
    static func navigation(_ appearance: ThemeAppearanceContext, copying source: UINavigationBarAppearance? = nil) -> UINavigationBarAppearance {
        let value = source?.copy() ?? UINavigationBarAppearance()
        value.configureWithOpaqueBackground()
        value.backgroundColor = UIColor(appearance.palette.background)
        value.shadowColor = .clear
        value.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.green)
        value.largeTitleTextAttributes[.foregroundColor] = UIColor(appearance.palette.green)
        for button in [value.buttonAppearance, value.doneButtonAppearance, value.backButtonAppearance] {
            button.normal.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.green)
            button.highlighted.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.primary)
        }
        let asset = appearance.bundle.document.app.icons["navigation.back"]
        var image = asset?.path.flatMap { appearance.iconImage($0, scale: UIScreen.main.scale) } ?? asset?.symbol.flatMap { UIImage(systemName: $0) }
        if asset?.path != nil { image = image?.withRenderingMode(asset?.template == false ? .alwaysOriginal : .alwaysTemplate) }
        value.setBackIndicatorImage(image, transitionMaskImage: image)
        return value
    }
    static func tab(_ appearance: ThemeAppearanceContext) -> UITabBarAppearance {
        let value = UITabBarAppearance()
        value.configureWithOpaqueBackground()
        value.backgroundColor = UIColor(appearance.palette.background)
        value.shadowColor = .clear
        value.selectionIndicatorTintColor = UIColor(appearance.palette.soft)
        for layout in [value.stackedLayoutAppearance, value.inlineLayoutAppearance, value.compactInlineLayoutAppearance] {
            layout.normal.iconColor = UIColor(appearance.palette.green)
            layout.normal.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.green)
            layout.selected.iconColor = UIColor(appearance.palette.primary)
            layout.selected.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.primary)
            layout.disabled.iconColor = UIColor(appearance.palette.muted)
            layout.disabled.titleTextAttributes[.foregroundColor] = UIColor(appearance.palette.muted)
        }
        return value
    }
}

/// Style the existing native controllers; back gestures and the search tab stay native.
struct ThemeNavigationAppearance: UIViewRepresentable {
    @Environment(\.themeAppearance) private var appearance
    final class Probe: UIView {
        var apply: ((UIView) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); apply?(self) }
    }
    func makeUIView(context: Context) -> Probe { let view = Probe(); view.isUserInteractionEnabled = false; return view }
    func updateUIView(_ view: Probe, context: Context) {
        view.apply = { probe in
            var responder: UIResponder? = probe
            var navigation: UINavigationController?
            var tabs: UITabBarController?
            while let current = responder {
                if let controller = current as? UIViewController {
                    navigation = navigation ?? (controller as? UINavigationController) ?? controller.navigationController
                    tabs = tabs ?? (controller as? UITabBarController) ?? controller.tabBarController
                }
                responder = current.next
            }
            let style: UIUserInterfaceStyle = appearance.bundle.document.app.dark ? .dark : .light
            if let bar = navigation?.navigationBar {
                bar.overrideUserInterfaceStyle = style
                bar.standardAppearance = ThemeNativeBarAppearance.navigation(appearance, copying: bar.standardAppearance)
                bar.scrollEdgeAppearance = ThemeNativeBarAppearance.navigation(appearance, copying: bar.scrollEdgeAppearance)
                bar.compactAppearance = ThemeNativeBarAppearance.navigation(appearance, copying: bar.compactAppearance)
                bar.compactScrollEdgeAppearance = ThemeNativeBarAppearance.navigation(appearance, copying: bar.compactScrollEdgeAppearance)
                bar.tintColor = UIColor(appearance.palette.primary)
            }
            if let bar = tabs?.tabBar {
                bar.overrideUserInterfaceStyle = style
                bar.standardAppearance = ThemeNativeBarAppearance.tab(appearance)
                bar.scrollEdgeAppearance = ThemeNativeBarAppearance.tab(appearance)
                bar.tintColor = UIColor(appearance.palette.primary)
                bar.unselectedItemTintColor = UIColor(appearance.palette.green)
                for item in bar.items ?? [] {
                    item.standardAppearance = ThemeNativeBarAppearance.tab(appearance)
                    item.scrollEdgeAppearance = ThemeNativeBarAppearance.tab(appearance)
                }
                // Keep book-cover colors from bleeding into the floating bar and home area.
                bar.backgroundColor = UIColor(appearance.palette.background)
            }
        }
        DispatchQueue.main.async { [weak view] in guard let view else { return }; view.apply?(view) }
    }
}
struct ThemeButtonFeedbackStyle: ButtonStyle {
    @Environment(\.themeAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.themeControlState, configuration.isPressed ? "pressed" : "normal")
            .opacity(configuration.isPressed ? appearance.bundle.document.app.motion.pressOpacity : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: appearance.bundle.document.app.motion.duration), value: configuration.isPressed)
    }
}

struct ThemeReaderBackdrop: View {
    @ObservedObject private var themes = GlobalThemeStore.shared
    let color: Color
    var body: some View {
        ZStack {
            color
            if let bundle = themes.readerBundle, let background = bundle.document.reader?.background,
               let image = ThemeAppearanceContext(bundle: bundle).image(background.path) {
                GeometryReader { geometry in
                    Group {
                        if background.mode == "tile" { Image(uiImage: image).resizable(resizingMode: .tile) }
                        else if background.mode == "fit" { Image(uiImage: image).resizable().scaledToFit() }
                        else { Image(uiImage: image).resizable().scaledToFill() }
                    }.frame(width: geometry.size.width, height: geometry.size.height).clipped().opacity(background.opacity)
                }
                color.opacity(background.overlayOpacity)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
