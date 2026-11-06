import Foundation
import ImageIO

enum ReadingStyleResolver {
    /// One normalization path for all entry points. Invalid new overrides keep
    /// the previous valid value; theme changes leave personal overrides intact.
    static func resolve(_ value: ReadingSettings, previous: ReadingSettings = .init()) -> ReadingSettings {
        var next = value
        next.fontSize = ReaderPreferenceBounds.clamp(next.fontSize, 14...30, fallback: previous.fontSize)
        next.lineSpacing = ReaderPreferenceBounds.clamp(next.lineSpacing, 0...24, fallback: previous.lineSpacing)
        next.preferences.normalize()
        let titles: [WritableKeyPath<ReaderPreferences, String?>] = [\.titleCSS, \.themeTitleCSS]
        for key in titles {
            if let css = value.preferences[keyPath: key], css.utf8.count > 60_000 || (try? ReaderTitleStyle.parse(css: css, accent: next.preferences.colors?.accent ?? 0x354F40)) == nil {
                let old = previous.preferences[keyPath: key]
                next.preferences[keyPath: key] = old.flatMap { (try? ReaderTitleStyle.parse(css: $0, accent: 0x354F40)) == nil ? nil : $0 }
            }
        }
        let skins: [WritableKeyPath<ReaderPreferences, String?>] = [\.bubbleSVG, \.customBubbleSVG]
        for key in skins {
            if let svg = value.preferences[keyPath: key], !ThemeAssetValidator.isValid(svg, kind: .bubble) {
                next.preferences[keyPath: key] = previous.preferences[keyPath: key].flatMap { ThemeAssetValidator.isValid($0, kind: .bubble) ? $0 : nil }
            }
        }
        let images: [WritableKeyPath<ReaderPreferences, Data?>] = [\.bubbleImageData, \.customBubbleImageData]
        for key in images {
            if let data = value.preferences[keyPath: key], data.count > 512_000 || CGImageSourceCreateWithData(data as CFData, nil) == nil {
                next.preferences[keyPath: key] = previous.preferences[keyPath: key].flatMap { CGImageSourceCreateWithData($0 as CFData, nil) == nil ? nil : $0 }
            }
        }
        return next
    }
}
