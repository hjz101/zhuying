import SwiftUI

enum Palette {
    static let background = Color(hex: 0xF7F6F0)
    static let green = Color(hex: 0x354F40)
    static let muted = Color(hex: 0x929986)
    static let line = Color(hex: 0xE3E6D9)
    static let accent = Color(hex: 0xB7815A)
    static let card = Color.white.opacity(0.72)
    static let soft = Color(hex: 0xEDF0E4)
}

/// App controls use the same palette as the shelf; reading paper is configured separately.
extension View {
    func appPageStyle() -> some View {
        self.background(Palette.background)
            .foregroundStyle(Palette.green)
            .tint(Palette.green)
            .toolbarBackground(Palette.background, for: .navigationBar)
            .preferredColorScheme(.light)
    }
}

struct AppPageHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 25, weight: .light))
                .frame(width: 54, height: 54).background(Palette.soft, in: .rect(cornerRadius: 17))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 25, weight: .medium, design: .serif))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
            }
        }.foregroundStyle(Palette.green).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppSettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content
    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon).font(.system(size: 16, weight: .medium, design: .serif))
                .foregroundStyle(Palette.green)
            content
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: .rect(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.line.opacity(0.55), lineWidth: 0.5) }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct MountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [CGPoint] = [CGPoint(x: 0, y: 0.55), CGPoint(x: 0.17, y: 0.3), CGPoint(x: 0.3, y: 0.43), CGPoint(x: 0.48, y: 0.03), CGPoint(x: 0.63, y: 0.35), CGPoint(x: 0.78, y: 0.16), CGPoint(x: 1, y: 0.6), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        path.addLines(points.map { CGPoint(x: $0.x * rect.width, y: $0.y * rect.height) })
        path.closeSubpath()
        return path
    }
}

enum BookCoverPalette {
    static func colors(for book: Book) -> (UInt32, UInt32, UInt32) {
        switch book.color {
        case "peach": (0xD4A78E, 0x6C473B, 0x739392)
        case "indigo": (0x29334E, 0xE0E1CC, 0x586784)
        case "sand": (0xD5C4A4, 0x605741, 0x8A8B6E)
        case "wine": (0x69524D, 0xE6D9B8, 0x3C4036)
        case "sage": (0x9DAD90, 0xF3EAD0, 0x56785B)
        case "mist": (0xC0CEC5, 0x3E5A4D, 0x6D9286)
        case "blue": (0x6F8890, 0xEBEDD7, 0x375868)
        default: (0x365851, 0xE8E3CA, 0x203E36)
        }
    }
}

struct BookCover: View {
    let book: Book
    var width: CGFloat = 150
    var titleLineLimit: Int? = nil
    @EnvironmentObject private var library: LibraryStore
    @State private var savedCover: UIImage?
    private var colors: (UInt32, UInt32, UInt32) { BookCoverPalette.colors(for: book) }
    var body: some View {
        ZStack {
            Color(hex: colors.0)
            GeometryReader { geo in
                if book.color == "indigo" || book.color == "blue" {
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: width * 0.9).offset(x: width * 0.35, y: geo.size.height * 0.69)
                    Ellipse().stroke(.white.opacity(0.18), lineWidth: 0.5).frame(width: width * 1.9, height: width * 0.5).rotationEffect(.degrees(-35)).offset(x: -width * 0.4, y: geo.size.height * 0.66)
                } else {
                    Circle().fill(Color(hex: 0xE7D5A0).opacity(0.55)).frame(width: width * 0.26).offset(x: width * 0.55, y: geo.size.height * 0.63)
                    MountainShape().fill(Color(hex: colors.2).opacity(0.4)).frame(height: geo.size.height * 0.37).scaleEffect(x: -1).offset(y: geo.size.height * 0.63)
                    MountainShape().fill(Color(hex: colors.2)).frame(height: geo.size.height * 0.31).offset(y: geo.size.height * 0.69)
                }
            }.accessibilityHidden(true).allowsHitTesting(false)
            VStack(spacing: 0) {
                Text("阅 山 · 故 事 典 藏").font(.system(size: width * 0.042)).tracking(1.2).opacity(0.5).padding(.top, width * 0.13)
                Spacer().frame(height: width * 0.2)
                Text(book.title).font(.system(size: width * 0.18, weight: .medium, design: .serif)).tracking(width * 0.015).multilineTextAlignment(.center).lineSpacing(7)
                    .lineLimit(titleLineLimit).minimumScaleFactor(titleLineLimit == nil ? 1 : 0.7)
                    .frame(width: width * 0.75)
                    .frame(maxHeight: titleLineLimit == nil ? nil : width * 0.55, alignment: .top)
                Text("\(book.author) 著").font(.system(size: width * 0.05)).tracking(2).opacity(0.7).padding(.top, width * 0.09)
                Spacer(minLength: 0)
                Text("ZHUYING ORIGINAL").font(.system(size: width * 0.032)).tracking(1.3).opacity(0.5).padding(.bottom, width * 0.1)
            }
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.14), .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 7)
                Spacer()
            }
        }
        .foregroundStyle(Color(hex: colors.1))
        .frame(width: width, height: width * 1.38)
        .overlay { if let savedCover { Image(uiImage:savedCover).resizable().scaledToFill().frame(width:width,height:width * 1.38).clipped().accessibilityHidden(true) } }
        .clipShape(.rect(cornerRadius: 5))
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.04), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.09), radius: 5, x: 1, y: 4)
        .accessibilityLabel("\(book.title)封面")
        .task(id:book.cover?.digest) {
            savedCover = nil
            guard let reference = book.cover else { return }
            do { let url = try await library.mediaURL(reference); let data = try await Task.detached { try Data(contentsOf:url) }.value; try Task.checkCancellation(); savedCover = UIImage(data:data) } catch { }
        }
    }
}

struct BookSpine: View {
    let book: Book
    let width: CGFloat
    var height: CGFloat = 184
    var progress: Int = 0
    var hasUpdates = false

    private var colors: (UInt32, UInt32, UInt32) { BookCoverPalette.colors(for: book) }
    private var titleFontSize: CGFloat { width < 52 ? 15 : 17 }
    private var titleColumns: [[String]] {
        let glyphs = book.title.map(String.init)
        let perColumn = max(1, Int(max(20, height - 62) / (titleFontSize + 3)))
        let maxColumns = width >= titleFontSize * 2 + 18 ? 2 : 1
        let capacity = perColumn * maxColumns
        let displayed = glyphs.count > capacity ? Array(glyphs.prefix(capacity - 1)) + ["⋮"] : glyphs
        return stride(from: 0, to: displayed.count, by: perColumn).map {
            Array(displayed[$0..<min($0 + perColumn, displayed.count)])
        }
    }

    var body: some View {
        ZStack {
            Color(hex: colors.0)
            LinearGradient(colors: [.black.opacity(0.17), .white.opacity(0.07), .clear, .black.opacity(0.06)],
                           startPoint: .leading, endPoint: .trailing)
                .accessibilityHidden(true).allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(Array(titleColumns.indices.reversed()), id: \.self) { column in
                        VStack(spacing: 3) {
                            ForEach(Array(titleColumns[column].enumerated()), id: \.offset) { _, glyph in
                                Text(glyph).font(.system(size: titleFontSize, weight: .medium, design: .serif))
                                    .frame(width: titleFontSize + 1, height: titleFontSize)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Text(book.author).font(.system(size: 10)).opacity(0.82).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.top, 6)
            }.padding(.horizontal, 6).padding(.top, 22).padding(.bottom, 18)
            VStack {
                Rectangle().frame(height: 0.5)
                Spacer()
                Rectangle().frame(height: 0.5)
            }.foregroundStyle(Color(hex: colors.1).opacity(0.2)).padding(.horizontal, 7).padding(.vertical, 9)
                .accessibilityHidden(true).allowsHitTesting(false)
        }
        .foregroundStyle(Color(hex: colors.1))
        .frame(width: width, height: height)
        .overlay(alignment: .topTrailing) {
            if hasUpdates {
                SpineBookmark().fill(Palette.accent).frame(width: 7, height: 15).padding(.trailing, 8)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if progress > 0 {
                Rectangle().fill(Color(hex: colors.1).opacity(0.65))
                    .frame(width: width * CGFloat(min(100, max(0, progress))) / 100, height: 2)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .clipShape(.rect(cornerRadius: 3))
        .contentShape(Rectangle())
        .shadow(color: .black.opacity(0.09), radius: 2, x: 1, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title)，\(book.author)")
        .accessibilityValue("\(progress > 0 ? "已读 \(min(100, progress))%" : "尚未开始")\(hasUpdates ? "，有章节更新" : "")")
    }
}

private struct SpineBookmark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY * 0.76))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 49)
            .background(filled ? Palette.green : Color.clear, in: .rect(cornerRadius: 12))
            .foregroundStyle(filled ? .white : Palette.green)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(filled ? .clear : Palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 19, weight: .semibold, design: .serif)).foregroundStyle(Palette.green)
            Spacer()
            if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted) }
        }
    }
}

struct BookRow: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    var body: some View {
        HStack(alignment: .top, spacing: 17) {
            BookCover(book: book, width: 77)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Palette.green)
                Text("\(book.author) · \(book.genre)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Text(book.intro).font(.system(size: 12)).lineSpacing(4).foregroundStyle(Palette.muted).lineLimit(2)
                HStack(spacing: 8) {
                    Text(book.status).foregroundStyle(Palette.green.opacity(0.7))
                    Text("\(book.words)字").foregroundStyle(Palette.muted)
                    if store.isFavorite(book) { Spacer(); Image(systemName: "bookmark.fill").foregroundStyle(Palette.green) }
                }.font(.system(size: 10)).padding(.top, 2)
            }.padding(.top, 2)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}
