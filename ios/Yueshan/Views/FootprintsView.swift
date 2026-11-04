import SwiftUI

struct FootprintsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var today = Calendar.current.startOfDay(for: Date())
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    private let calendar = Calendar.current
    private var dates: [Date] { ReadingActivity.heatmapDates(ending: today) }
    private var selected: ReadingActivity { activity(selectedDate) }
    private func activity(_ date: Date) -> ReadingActivity { ReadingActivity.demo(on: date, today: today, books: store.books, calendar: calendar) }
    private var streak: Int { (0..<84).prefix { activity(calendar.date(byAdding: .day, value: -$0, to: today)!).minutes > 0 }.count }
    private var weekMinutes: Int {
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        return (0...offset).reduce(0) { $0 + activity(calendar.date(byAdding: .day, value: -$1, to: today)!).minutes }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppPageHeader(title: "每一页，都有足迹。", subtitle: "把读过的日子，留成一片山林。", icon: "calendar")
                HStack(spacing: 0) {
                    metric("\(activity(today).minutes)", unit: "今日分钟")
                    metric("\(streak)", unit: "连续阅读天数")
                    metric("\(weekMinutes)", unit: "本周分钟")
                }.padding(.vertical, 20).background(Palette.soft, in: .rect(cornerRadius: 18))
                AppSettingsCard("阅读热力图", icon: "square.grid.3x3") {
                    HStack {
                        Text("最近 12 周 · 示例阅读记录").font(.system(size: 10)).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("今天") { selectedDate = today }.font(.system(size: 11)).accessibilityIdentifier("activityToday")
                    }
                    Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(0..<7, id: \.self) { row in
                            GridRow {
                                Text(["一", "", "三", "", "五", "", "日"][row]).font(.system(size: 8)).foregroundStyle(Palette.muted).frame(width: 10)
                                ForEach(0..<12, id: \.self) { week in
                                    let index = week * 7 + row
                                    let date = dates[index]
                                    let future = date > today
                                    Button { selectedDate = date } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(future ? Color.clear : color(activity(date).minutes))
                                            .frame(maxWidth: .infinity).frame(height: 19)
                                            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(calendar.isDate(date, inSameDayAs: selectedDate) ? Palette.green : .clear, lineWidth: 2) }
                                    }.buttonStyle(.plain).disabled(future)
                                        .accessibilityLabel(date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                                        .accessibilityValue(future ? "待到来的日期" : "\(activity(date).minutes) 分钟")
                                        .accessibilityIdentifier("activity-day-\(index)")
                                }
                            }
                        }
                    }
                    HStack(spacing: 5) {
                        Spacer(); Text("少").font(.system(size: 9))
                        ForEach([0, 12, 25, 40, 55], id: \.self) { value in RoundedRectangle(cornerRadius: 2).fill(color(value)).frame(width: 12, height: 12) }
                        Text("多").font(.system(size: 9))
                    }.foregroundStyle(Palette.muted)
                }
                AppSettingsCard("那天读过的故事", icon: "book") {
                    HStack {
                        Text(selectedDate, format: .dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))).font(.system(size: 13))
                            .accessibilityIdentifier("selectedActivityDate")
                        Spacer()
                        Text("\(selected.minutes) 分钟").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    if selected.bookIDs.isEmpty {
                        Text("这一天留了白，下一页随时开始。").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.vertical, 12)
                    } else {
                        ForEach(store.books.filter { selected.bookIDs.contains($0.id) }) { book in
                            Button { store.read(book) } label: { BookRow(book: book) }.buttonStyle(.plain)
                                .accessibilityIdentifier("activity-book-\(book.id)")
                        }
                    }
                }
                NavigationLink { ReadingHistoryView() } label: { Label("查看全部阅读历史", systemImage: "clock.arrow.circlepath") }
                    .font(.system(size: 13)).frame(minHeight: 44)
            }.padding(22)
        }.appPageStyle().navigationTitle("足迹").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let latest = calendar.startOfDay(for: Date())
                if latest != today { today = latest; selectedDate = latest }
            }
    }
    private func metric(_ value: String, unit: String) -> some View {
        VStack(spacing: 8) {
            Text(value).font(.system(size: 27, design: .serif))
            Text(unit).font(.system(size: 9)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.green).frame(maxWidth: .infinity)
    }
    private func color(_ minutes: Int) -> Color {
        minutes == 0 ? Palette.line.opacity(0.6) : Palette.green.opacity(minutes < 20 ? 0.25 : minutes < 35 ? 0.48 : minutes < 50 ? 0.72 : 1)
    }
}
