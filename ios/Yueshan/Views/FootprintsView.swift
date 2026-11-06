import SwiftUI
import Charts

struct FootprintsView: View {
    var title = "足迹"
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()
    @State private var period = ActivityPeriod.day
    @State private var selectedDate = Calendar.current.startOfDay(for: Date())
    @State private var annualBars = false
    @State private var showAll = false
    private var calendar: Calendar { .current }
    private var report: ActivityReport {
        ActivityReport(sessions: store.isDemo ? ActivitySession.demo(books: store.books, now: now, calendar: calendar) : store.activitySessions.filter { ($0.kind ?? .reading) == .reading }, now: now, period: period, calendar: calendar)
    }
    var body: some View {
        let data = report
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppPageHeader(title: "每一页，都有足迹。", subtitle: store.isDemo ? "阅读统计 · 示例数据，非实际计时" : "真实阅读记录 · 前台阅读，空闲 60 秒停止计时 · 朗读单独记录", icon: "calendar")
                Picker("统计周期", selection: $period) {
                    ForEach(ActivityPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("activityPeriod")
                summary(data)
                AppSettingsCard(chartTitle, icon: "chart.bar") {
                    Text(rangeLabel(data.interval)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if period == .year {
                        Picker("年度图表", selection: $annualBars) {
                            Text("全年热力图").tag(false); Text("月度柱状图").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    if period == .month { monthGrid(data) }
                    else if period == .year && !annualBars { yearGrid(data) }
                    else { bars(data) }
                    if period == .month || (period == .year && !annualBars) { legend }
                }
                ranking(data)
                dayDetail(data)
                NavigationLink { ReadingHistoryView() } label: { Label("查看全部阅读历史", systemImage: "clock.arrow.circlepath") }
                    .font(.system(size: 13)).frame(minHeight: 44)
            }.padding(22)
        }.appPageStyle().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .onChange(of: period) { _, _ in selectedDate = calendar.startOfDay(for: now); showAll = false }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
            .onAppear { refresh() }
    }
    private var chartTitle: String {
        switch period { case .day: "小时阅读分布"; case .week: "本周阅读趋势"; case .month: "月历热力图"; case .year: "年度阅读趋势" }
    }
    private func refresh() {
        let latest = Date()
        if !calendar.isDate(latest, inSameDayAs: now) { selectedDate = calendar.startOfDay(for: latest) }
        now = latest
    }
    private func rangeLabel(_ range: DateInterval) -> String {
        range.start.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))) + " — " + range.end.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
    }
    private func summary(_ data: ActivityReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(period == .day ? "今日阅读时长" : "本\(period.title)阅读时长").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text(ActivityReport.duration(data.seconds)).font(.system(size: 29, weight: .medium, design: .serif))
                .accessibilityIdentifier("activityTotal")
            Text(data.changePercent.map { "\(period.comparison) \($0 >= 0 ? "+" : "")\($0)%" } ?? "\(period.comparison) · 暂无对比")
                .font(.system(size: 12)).accessibilityIdentifier("activityComparison")
            HStack {
                Text("读过 \(data.ranking().count) 本")
                Spacer()
                Text("阅读 \(data.readingDays) 天")
                Spacer()
                Text("日均 \(ActivityReport.duration(data.seconds / Double(data.elapsedDays)))")
            }.font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.green).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.soft, in: .rect(cornerRadius: 18))
    }
    private func buckets(_ data: ActivityReport) -> [DateInterval] {
        let component: Calendar.Component = period == .day ? .hour : period == .year ? .month : .day
        let count = period == .day ? 24 : period == .year ? 12 : 7
        return (0..<count).map { offset in
            let start = calendar.date(byAdding: component, value: offset, to: data.interval.start)!
            return DateInterval(start: start, end: calendar.date(byAdding: component, value: 1, to: start)!)
        }
    }
    private func bars(_ data: ActivityReport) -> some View {
        let ranges = buckets(data)
        return VStack(spacing: 10) {
            Chart(Array(ranges.enumerated()), id: \.offset) { index, range in
                BarMark(x: .value("时间", index), y: .value("分钟", data.total(in: clipped(range)) / 60))
                    .foregroundStyle(Palette.green).cornerRadius(3)
                    .accessibilityLabel(bucketLabel(range.start)).accessibilityValue(ActivityReport.duration(data.total(in: clipped(range))))
            }.chartXAxis {
                AxisMarks(values: Array(stride(from: 0, to: ranges.count, by: period == .day ? 6 : 1))) { value in
                    AxisValueLabel { if let i = value.as(Int.self), ranges.indices.contains(i) { Text(bucketLabel(ranges[i].start)).font(.system(size: 9)) } }
                }
            }.chartYAxis { AxisMarks(position: .leading) }.frame(height: 165)
                .accessibilityIdentifier("activityBars")
            Text("纵轴：分钟\(period == .day ? " · 横轴：小时" : "")").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if period != .day {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(Array(ranges.enumerated()), id: \.offset) { i, range in
                        Button(bucketLabel(range.start)) { selectedDate = range.start }
                            .font(.system(size: 11)).frame(minWidth: 36, minHeight: 44)
                            .disabled(range.start > now).accessibilityIdentifier("activity-bucket-\(i)")
                    } }
                }
                Text(period == .year ? "点月份查看当月首日记录" : "点日期查看当天明细").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }
    private func clipped(_ range: DateInterval) -> DateInterval {
        let end = min(range.end, now)
        return .init(start: min(range.start, end), end: end)
    }
    private func bucketLabel(_ date: Date) -> String {
        if period == .day { return "\(calendar.component(.hour, from: date))" }
        if period == .year { return "\(calendar.component(.month, from: date))月" }
        return ["日", "一", "二", "三", "四", "五", "六"][calendar.component(.weekday, from: date) - 1]
    }
    private func monthGrid(_ data: ActivityReport) -> some View {
        let start = data.interval.start
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            ForEach(0..<(offset + count), id: \.self) { index in
                if index < offset { Color.clear.frame(height: 36) }
                else { dateCell(calendar.date(byAdding: .day, value: index - offset, to: start)!, data: data, showNumber: true) }
            }
        }.accessibilityIdentifier("activityMonthGrid")
    }
    private func yearGrid(_ data: ActivityReport) -> some View {
        let start = ActivityPeriod.week.start(containing: data.interval.start, calendar: calendar)
        let yearEnd = calendar.date(byAdding: .year, value: 1, to: data.interval.start)!
        let count = calendar.dateComponents([.day], from: start, to: yearEnd).day!
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<((count + 6) / 7), id: \.self) { week in
                        let days = (0..<7).map { calendar.date(byAdding: .day, value: week * 7 + $0, to: start)! }
                        VStack(spacing: 4) {
                            Text(days.first(where: { calendar.component(.day, from: $0) == 1 }).map { "\(calendar.component(.month, from: $0))月" } ?? " ")
                                .font(.system(size: 8)).foregroundStyle(Palette.muted).frame(height: 16)
                            ForEach(days, id: \.self) { date in
                                if date < data.interval.start || date >= yearEnd { Color.clear.frame(width: 24, height: 24) }
                                else { dateCell(date, data: data, showNumber: false).frame(width: 24) }
                            }
                        }.frame(width: 24)
                    }
                }.padding(3)
            }.accessibilityIdentifier("activityYearGrid")
            Text("每列周一至周日 · 横向滑动查看全年 · 点日期查看明细")
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
    private func dateCell(_ date: Date, data: ActivityReport, showNumber: Bool) -> some View {
        let duration = data.total(in: data.dayInterval(date))
        return Button { selectedDate = date } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(date > now ? Palette.line.opacity(0.2) : heatColor(duration))
                if showNumber { Text("\(calendar.component(.day, from: date))").font(.system(size: 11)).foregroundStyle(duration > 30 * 60 ? .white : Palette.green) }
            }.frame(height: showNumber ? 36 : 24)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(calendar.isDate(date, inSameDayAs: selectedDate) ? Palette.accent : .clear, lineWidth: 2))
        }.buttonStyle(.plain).disabled(date > now)
            .accessibilityLabel(date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
            .accessibilityValue(ActivityReport.duration(duration))
            .accessibilityIdentifier("activity-date-\(calendar.component(.day, from: date))\(showNumber ? "" : "-\(calendar.component(.month, from: date))")")
    }
    private func heatColor(_ seconds: TimeInterval) -> Color {
        seconds == 0 ? Palette.line : Palette.green.opacity(seconds <= 900 ? 0.2 : seconds <= 1800 ? 0.4 : seconds <= 3600 ? 0.7 : 1)
    }
    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("颜色越深，阅读越久").font(.system(size: 10)).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                ForEach(Array(zip([0.0, 600, 1200, 2400, 4000], ["0", "1–15", "16–30", "31–60", "60+"])), id: \.0) { value, label in
                    VStack(spacing: 5) { RoundedRectangle(cornerRadius: 3).fill(heatColor(value)).frame(height: 8); Text(label).font(.system(size: 8)) }
                }
                Text("分钟").font(.system(size: 8))
            }.foregroundStyle(Palette.muted)
        }
    }
    private func ranking(_ data: ActivityReport) -> some View {
        let totals = data.ranking()
        return AppSettingsCard("书籍时长排行", icon: "chart.bar.xaxis") {
            Text("按本\(period.title)阅读时长排序").font(.system(size: 11)).foregroundStyle(Palette.muted).accessibilityIdentifier("activityRankingPeriod")
            if totals.isEmpty { Text("这个周期还没有阅读记录。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            ForEach(Array((showAll ? totals : Array(totals.prefix(5))).enumerated()), id: \.element.id) { index, item in
                if let book = store.books.first(where: { $0.id == item.id }) {
                    NavigationLink { ActivityBookView(book: book, report: data) } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.system(size: 13)).frame(width: 14)
                            BookCover(book: book, width: 35)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(book.title).font(.system(size: 13, weight: .medium))
                                Text("\(ActivityReport.duration(item.seconds)) · \(Int((item.seconds / max(1, data.seconds) * 100).rounded()))%")
                                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
                                ProgressView(value: item.seconds, total: max(1, data.seconds)).tint(Palette.green)
                            }
                        }.foregroundStyle(Palette.green).padding(.vertical, 4)
                    }.buttonStyle(.plain).accessibilityIdentifier("activity-rank-\(index)")
                }
            }
            if totals.count > 5 { Button(showAll ? "收起排行" : "查看全部排行") { showAll.toggle() }.font(.system(size: 12)).frame(minHeight: 44).accessibilityIdentifier("activityAllRanks") }
        }
    }
    private func dayDetail(_ data: ActivityReport) -> some View {
        let totals = data.ranking(in: data.dayInterval(selectedDate))
        return AppSettingsCard("当天阅读明细", icon: "book") {
            HStack {
                Text(selectedDate.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN")))).font(.system(size: 12)).accessibilityIdentifier("selectedActivityDate")
                Spacer()
                Button("今天") { selectedDate = calendar.startOfDay(for: now) }.font(.system(size: 11)).accessibilityIdentifier("activityToday")
            }
            Text(ActivityReport.duration(data.total(in: data.dayInterval(selectedDate)))).font(.system(size: 17, design: .serif)).accessibilityIdentifier("activityDayTotal")
            if totals.isEmpty { Text("这一天留了白，下一页随时开始。").font(.system(size: 12)).foregroundStyle(Palette.muted) }
            ForEach(totals) { item in
                if let book = store.books.first(where: { $0.id == item.id }) {
                    NavigationLink { ActivityBookView(book: book, report: data) } label: {
                        HStack { Text(book.title); Spacer(); Text(ActivityReport.duration(item.seconds)).foregroundStyle(Palette.muted) }.font(.system(size: 12)).frame(minHeight: 44)
                    }.accessibilityIdentifier("activity-book-\(book.id)")
                }
            }
        }
    }
}

private struct ActivityBookView: View {
    @EnvironmentObject private var store: LibraryStore
    let book: Book
    let report: ActivityReport
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) { BookCover(book: book, width: 75); AppPageHeader(title: book.title, subtitle: "本\(report.period.title) · \(store.isDemo ? "示例阅读记录" : "真实阅读记录")", icon: "clock") }
                Text(ActivityReport.duration(report.total(in: report.interval, bookID: book.id))).font(.system(size: 25, design: .serif))
                Button { store.read(book) } label: { Label("继续阅读", systemImage: "book") }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("activityResume")
                ForEach(report.sessions.filter { $0.bookID == book.id && $0.duration(in: report.interval) > 0 }.sorted { $0.start > $1.start }, id: \.start) { session in
                    HStack {
                        Text(session.start, format: .dateTime.month().day().hour().minute().locale(Locale(identifier: "zh_CN")))
                        Spacer()
                        Text(ActivityReport.duration(session.duration(in: report.interval)))
                    }.font(.system(size: 12)).padding(.vertical, 8)
                }
            }.padding(22)
        }.appPageStyle().navigationTitle("阅读记录").navigationBarTitleDisplayMode(.inline)
    }
}
