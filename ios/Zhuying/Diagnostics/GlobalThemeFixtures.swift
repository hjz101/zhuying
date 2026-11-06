#if DEBUG
import Foundation
import UIKit

enum GlobalThemeFixtures {
    @MainActor static func write(to directory: URL) throws {
        var settings = ReadingSettings(fontSize: 23, lineSpacing: 14)
        settings.preferences.colors = .init(background: 0x18202E, ink: 0xECE8FF, accent: 0xC9B5FF, name: "竹影主题导入测试", dark: true)
        settings.preferences.headerEnabled = true; settings.preferences.showCommentBubbles = true
        let reader = PortableReaderTheme(appearance: .init(settings), resources: ["title": .init(path: "assets/reader/title.css"), "bubble": .init(path: "assets/reader/bubble.svg")])
        let resource: [String: Data] = [
            "assets/reader/title.css": Data(".chapter-title { font-size:28pt; text-align:center; color:#C9B5FF; }".utf8),
            "assets/reader/bubble.svg": Data(ThemeStyleSamples.bubbleSVG[1].utf8)
        ]
        let bundle = GlobalThemeBundle(manifest: .init(themeID: "zhuying.fixtures.complete", name: "竹影完整导入测试", packageKind: "full", scopes: ["app", "reader"], appearanceModes: ["dark"], requiredCapabilities: Array(GlobalThemePackage.capabilities).sorted()), document: .init(app: .night, reader: reader), resources: resource)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try GlobalThemePackage.encode(bundle).write(to: directory.appendingPathComponent("竹影完整主题.zhuyingtheme"), options: .atomic)
    }
}
#endif
