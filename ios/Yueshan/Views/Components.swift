import SwiftUI

enum Palette {
    static let background = Color(hex: 0xF7F6F0)
    static let green = Color(hex: 0x354F40)
    static let muted = Color(hex: 0x929986)
    static let line = Color(hex: 0xE3E6D9)
    static let accent = Color(hex: 0xB7815A)
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

struct BookCover: View {
    let book: Book
    var width: CGFloat = 150
    private var colors: (UInt32, UInt32, UInt32) {
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
            }
            VStack(spacing: 0) {
                Text("阅 山 · 故 事 典 藏").font(.system(size: width * 0.042)).tracking(1.2).opacity(0.5).padding(.top, width * 0.13)
                Spacer().frame(height: width * 0.2)
                Text(book.title).font(.system(size: width * 0.18, weight: .medium, design: .serif)).tracking(width * 0.015).multilineTextAlignment(.center).lineSpacing(7).frame(width: width * 0.75)
                Text("\(book.author) 著").font(.system(size: width * 0.05)).tracking(2).opacity(0.7).padding(.top, width * 0.09)
                Spacer(minLength: 0)
                Text("YUESHAN ORIGINAL").font(.system(size: width * 0.032)).tracking(1.3).opacity(0.5).padding(.bottom, width * 0.1)
            }
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.14), .white.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 7)
                Spacer()
            }
        }
        .foregroundStyle(Color(hex: colors.1))
        .frame(width: width, height: width * 1.38)
        .clipShape(.rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.04), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.09), radius: 5, x: 1, y: 4)
        .accessibilityLabel("\(book.title)封面")
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
