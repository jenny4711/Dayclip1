//
//  ContentView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import Combine
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import UIKit
import QuartzCore
import CoreMedia

 // MARK: -  Rotation Math Helpers

private func normalizedQuarterTurns(_ value: Int) -> Int {
    let mod = value % 4
    return mod >= 0 ? mod : mod + 4
}

 // MARK: - rotationTransform
private func rotationTransform(for quarterTurns: Int, size: CGSize) -> CGAffineTransform {
    let turns = normalizedQuarterTurns(quarterTurns)
    switch turns {
    case 0:
        return .identity
    case 1:
        return CGAffineTransform(translationX: size.height, y: 0).rotated(by: .pi / 2)
    case 2:
        return CGAffineTransform(translationX: size.width, y: size.height).rotated(by: .pi)
    case 3:
        return CGAffineTransform(translationX: 0, y: size.width).rotated(by: -.pi / 2)
    default:
        return .identity
    }
}

 // MARK: - defaultTrimDuration
private let defaultTrimDuration: Double = 2.0

 // MARK: - ClipPlacement
private struct ClipPlacement {
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
}

 // MARK: - TimelineThumbnailRequest
private struct TimelineThumbnailRequest: Sendable {
    let clipIndex: Int
    let assetURL: URL
    let renderSize: CGSize
    let rotationQuarterTurns: Int
    let times: [CMTime]
}

 // MARK: - TimelineThumbnailResult
private struct TimelineThumbnailResult: @unchecked Sendable {
    let frameIndex: Int
    let image: CGImage
}

 // MARK: - TimelineThumbnailGenerator
private enum TimelineThumbnailGenerator {
    private static let maxThumbnailDimension: CGFloat = 320

    static func generate(for request: TimelineThumbnailRequest) -> [TimelineThumbnailResult] {
        let asset = AVAsset(url: request.assetURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = scaledSize(for: request.renderSize)

        var outputs: [TimelineThumbnailResult] = []
        for (index, time) in request.times.enumerated() {
            if Task.isCancelled { break }
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                outputs.append(TimelineThumbnailResult(frameIndex: index, image: cgImage))
            } catch {
                continue
            }
        }
        return outputs
    }

    private static func scaledSize(for renderSize: CGSize) -> CGSize {
        guard renderSize.width > 0, renderSize.height > 0 else {
            return CGSize(width: maxThumbnailDimension, height: maxThumbnailDimension)
        }

        let maxSide = max(renderSize.width, renderSize.height)
        guard maxSide > maxThumbnailDimension else {
            return renderSize
        }

        let scale = maxThumbnailDimension / maxSide
        return CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
    }
}

 // MARK: - extension UIImage
private extension UIImage {
    func rotatedByQuarterTurns(_ turns: Int) -> UIImage {
        let normalized = normalizedQuarterTurns(turns)
        guard normalized != 0 else { return self }

        let angle: CGFloat
        let newSize: CGSize
        switch normalized {
        case 1:
            angle = .pi / 2
            newSize = CGSize(width: size.height, height: size.width)
        case 2:
            angle = .pi
            newSize = size
        case 3:
            angle = -.pi / 2
            newSize = CGSize(width: size.height, height: size.width)
        default:
            angle = 0
            newSize = size
        }

        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return self
        }

        switch normalized {
        case 1:
            context.translateBy(x: newSize.width, y: 0)
        case 2:
            context.translateBy(x: newSize.width, y: newSize.height)
        case 3:
            context.translateBy(x: 0, y: newSize.height)
        default:
            break
        }

        context.rotate(by: angle)
        draw(at: CGPoint(x: 0, y: 0))
        let rotated = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rotated ?? self
    }
}
 // MARK: - contentView
struct ContentView: View {
    @StateObject private var viewModel = CalendarViewModel()
    @State private var pendingDaySelection: CalendarDay?
    @State private var isShowingPicker = false
    @State private var selectedPickerItems: [PhotosPickerItem] = []
    @State private var showReplaceAlert = false
    @State private var isSavingClip = false
    @State private var errorMessage: String?
    @State private var presentedClip: DayClip?
    @State private var editorDraft: EditorDraft?
    @State private var monthlyPlaybackSession: MonthlyPlaybackSession?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 40) {
                    ForEach(viewModel.months) { month in
                        CalendarMonthPage(
                            month: month,
                            viewportHeight: geometry.size.height,
                            viewportWidth: geometry.size.width,
                            clipCount: viewModel.clipCount(for: month),
                            onDaySelected: handleDaySelection,
                            onPlayMonth: startMonthlyPlayback
                        )
                            .frame(width: geometry.size.width)
                    }
                }
                .padding(.vertical, 32)
            }
            .photosPicker(
                isPresented: $isShowingPicker,
                selection: $selectedPickerItems,
                maxSelectionCount: 1,
                matching: .videos,
                photoLibrary: .shared()
            )
            .onChange(of: selectedPickerItems) { _, newItems in
                Task { await handlePickerItems(newItems) }
            }
            .onChange(of: isShowingPicker) { _, isPresented in
                if !isPresented && selectedPickerItems.isEmpty {
                    resetPendingSelection()
                }
            }
            .alert(
                "기존 영상을 교체하시겠습니까?",
                isPresented: $showReplaceAlert,
                presenting: pendingDaySelection
            ) { _ in
                Button("교체", role: .destructive) {
                    presentPickerForPendingDay()
                }
                Button("취소", role: .cancel) {
                    pendingDaySelection = nil
                }
            } message: { _ in
                Text("선택한 날짜의 기존 영상을 교체합니다.")
            }
            .background(Color.black.ignoresSafeArea())
            .overlay {
                if isSavingClip {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        ProgressView("영상을 저장 중입니다…")
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .alert("문제가 발생했어요", isPresented: Binding(get: {
            errorMessage != nil
        }, set: { newValue in
            if !newValue {
                errorMessage = nil
            }
        }), actions: {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
        .fullScreenCover(item: $presentedClip) { clip in
            VideoPlayerView(
                clip: clip,
                onClose: {
                    pendingDaySelection = nil
                },
                onReplace: {
                    presentedClip = nil
                    if pendingDaySelection == nil {
                        pendingDaySelection = viewModel.day(for: clip.date)
                    }
                    showReplaceAlert = true
                },
                onDelete: {
                    Task {
                        await deleteClip(clip)
                    }
                },
                onReedit: {
                    presentedClip = nil
                    presentEditorForExistingClip(clip)
                }
            )
            .interactiveDismissDisabled()
        }
        .fullScreenCover(item: $editorDraft) { draft in
            MultiClipEditorView(
                draft: draft,
                onCancel: {
                    editorDraft = nil
                    resetPendingSelection()
                },
                onComplete: { composition in
                    editorDraft = nil
                    Task {
                        await handleEditorCompletion(composition)
                    }
                }
            )
        }
        .fullScreenCover(item: $monthlyPlaybackSession) { session in
            MonthlyPlaybackView(session: session) {
                monthlyPlaybackSession = nil
            }
        }
        .preferredColorScheme(.dark)
       
        .task {
            await viewModel.loadPersistedClips()
        }
    }

    private func handleDaySelection(_ day: CalendarDay) {
        guard day.isSelectable else { return }
        pendingDaySelection = day

        if day.hasClip, let clip = viewModel.clip(for: day.date) {
            presentedClip = clip
        } else {
            presentPickerForPendingDay()
        }
    }

    private func startMonthlyPlayback(for month: CalendarMonth) {
        let clips = viewModel.clips(for: month)
        guard !clips.isEmpty else {
            errorMessage = "이 달에는 저장된 영상이 없습니다."
            return
        }
        monthlyPlaybackSession = MonthlyPlaybackSession(monthDate: month.date, clips: clips)
    }

    private func presentPickerForPendingDay() {
        guard pendingDaySelection != nil else { return }
        showReplaceAlert = false
        selectedPickerItems = []
        isShowingPicker = true
    }

    private func resetPendingSelection() {
        pendingDaySelection = nil
        selectedPickerItems = []
        isShowingPicker = false
        showReplaceAlert = false
    }

    private func handlePickerItems(_ items: [PhotosPickerItem]) async {
        guard let item = items.first else { return }

        let day = await MainActor.run { pendingDaySelection }

        guard let day else {
            await MainActor.run { selectedPickerItems = [] }
            return
        }

        VideoStorageManager.shared.clearEditingSession(for: day.date)

        await MainActor.run {
            editorDraft = EditorDraft(date: day.date, sources: [.picker(item)])
            isShowingPicker = false
            selectedPickerItems = []
        }
    }

    private func deleteClip(_ clip: DayClip) async {
        await MainActor.run {
            isSavingClip = true
        }

        do {
            try VideoStorageManager.shared.removeClip(clip)
            VideoStorageManager.shared.clearEditingSession(for: clip.date)
            try await ClipStore.shared.deleteClip(for: clip.date)
            await MainActor.run {
                viewModel.removeClip(for: clip.date)
                resetPendingSelection()
            }
        } catch {
            await MainActor.run {
                errorMessage = "영상을 삭제하지 못했습니다.\n\(error.localizedDescription)"
            }
        }

        await MainActor.run {
            isSavingClip = false
        }
    }

    private func handleEditorCompletion(_ composition: EditorCompositionDraft) async {
        let day = await MainActor.run { pendingDaySelection }

        guard let day else {
            await MainActor.run {
                errorMessage = "편집을 저장할 수 있는 날짜를 찾지 못했습니다."
                resetPendingSelection()
            }
            return
        }

        await MainActor.run {
            isSavingClip = true
        }

        do {
            let clip = try await VideoStorageManager.shared.exportComposition(
                draft: composition,
                date: day.date
            )

            try await ClipStore.shared.upsert(clip.metadata)

            await MainActor.run {
                viewModel.setClip(clip)
                presentedClip = clip
                resetPendingSelection()
            }
        } catch {
            await MainActor.run {
                errorMessage = "편집본을 저장하지 못했습니다.\n\(error.localizedDescription)"
                resetPendingSelection()
            }
        }

        await MainActor.run {
            isSavingClip = false
        }
    }

    private func presentEditorForExistingClip(_ clip: DayClip) {
        let sources = VideoStorageManager.shared.loadEditingSources(for: clip.date)
        guard !sources.isEmpty else {
            errorMessage = "편집 세션을 불러올 수 없습니다. 새 영상을 선택해 주세요."
            return
        }

        let day = viewModel.day(for: clip.date)
        let today = Date()
        let calendar = Calendar.current
        let calendarDay = day ?? CalendarDay(
            date: clip.date,
            kind: .current,
            isToday: calendar.isDate(clip.date, inSameDayAs: today),
            isFuture: clip.date > today,
            hasClip: true,
            thumbnail: clip.thumbnail
        )

        pendingDaySelection = calendarDay
        editorDraft = EditorDraft(date: clip.date, sources: sources.map { .file($0) })
    }
}
 // MARK: - Calendar MonthPage
private struct CalendarMonthPage: View {
    let month: CalendarMonth
    let viewportHeight: CGFloat
    let viewportWidth: CGFloat
    let clipCount: Int
    let onDaySelected: (CalendarDay) -> Void
    let onPlayMonth: (CalendarMonth) -> Void

    private let horizontalPadding: CGFloat = 20
    private let cellSpacing: CGFloat = 6

    var body: some View {
        let availableWidth = viewportWidth - (horizontalPadding * 2)
        let minimumCellWidth: CGFloat = 45
        let computedCellWidth = (availableWidth - (cellSpacing * 6)) / 7
        let cellWidth = max(computedCellWidth, minimumCellWidth)
        let cellHeight: CGFloat = 81
        let gridHeight = month.gridHeight(cellHeight: cellHeight, rowSpacing: cellSpacing)

        let columns: [GridItem] = Array(repeating: GridItem(.fixed(cellWidth), spacing: cellSpacing), count: 7)

        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(month.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
//                    Text(month.yearTitle)
//                        .font(.footnote)
//                        .foregroundStyle(.gray)
                }

                Spacer()

                Button {
                    onPlayMonth(month)
                } label: {
                    Label("전체 재생", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.18)))
                .disabled(clipCount == 0)
                .opacity(clipCount == 0 ? 0.4 : 1.0)
              
            }
            .padding(.horizontal, horizontalPadding)

            VStack(spacing: 12) {
                HStack(spacing: cellSpacing) {
                    ForEach(Weekday.allCases, id: \.self) { weekday in
                        Text(weekday.displaySymbol)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity)
                    }
                }
               

                LazyVGrid(columns: columns, spacing: cellSpacing) {
                    ForEach(month.days) { day in
                        DayCellView(day: day, size: CGSize(width: cellWidth, height: cellHeight), onTap: onDaySelected)
                            
                    }
                }
                .frame(height: gridHeight)
            }
            .padding(.horizontal, horizontalPadding)

            Spacer(minLength: 0)
        }
        .frame(height: viewportHeight)
        
    }
}
 // MARK: - DayCellView(Day)
private struct DayCellView: View {
    let day: CalendarDay
    let size: CGSize
    let onTap: (CalendarDay) -> Void

    private let cornerRadius: CGFloat = 15

    var body: some View {
        Group {
            if day.isSelectable {
                Button {
                    onTap(day)
                } label: {
                    cellBody
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                cellBody
            }
        }
    }

    // MARK: - Inside of DayCell
    private var cellBody: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(day.backgroundColor)

            if let thumbnail = day.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(day.displayText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(day.textColor)
                    .shadow(color: Color.black.opacity(0.35), radius: 1, x: 0, y: 0)

                Spacer()

                if day.hasClip {
                    Image(systemName: "video.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 0)
                } else if day.shouldShowPlus {
                    Image(systemName: "plus")
                        .font(.headline)
                        .foregroundStyle(.gray)
                }
            }
            .padding(10)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .opacity(day.opacity)
    }
}


 // MARK: - CalendarMonthPage (title,yearTitle,func)
private struct CalendarMonth: Identifiable {
    let id: UUID
    let date: Date
    let days: [CalendarDay]

    init(id: UUID = UUID(), date: Date, days: [CalendarDay]) {
        self.id = id
        self.date = date
        self.days = days
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "LLLL"
        return formatter.string(from: date).capitalized
    }

    var yearTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }

    var rowCount: Int {
        max(days.count / 7, 0)
    }

    func gridHeight(cellHeight: CGFloat, rowSpacing: CGFloat) -> CGFloat {
        let rows = rowCount
        guard rows > 0 else { return 0 }
        let totalSpacing = CGFloat(max(rows - 1, 0)) * rowSpacing
        return CGFloat(rows) * cellHeight + totalSpacing
    }
}

 // MARK: - CalenderMonthPage(thumbnail,text,bg,color,opacity)
private struct CalendarDay: Identifiable {
    let id: UUID
    let date: Date
    let kind: DayKind
    let isToday: Bool
    let isFuture: Bool
    let hasClip: Bool
    let thumbnail: UIImage?

    init(id: UUID = UUID(), date: Date, kind: DayKind, isToday: Bool, isFuture: Bool, hasClip: Bool, thumbnail: UIImage?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.isToday = isToday
        self.isFuture = isFuture
        self.hasClip = hasClip
        self.thumbnail = thumbnail
    }

    var displayText: String {
        let day = Calendar.current.component(.day, from: date)
        return "\(day)"
    }

    var backgroundColor: Color {
        switch kind {
        case .current:
            return Color(red: 36/255, green: 36/255, blue: 36/255)
        case .previous, .next:
            return Color(red: 46/255, green: 46/255, blue: 46/255).opacity(0.35)
        }
    }

    var textColor: Color {
        switch kind {
        case .current:
            return isFuture ? .gray.opacity(0.45) : .white
        case .previous, .next:
            return .gray.opacity(0.6)
        }
    }

    var opacity: Double {
        switch kind {
        case .current:
            return 1.0
        case .previous, .next:
            return 0.4
        }
    }

    var isSelectable: Bool {
        kind == .current && !isFuture
    }

    var shouldShowPlus: Bool {
        !hasClip && isSelectable
    }

    func updating(hasClip newValue: Bool, thumbnail: UIImage?) -> CalendarDay {
        CalendarDay(id: id, date: date, kind: kind, isToday: isToday, isFuture: isFuture, hasClip: newValue, thumbnail: thumbnail)
    }

    enum DayKind {
        case previous
        case current
        case next
    }
}

 // MARK: - CalendarViewModel
@MainActor
private final class CalendarViewModel: ObservableObject {
    @Published var months: [CalendarMonth] = []
    private var clips: [Date: DayClip] = [:]
    private let clipStore = ClipStore.shared

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale.current
        calendar.firstWeekday = 1
        return calendar
    }()

    init() {
        generateMonths()
    }

    func loadPersistedClips() async {
        do {
            let metadata = try await clipStore.fetchAll()
            let manager = VideoStorageManager.shared
            var restored: [Date: DayClip] = [:]

            for item in metadata {
                if let clip = manager.rebuildClip(from: item) {
                    restored[normalizedDate(item.date)] = clip
                } else {
                    try await clipStore.deleteClip(for: item.date)
                }
            }

            clips = restored
            generateMonths()
        } catch {
            #if DEBUG
            print("Failed to load clips: \(error)")
            #endif
        }
    }

    private func generateMonths() {
        let today = Date()
        guard let startDate = calendar.date(byAdding: .month, value: -5, to: today) else { return }

        var generatedMonths: [CalendarMonth] = []

        guard let endDate = calendar.startOfMonth(for: today),
              let startMonth = calendar.startOfMonth(for: startDate) else {
            months = []
            return
        }

        var currentMonth = startMonth
        while currentMonth <= endDate {
            if let monthRange = calendar.range(of: .day, in: .month, for: currentMonth) {
                let days = buildDays(for: currentMonth, dayRange: monthRange, today: today)
                generatedMonths.append(CalendarMonth(date: currentMonth, days: days))
            }

            guard let nextMonth = calendar.startOfNextMonth(for: currentMonth) else { break }
            currentMonth = nextMonth
        }

        months = Array(generatedMonths.reversed())
    }

    func setClip(_ clip: DayClip) {
        let key = normalizedDate(clip.date)
        clips[key] = clip
        updateDay(for: clip.date) { day in
            day.updating(hasClip: true, thumbnail: clip.thumbnail)
        }
    }

    func clip(for date: Date) -> DayClip? {
        clips[normalizedDate(date)]
    }

    func removeClip(for date: Date) {
        clips[normalizedDate(date)] = nil
        updateDay(for: date) { day in
            day.updating(hasClip: false, thumbnail: nil)
        }
    }

    func day(for date: Date) -> CalendarDay? {
        guard let monthIndex = months.firstIndex(where: { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }) else {
            return nil
        }
        let month = months[monthIndex]
        return month.days.first(where: { calendar.isDate($0.date, inSameDayAs: date) })
    }

    private func buildDays(for monthStart: Date, dayRange: Range<Int>, today: Date) -> [CalendarDay] {
        var days: [CalendarDay] = []

        let leadingDays = leadingDayCount(for: monthStart)

        if leadingDays > 0 {
            for offset in stride(from: leadingDays, to: 0, by: -1) {
                if let date = calendar.date(byAdding: .day, value: -offset, to: monthStart) {
                    let isToday = calendar.isDate(date, inSameDayAs: today)
                    let isFuture = date > today
                    let clip = clips[normalizedDate(date)]
                    days.append(CalendarDay(date: date, kind: .previous, isToday: isToday, isFuture: isFuture, hasClip: clip != nil, thumbnail: clip?.thumbnail))
                }
            }
        }

        for day in dayRange {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) {
                let isToday = calendar.isDate(date, inSameDayAs: today)
                let isFuture = date > today
                let clip = clips[normalizedDate(date)]
                days.append(CalendarDay(date: date, kind: .current, isToday: isToday, isFuture: isFuture, hasClip: clip != nil, thumbnail: clip?.thumbnail))
            }
        }

        while days.count % 7 != 0 {
            if let lastDate = days.last?.date,
               let date = calendar.date(byAdding: .day, value: 1, to: lastDate) {
                let isToday = calendar.isDate(date, inSameDayAs: today)
                let isFuture = date > today
                let clip = clips[normalizedDate(date)]
                days.append(CalendarDay(date: date, kind: .next, isToday: isToday, isFuture: isFuture, hasClip: clip != nil, thumbnail: clip?.thumbnail))
            } else {
                break
            }
        }

        return days
    }

    private func leadingDayCount(for monthStart: Date) -> Int {
        let weekday = calendar.component(.weekday, from: monthStart)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private func updateDay(for date: Date, transform: (CalendarDay) -> CalendarDay) {
        guard let monthIndex = months.firstIndex(where: { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }) else { return }

        let month = months[monthIndex]
        if let dayIndex = month.days.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            var days = month.days
            days[dayIndex] = transform(month.days[dayIndex])
            months[monthIndex] = CalendarMonth(id: month.id, date: month.date, days: days)
        }
    }

    private func normalizedDate(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    func clipCount(for month: CalendarMonth) -> Int {
        guard let monthStart = calendar.startOfMonth(for: month.date),
              let nextMonth = calendar.startOfNextMonth(for: monthStart) else {
            return 0
        }
        return clips.keys.filter { $0 >= monthStart && $0 < nextMonth }.count
    }

    func clips(for month: CalendarMonth) -> [DayClip] {
        guard let monthStart = calendar.startOfMonth(for: month.date),
              let nextMonth = calendar.startOfNextMonth(for: monthStart) else {
            return []
        }
        return clips
            .filter { $0.key >= monthStart && $0.key < nextMonth }
            .sorted { $0.key < $1.key }
            .map { $0.value }
    }
}

// MARK: - enum Weekday
private enum Weekday: CaseIterable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    var displaySymbol: String {
        switch self {
        case .sunday: return "SUN"
        case .monday: return "MON"
        case .tuesday: return "TUE"
        case .wednesday: return "WED"
        case .thursday: return "THU"
        case .friday: return "FRI"
        case .saturday: return "SAT"
        }
    }
}

// MARK: - Calendar Date Helpers
private extension Calendar {
    func startOfMonth(for date: Date) -> Date? {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components)
    }

    func startOfNextMonth(for date: Date) -> Date? {
        guard let month = self.date(byAdding: .month, value: 1, to: date) else { return nil }
        return startOfMonth(for: month)
    }
}

// MARK: - Day Clip Model
private struct DayClip: Identifiable {
    let id = UUID()
    let date: Date
    let videoURL: URL
    let thumbnailURL: URL
    let thumbnail: UIImage
    let createdAt: Date
}


// MARK: - Monthly Playback Session Model
private struct MonthlyPlaybackSession: Identifiable {
    let id = UUID()
    let monthDate: Date
    let clips: [DayClip]

    var monthTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy년 M월"
        return formatter.string(from: monthDate)
    }

    var clipCount: Int {
        clips.count
    }
}

// MARK: - Day Clip Metadata Bridge
extension DayClip {
    var metadata: ClipMetadata {
        ClipMetadata(date: date, videoURL: videoURL, thumbnailURL: thumbnailURL, createdAt: createdAt)
    }
}

// MARK: - Daily Clip Player Screen
private struct VideoPlayerView: View {
    let clip: DayClip
    let onClose: () -> Void
    let onReplace: () -> Void
    let onDelete: () -> Void
    let onReedit: () -> Void
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    init(clip: DayClip, onClose: @escaping () -> Void, onReplace: @escaping () -> Void, onDelete: @escaping () -> Void, onReedit: @escaping () -> Void) {
        self.clip = clip
        self.onClose = onClose
        self.onReplace = onReplace
        self.onDelete = onDelete
        self.onReedit = onReedit
        _player = State(initialValue: AVPlayer(url: clip.videoURL))
    }

    var body: some View {
        GeometryReader { proxy in
            let safeAreaInsets = proxy.safeAreaInsets

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                AspectFillVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        activatePlaybackAudioSession()
                        player.isMuted = false
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }

                VStack(spacing: 12) {
                    HStack {
                        Button {
                            dismiss()
                            onClose()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }

                        Spacer()

                        Button {
                            shareURL = clip.videoURL
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .padding(.trailing, 4)
                    }
                    .padding(.top, safeAreaInsets.top + 6)
                    .padding(.horizontal, 20)

                    Spacer()

                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                            onReedit()
                        } label: {
                            Label("재편집", systemImage: "scissors")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.18)))

                        Button {
                            dismiss()
                            onReplace()
                        } label: {
                            Label("새 영상 선택", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle())

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("삭제", systemImage: "trash")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle(tint: Color.red.opacity(0.85)))
                        .confirmationDialog("Delete this clip?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                dismiss()
                                onDelete()
                            }
                            Button("Cancel", role: .cancel) {
                                showDeleteConfirmation = false
                            }
                        } message: {
                            Text("영상을 삭제하면 복구할 수 없습니다.")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, max(safeAreaInsets.bottom + 24, 32))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { shareURL = nil }) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            } else {
                Text("공유할 영상이 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    fileprivate func activatePlaybackAudioSession() {
        Task {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                #if DEBUG
                print("Audio session error: \(error)")
                #endif
            }
        }
    }
}

// MARK: - Player Action Button Style
private struct PlayerActionButtonStyle: ButtonStyle {
    var tint: Color = Color.white.opacity(0.2)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                tint
                    .blendMode(.plusLighter)
                    .overlay(Color.white.opacity(configuration.isPressed ? 0.15 : 0))
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
    }
}

// MARK: - Editor Clip Sources
private enum EditorClipSource {
    case picker(PhotosPickerItem)
    case file(URL)
}

// MARK: - Editor Draft Model
private struct EditorDraft: Identifiable {
    let id = UUID()
    let date: Date
    let sources: [EditorClipSource]
}

// MARK: - Editor Clip Selection Model
private struct EditorClipSelection: Identifiable {
    let id = UUID()
    let url: URL
    let order: Int
    let timeRange: CMTimeRange
    let rotationQuarterTurns: Int
}

// MARK: - Background Track Options
private struct BackgroundTrackOption: Identifiable, Hashable {
    enum Source: Hashable {
        case bundled(resource: String, ext: String)
        case file(URL)
    }

    let id: UUID
    let displayName: String
    let source: Source
    let defaultVolume: Double

    init(id: UUID = UUID(), displayName: String, source: Source, defaultVolume: Double) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.defaultVolume = defaultVolume
    }

    func resolvedURL() -> URL? {
        switch source {
        case .bundled(let resource, let ext):
            return Bundle.main.url(forResource: resource, withExtension: ext)
        case .file(let url):
            return url
        }
    }

    static let builtInOptions: [BackgroundTrackOption] = [
        BackgroundTrackOption(displayName: "Ambient Sunset", source: .bundled(resource: "AmbientSunset", ext: "mp3"), defaultVolume: 0.6),
        BackgroundTrackOption(displayName: "Gentle Wave", source: .bundled(resource: "GentleWave", ext: "mp3"), defaultVolume: 0.6),
        BackgroundTrackOption(displayName: "Lo-Fi Breeze", source: .bundled(resource: "LoFiBreeze", ext: "mp3"), defaultVolume: 0.55)
    ]
}

// MARK: - Background Track Selection
private struct BackgroundTrackSelection {
    let option: BackgroundTrackOption
    let volume: Float
}

// MARK: - Composition Draft Model
private struct EditorCompositionDraft: Identifiable {
    let id = UUID()
    let date: Date
    let clipSelections: [EditorClipSelection]
    let muteOriginalAudio: Bool
    let backgroundTrack: BackgroundTrackSelection?
    let renderSize: CGSize
}

// MARK: - Multi Clip Editor ViewModel
@MainActor
private final class MultiClipEditorViewModel: ObservableObject {
    struct EditorClip: Identifiable {
        let id = UUID()
        let order: Int
        let url: URL
        let asset: AVAsset
        let duration: Double
        let renderSize: CGSize
        var rotationQuarterTurns: Int
        var trimDuration: Double
        var trimStart: Double
        var timelineFrames: [TimelineFrame]
    }

    struct TimelineFrame: Identifiable {
        let id = UUID()
        let index: Int
        let time: Double
        let length: Double
        var thumbnail: UIImage?
    }

    @Published var clips: [EditorClip] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var player = AVPlayer()
    @Published var isPlaying = false
    @Published var isBuildingPreview = false

    private let draft: EditorDraft
    private var currentMuteOriginal = false
    private var currentBackgroundTrack: BackgroundTrackSelection?
    private var rebuildTask: Task<AVPlayerItem?, Never>?
    private var thumbnailTasks: [Task<Void, Never>] = []
    private let maxTimelineFrames = 80

    init(draft: EditorDraft) {
        self.draft = draft
        Task {
            await loadClips()
        }
    }

    var hasSelection: Bool {
        clips.contains { effectiveTrimRange(for: $0) != nil }
    }

    func rebuildPreviewPlayer(muteOriginal: Bool? = nil, backgroundTrack: BackgroundTrackSelection?? = nil) async {
        if let muteOriginal {
            currentMuteOriginal = muteOriginal
        }
        if let backgroundTrack {
            switch backgroundTrack {
            case .some(let selection):
                currentBackgroundTrack = selection
            case .none:
                currentBackgroundTrack = nil
            }
        }

        guard !clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            isBuildingPreview = false
            return
        }

        let mute = currentMuteOriginal
        let backgroundSelection = currentBackgroundTrack
        let clipsSnapshot = clips
        let renderSize = currentRenderSize

        rebuildTask?.cancel()
        isBuildingPreview = true

        rebuildTask = Task(priority: .userInitiated) {
            await MultiClipEditorViewModel.buildPreviewItem(
                clips: clipsSnapshot,
                muteOriginal: mute,
                backgroundSelection: backgroundSelection,
                renderSize: renderSize
            )
        }

        let item = await rebuildTask?.value
        guard !Task.isCancelled else { return }

        await MainActor.run {
            player.replaceCurrentItem(with: item)
            if let item, isPlaying {
                item.seek(to: .zero, completionHandler: { [weak self] _ in
                    self?.player.play()
                })
            } else if isPlaying {
                player.play()
            }
            isBuildingPreview = false
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.seek(to: .zero)
            player.play()
        }
        isPlaying.toggle()
    }

    func stopPlayback() {
        player.pause()
        isPlaying = false
    }

    func makeCompositionDraft(muteOriginalAudio: Bool, backgroundTrack: BackgroundTrackSelection?) -> EditorCompositionDraft? {
        let selections: [EditorClipSelection] = clips
            .sorted(by: { $0.order < $1.order })
            .compactMap { clip in
                guard let range = effectiveTrimRange(for: clip) else { return nil }
                return EditorClipSelection(url: clip.url,
                                           order: clip.order,
                                           timeRange: range,
                                           rotationQuarterTurns: clip.rotationQuarterTurns)
            }

        guard !selections.isEmpty else { return nil }
        return EditorCompositionDraft(
            date: draft.date,
            clipSelections: selections,
            muteOriginalAudio: muteOriginalAudio,
            backgroundTrack: backgroundTrack,
            renderSize: currentRenderSize
        )
    }

    func formatDuration(_ duration: Double) -> String {
        formatDuration(seconds: duration)
    }

    private func loadClips() async {
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        isLoading = true

        let results: [(index: Int, url: URL, asset: AVAsset, duration: Double, renderSize: CGSize)] = await withTaskGroup(of: (Int, URL, AVAsset, Double, CGSize)?.self) { group in
            for (index, source) in draft.sources.enumerated() {
                group.addTask {
                    do {
                        let storedURL: URL
                        switch source {
                        case .picker(let pickerItem):
                            guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else { return nil }
                            storedURL = try VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: movie.url)
                        case .file(let url):
                            storedURL = try VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: url)
                        }

                        let asset = AVAsset(url: storedURL)
                        let durationTime = try await asset.load(.duration)
                        let durationSeconds = durationTime.seconds
                        let videoTracks = try await asset.loadTracks(withMediaType: .video)
                        guard let primaryTrack = videoTracks.first else { return nil }
                        let naturalSize = try await primaryTrack.load(.naturalSize)
                        let transform = (try? await primaryTrack.load(.preferredTransform)) ?? .identity
                        let renderRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                        let renderSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
                        return (index, storedURL, asset, durationSeconds, renderSize == .zero ? naturalSize : renderSize)
                    } catch {
                        await MainActor.run {
                            self.errorMessage = error.localizedDescription
                        }
                        return nil
                    }
                }
            }

            var collected: [(Int, URL, AVAsset, Double, CGSize)] = []
            for await result in group {
                if let value = result {
                    collected.append(value)
                }
            }
            return collected
        }

        var storedURLs: [URL] = []
        var built: [EditorClip] = []
        for result in results.sorted(by: { $0.index < $1.index }) {
            let initialDuration = min(defaultTrimDuration, max(result.duration, 0.1))
            let frames = makeTimelineFrames(duration: result.duration)
            built.append(EditorClip(order: result.index,
                                    url: result.url,
                                    asset: result.asset,
                                    duration: result.duration,
                                    renderSize: result.renderSize,
                                    rotationQuarterTurns: 0,
                                    trimDuration: initialDuration,
                                    trimStart: 0,
                                    timelineFrames: frames))
            storedURLs.append(result.url)
        }

        clips = built
        isLoading = false

        if !storedURLs.isEmpty {
            VideoStorageManager.shared.saveEditingSources(storedURLs, for: draft.date)
        }

        scheduleThumbnailGeneration()

        await rebuildPreviewPlayer()
    }

    private func makeTimelineFrames(duration: Double) -> [TimelineFrame] {
        let totalSeconds = max(duration, 0.1)
        let interval = max(defaultTrimDuration / 2, 0.5)
        let estimatedCount = Int(ceil(totalSeconds / interval))
        let frameCount = min(max(estimatedCount, 1), maxTimelineFrames)
        let actualInterval = totalSeconds / Double(frameCount)

        return (0..<frameCount).map { index in
            let start = Double(index) * actualInterval
            let length = index == frameCount - 1 ? (totalSeconds - start) : actualInterval
            return TimelineFrame(index: index, time: start, length: max(length, 0.1), thumbnail: nil)
        }
    }

    private func scheduleThumbnailGeneration(for targetIndexes: [Int]? = nil) {
        let indexes = targetIndexes ?? Array(clips.indices)
        guard !indexes.isEmpty else { return }

        let requests: [TimelineThumbnailRequest] = indexes.compactMap { index in
            guard clips.indices.contains(index) else { return nil }
            let clip = clips[index]
            let times = clip.timelineFrames.map { frame in
                CMTime(seconds: min(frame.time + frame.length / 2, clip.duration), preferredTimescale: 600)
            }
            return TimelineThumbnailRequest(
                clipIndex: index,
                assetURL: clip.url,
                renderSize: clip.renderSize,
                rotationQuarterTurns: clip.rotationQuarterTurns,
                times: times
            )
        }

        guard !requests.isEmpty else { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            for request in requests {
                if Task.isCancelled { return }
                let results = TimelineThumbnailGenerator.generate(for: request)
                if results.isEmpty { continue }

                await MainActor.run { [weak self, request, results] in
                    guard let self else { return }
                    guard self.clips.indices.contains(request.clipIndex) else { return }

                    for result in results {
                        guard self.clips[request.clipIndex].timelineFrames.indices.contains(result.frameIndex) else { continue }
                        let baseImage = UIImage(cgImage: result.image)
                        let finalImage = baseImage.rotatedByQuarterTurns(request.rotationQuarterTurns)
                        self.clips[request.clipIndex].timelineFrames[result.frameIndex].thumbnail = finalImage
                    }
                }
            }
        }

        thumbnailTasks.append(task)
    }


    private func formatDuration(seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.toNearestOrAwayFromZero))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func buildPreviewItem(clips: [EditorClip],
                                         muteOriginal: Bool,
                                         backgroundSelection: BackgroundTrackSelection?,
                                         renderSize: CGSize) async -> AVPlayerItem? {
        guard !clips.isEmpty else { return nil }

        let mixComposition = AVMutableComposition()
        guard let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        videoTrack.preferredTransform = .identity
        let originalAudioTrack = muteOriginal ? nil : mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var audioInputParameters: [AVMutableAudioMixInputParameters] = []
        if let originalAudioTrack {
            let params = AVMutableAudioMixInputParameters(track: originalAudioTrack)
            params.setVolume(1.0, at: .zero)
            audioInputParameters.append(params)
        }

        var cursor = CMTime.zero
        var placements: [ClipPlacement] = []

        for clip in clips.sorted(by: { $0.order < $1.order }) {
            guard let sourceVideoTrack = try? await clip.asset.loadTracks(withMediaType: .video).first else { continue }
            let baseTransform = (try? await sourceVideoTrack.load(.preferredTransform)) ?? .identity
            let combinedTransform = baseTransform.concatenating(rotationTransform(for: clip.rotationQuarterTurns, size: clip.renderSize))

            let audioTracks = muteOriginal ? nil : (try? await clip.asset.loadTracks(withMediaType: .audio))
            let sourceAudioTrack = audioTracks?.first

            let safeStart = min(max(clip.trimStart, 0), clip.duration)
            let remaining = max(clip.duration - safeStart, 0)
            let trimmedDuration = min(max(clip.trimDuration, 0.1), remaining)
            guard trimmedDuration > 0 else { continue }

            if Task.isCancelled { return nil }
            let range = CMTimeRange(start: CMTime(seconds: safeStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: trimmedDuration, preferredTimescale: 600))

            do {
                try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)
                if let originalAudioTrack, let sourceAudioTrack {
                    try originalAudioTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
                }
                let outputRange = CMTimeRange(start: cursor, duration: range.duration)
                placements.append(ClipPlacement(timeRange: outputRange, transform: combinedTransform))
                cursor = CMTimeAdd(cursor, range.duration)
            } catch {
                continue
            }
        }

        guard cursor.seconds > 0, !placements.isEmpty else {
            return nil
        }

        if let backgroundSelection, let bgURL = backgroundSelection.option.resolvedURL() {
            do {
                let bgAsset = AVAsset(url: bgURL)
                let bgTracks = try await bgAsset.loadTracks(withMediaType: .audio)
                if let sourceBG = bgTracks.first,
                   let bgTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {

                    var bgCursor = CMTime.zero
                    let bgDuration = try await bgAsset.load(.duration)

                    while bgCursor < cursor {
                        if Task.isCancelled { return nil }
                        let remaining = CMTimeSubtract(cursor, bgCursor)
                        let segmentDuration = CMTimeCompare(bgDuration, remaining) == 1 ? remaining : bgDuration
                        try bgTrack.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: sourceBG, at: bgCursor)
                        bgCursor = CMTimeAdd(bgCursor, segmentDuration)
                    }

                    let bgParams = AVMutableAudioMixInputParameters(track: bgTrack)
                    bgParams.setVolume(backgroundSelection.volume, at: .zero)
                    audioInputParameters.append(bgParams)
                }
            } catch {
                return nil
            }
        }

        let item = AVPlayerItem(asset: mixComposition)
        if !audioInputParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioInputParameters
            item.audioMix = audioMix
        }

        if let videoComposition = VideoStorageManager.shared.makeVideoComposition(for: mixComposition,
                                                                                  placements: placements,
                                                                                  renderSize: renderSize) {
            item.videoComposition = videoComposition
        }

        return item
    }

    private func rotatedSize(for clip: EditorClip) -> CGSize {
        if clip.rotationQuarterTurns % 2 == 0 {
            return clip.renderSize
        } else {
            return CGSize(width: clip.renderSize.height, height: clip.renderSize.width)
        }
    }

    private var primaryClip: EditorClip? {
        clips.sorted(by: { $0.order < $1.order }).first
    }

    var currentRenderSize: CGSize {
        guard let clip = primaryClip else {
            return CGSize(width: 1080, height: 1920)
        }
        return rotatedSize(for: clip)
    }

    func rotateClip(_ clip: EditorClip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].rotationQuarterTurns = normalizedQuarterTurns(clips[index].rotationQuarterTurns + 1)

        for frameIndex in clips[index].timelineFrames.indices {
            if let thumbnail = clips[index].timelineFrames[frameIndex].thumbnail {
                clips[index].timelineFrames[frameIndex].thumbnail = thumbnail.rotatedByQuarterTurns(1)
            }
        }

        scheduleThumbnailGeneration(for: [index])

        Task { [weak self] in
            await self?.rebuildPreviewPlayer()
        }
    }

    func updateTrimStart(clipID: UUID, start: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[index]
        let targetDuration = min(defaultTrimDuration, clip.duration)
        let maxStart = max(0, clip.duration - targetDuration)
        let clampedStart = min(max(0, start), maxStart)

        let current = clips[index]
        if abs(current.trimStart - clampedStart) < 0.01 && abs(current.trimDuration - targetDuration) < 0.01 {
            return
        }

        clips[index].trimStart = clampedStart
        clips[index].trimDuration = targetDuration

        Task { [weak self] in
            await self?.rebuildPreviewPlayer()
        }
    }

    func effectiveTrimRange(for clip: EditorClip) -> CMTimeRange? {
        let safeStart = min(max(clip.trimStart, 0), clip.duration)
        let remaining = max(clip.duration - safeStart, 0)
        let trimmedDuration = min(max(clip.trimDuration, 0.1), remaining)
        guard trimmedDuration > 0 else { return nil }
        let startTime = CMTime(seconds: safeStart, preferredTimescale: 600)
        let durationTime = CMTime(seconds: trimmedDuration, preferredTimescale: 600)
        return CMTimeRange(start: startTime, duration: durationTime)
    }

    func trimDescription(for clip: EditorClip) -> String {
        guard let range = effectiveTrimRange(for: clip) else { return "0.0s" }
        let start = range.start.seconds
        let end = CMTimeAdd(range.start, range.duration).seconds
        return "\(formatDuration(seconds: start)) - \(formatDuration(seconds: end))"
    }
}

// MARK: - Multi Clip Editor Screen
private struct MultiClipEditorView: View {
    let draft: EditorDraft
    let onCancel: () -> Void
    let onComplete: (EditorCompositionDraft) -> Void

    @StateObject private var viewModel: MultiClipEditorViewModel
    @State private var muteAudio = false
    @State private var selectedTrackID: UUID? = nil
    @State private var trackVolume: Double = 0.6
    @State private var userTrackOptions: [BackgroundTrackOption] = []
    @State private var showAudioImporter = false
    @State private var isImportingAudio = false

    private var allTrackOptions: [BackgroundTrackOption] {
        BackgroundTrackOption.builtInOptions + userTrackOptions
    }

    init(draft: EditorDraft, onCancel: @escaping () -> Void, onComplete: @escaping (EditorCompositionDraft) -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onComplete = onComplete
        _viewModel = StateObject(wrappedValue: MultiClipEditorViewModel(draft: draft))
    }

    private var selectedTrackOption: BackgroundTrackOption? {
        guard let id = selectedTrackID else { return nil }
        return allTrackOptions.first(where: { $0.id == id })
    }

    private var backgroundSelection: BackgroundTrackSelection? {
        guard let option = selectedTrackOption else { return nil }
        return BackgroundTrackSelection(option: option, volume: Float(trackVolume))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    previewSection

                    if viewModel.isLoading {
                        Spacer()
                        ProgressView("영상을 불러오는 중...")
                        Spacer()
                    } else if let error = viewModel.errorMessage, viewModel.clips.isEmpty {
                        Spacer()
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(viewModel.clips) { clip in
                                    clipTimeline(clip)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 32)
                        }
                    }
                }
            }
            .navigationTitle(formattedDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        viewModel.stopPlayback()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") {
                        if let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: backgroundSelection) {
                            viewModel.stopPlayback()
                            onComplete(draft)
                        }
                    }
                    .disabled(!viewModel.hasSelection || viewModel.isLoading || viewModel.isBuildingPreview)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            viewModel.stopPlayback()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "yyyy. MM. dd"
        return formatter.string(from: draft.date)
    }

    private var previewSection: some View {
        VStack(spacing: 12) {
            ZStack {
                AspectFillVideoPlayer(player: viewModel.player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.hasSelection {
                    Text("선택된 구간이 없습니다.")
                        .font(.footnote)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }

                if viewModel.isBuildingPreview {
                    ProgressView()
                }
            }
            .padding(.horizontal)

            HStack {
                Button {
                    viewModel.togglePlayback()
                } label: {
                    Label(viewModel.isPlaying ? "일시정지" : "재생", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.15)))
                .disabled(viewModel.player.currentItem == nil)

                Spacer()

                Button {
                    Task { await viewModel.rebuildPreviewPlayer(muteOriginal: muteAudio, backgroundTrack: .some(backgroundSelection)) }
                } label: {
                    Label("미리보기 갱신", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.1)))
            }
            .padding(.horizontal)

            Toggle(isOn: $muteAudio) {
                Label(muteAudio ? "음소거 켜짐" : "음소거 해제", systemImage: muteAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .padding(.horizontal)
            .padding(.bottom, 4)
            .onChange(of: muteAudio) { _, newValue in
                Task { await viewModel.rebuildPreviewPlayer(muteOriginal: newValue) }
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("배경 음악", selection: $selectedTrackID) {
                    Text("없음")
                        .tag(nil as UUID?)
                    ForEach(allTrackOptions) { option in
                        Text(option.displayName)
                            .tag(option.id as UUID?)
                    }
                }
                .pickerStyle(.menu)

                if selectedTrackOption != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("음악 볼륨", systemImage: "music.note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", trackVolume * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $trackVolume, in: 0...1)
                            .onChange(of: trackVolume) { _, _ in
                                Task { await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(backgroundSelection)) }
                            }
                    }
                }

                Button {
                    showAudioImporter = true
                } label: {
                    Label(isImportingAudio ? "불러오는 중..." : "파일에서 선택", systemImage: "folder.badge.plus")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.08)))
                .disabled(isImportingAudio)
            }
            .padding(.horizontal)
            .onChange(of: selectedTrackID) { _, newValue in
                if let id = newValue, let option = allTrackOptions.first(where: { $0.id == id }) {
                    trackVolume = option.defaultVolume
                }
                Task { await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(backgroundSelection)) }
            }
        }
        .task {
            userTrackOptions = VideoStorageManager.shared.loadImportedBackgroundTracks()
            if let option = selectedTrackOption {
                trackVolume = option.defaultVolume
            }
            await viewModel.rebuildPreviewPlayer(muteOriginal: muteAudio, backgroundTrack: .some(backgroundSelection))
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await importBackgroundTrack(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

private func clipTimeline(_ clip: MultiClipEditorViewModel.EditorClip) -> some View {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            Text("클립 \(clip.order + 1)")
                .font(.headline)
            Spacer()
            Text(viewModel.trimDescription(for: clip))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                viewModel.rotateClip(clip)
            } label: {
                Image(systemName: "rotate.right")
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.leading, 8)
        }

        TimelineTrimView(clip: clip) { newStart in
            viewModel.updateTrimStart(clipID: clip.id, start: newStart)
        }
        .frame(height: 86)

        HStack {
            Label("영상 길이 \(viewModel.formatDuration(clip.duration))", systemImage: "film")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct TimelineTrimView: View {
    let clip: MultiClipEditorViewModel.EditorClip
    let onTrimStartChange: (Double) -> Void

    @State private var dragOrigin: CGFloat?
    @State private var previewImage: UIImage?
    @State private var previewTime: Double = 0
    @State private var previewOffset: CGFloat = 0
    @State private var showPreview = false

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let duration = max(clip.duration, 0.1)
            let selectedDuration = max(clip.trimDuration, 0.1)
            let minWindowWidth: CGFloat = min(max(totalWidth * 0.2, 110), totalWidth)
            let rawWidth = CGFloat(selectedDuration / duration) * totalWidth
            let selectionWidth = min(max(rawWidth.isFinite ? rawWidth : totalWidth, minWindowWidth), totalWidth)
            let travel = max(totalWidth - selectionWidth, 0)
            let maxStart = max(duration - selectedDuration, 0)
            let ratio = maxStart > 0 ? clip.trimStart / maxStart : 0
            let clampedRatio = min(max(ratio, 0), 1)
            let selectionOffset = travel * CGFloat(clampedRatio)

            let nearestThumbnail: (Double) -> UIImage? = { time in
                guard !clip.timelineFrames.isEmpty else { return nil }
                let target = min(max(time, 0), clip.duration)
                let nearest = clip.timelineFrames.min(by: { abs($0.time - target) < abs($1.time - target) })
                return nearest?.thumbnail
            }

            let presentPreview: (Double, CGFloat) -> Void = { time, offset in
                let clampedTime = min(max(time, 0), clip.duration)
                previewTime = clampedTime
                previewOffset = min(max(offset, 0), travel)
                previewImage = nearestThumbnail(clampedTime)
                showPreview = previewImage != nil
            }

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(clip.timelineFrames) { frame in
                        Group {
                            if let image = frame.thumbnail {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.18)
                                    .overlay {
                                        ProgressView()
                                            .tint(.secondary)
                                            .scaleEffect(0.6)
                                    }
                            }
                        }
                        .frame(width: max(CGFloat(frame.length / duration) * totalWidth, 4), height: 80)
                        .clipped()
                    }
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                    )
                    .frame(width: selectionWidth, height: 80)
                    .offset(x: selectionOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragOrigin == nil { dragOrigin = selectionOffset }
                                let origin = dragOrigin ?? selectionOffset
                                let newOffset = min(max(origin + value.translation.width, 0), travel)
                                let newRatio = travel > 0 ? Double(newOffset / travel) : 0
                                let newStart = newRatio * maxStart
                                presentPreview(newStart, newOffset)
                                onTrimStartChange(newStart)
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                showPreview = false
                            }
                    )

                if showPreview, let previewImage {
                    let previewWidth: CGFloat = 120
                    let clampedX = min(max(previewOffset + selectionWidth / 2, previewWidth / 2), totalWidth - previewWidth / 2)

                    VStack(spacing: 6) {
                        Image(uiImage: previewImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: previewWidth, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                        Text(formatTime(previewTime))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7), in: Capsule())
                    }
                    .position(x: clampedX, y: -46)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let rawOffset = min(max(value.location.x - selectionWidth / 2, 0), travel)
                        let newRatio = travel > 0 ? Double(rawOffset / travel) : 0
                        let newStart = newRatio * maxStart
                        presentPreview(newStart, rawOffset)
                    }
                    .onEnded { _ in
                        showPreview = false
                    }
            )
        }
    }

    private func formatTime(_ time: Double) -> String {
        let total = Int(time.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private func importBackgroundTrack(from url: URL) async {
    await MainActor.run {
        isImportingAudio = true
    }

    do {
        let option = try VideoStorageManager.shared.importBackgroundTrack(from: url)
        let selection = await MainActor.run { () -> BackgroundTrackSelection? in
            let resolvedOption: BackgroundTrackOption
            if let existingIndex = userTrackOptions.firstIndex(where: { $0.source == option.source }) {
                resolvedOption = userTrackOptions[existingIndex]
            } else {
                userTrackOptions.append(option)
                resolvedOption = option
            }
            selectedTrackID = resolvedOption.id
            trackVolume = resolvedOption.defaultVolume
            return backgroundSelection
        }
        await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(selection))
    } catch {
        await MainActor.run {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    await MainActor.run {
        isImportingAudio = false
    }
}
}

// MARK: - Export Session Wrapper
private struct ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
}

// MARK: - Video Storage Manager
private final class VideoStorageManager {
    static let shared = VideoStorageManager()

    private let fileManager = FileManager.default
    private let clipsDirectory: URL
    private let backgroundTracksDirectory: URL
    private let editingSessionsDirectory: URL
    private let folderFormatter: DateFormatter
    private let calendar: Calendar = Calendar(identifier: .gregorian)

    private init() {
        let appSupport = try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let baseDirectory = appSupport?.appendingPathComponent("Dayclip", isDirectory: true) ?? fileManager.temporaryDirectory.appendingPathComponent("Dayclip", isDirectory: true)

        clipsDirectory = baseDirectory.appendingPathComponent("Clips", isDirectory: true)
        backgroundTracksDirectory = baseDirectory.appendingPathComponent("BackgroundTracks", isDirectory: true)
        editingSessionsDirectory = baseDirectory.appendingPathComponent("EditingSessions", isDirectory: true)

        if !fileManager.fileExists(atPath: clipsDirectory.path) {
            try? fileManager.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var resourceURL = clipsDirectory
            try? resourceURL.setResourceValues(values)
        }

        if !fileManager.fileExists(atPath: backgroundTracksDirectory.path) {
            try? fileManager.createDirectory(at: backgroundTracksDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var resourceURL = backgroundTracksDirectory
            try? resourceURL.setResourceValues(values)
        }

        if !fileManager.fileExists(atPath: editingSessionsDirectory.path) {
            try? fileManager.createDirectory(at: editingSessionsDirectory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var resourceURL = editingSessionsDirectory
            try? resourceURL.setResourceValues(values)
        }

        folderFormatter = DateFormatter()
        folderFormatter.calendar = calendar
        folderFormatter.locale = Locale.current
        folderFormatter.dateFormat = "yyyy-MM-dd"
    }

    func storeVideo(from item: PhotosPickerItem, for date: Date) async throws -> DayClip {
        guard let picked = try await item.loadTransferable(type: PickedMovie.self) else {
            throw VideoStorageError.assetUnavailable
        }

        let normalizedDate = calendar.startOfDay(for: date)
        let folderName = folderFormatter.string(from: normalizedDate)
        let targetDirectory = clipsDirectory.appendingPathComponent(folderName, isDirectory: true)

        if fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.removeItem(at: targetDirectory)
        }

        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let fileExtension = picked.url.pathExtension.isEmpty ? "mp4" : picked.url.pathExtension
        let storedVideoURL = targetDirectory.appendingPathComponent("clip").appendingPathExtension(fileExtension)

        try fileManager.copyItem(at: picked.url, to: storedVideoURL)

        defer {
            try? fileManager.removeItem(at: picked.url)
        }

        let thumbnailImage = try await generateThumbnail(for: storedVideoURL)
        let thumbnailURL = targetDirectory.appendingPathComponent("thumbnail.jpg")

        if let data = thumbnailImage.jpegData(compressionQuality: 0.85) {
            try data.write(to: thumbnailURL, options: .atomic)
        } else {
            throw VideoStorageError.thumbnailCreationFailed
        }

        return DayClip(date: normalizedDate, videoURL: storedVideoURL, thumbnailURL: thumbnailURL, thumbnail: thumbnailImage, createdAt: Date())
    }

    func removeClip(_ clip: DayClip) throws {
        let directory = clip.videoURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    func rebuildClip(from metadata: ClipMetadata) -> DayClip? {
        guard fileManager.fileExists(atPath: metadata.videoURL.path),
              fileManager.fileExists(atPath: metadata.thumbnailURL.path),
              let image = UIImage(contentsOfFile: metadata.thumbnailURL.path)
        else {
            return nil
        }

        return DayClip(
            date: metadata.date,
            videoURL: metadata.videoURL,
            thumbnailURL: metadata.thumbnailURL,
            thumbnail: image,
            createdAt: metadata.createdAt
        )
    }

    private func editingDirectory(for date: Date) -> URL {
        let normalized = calendar.startOfDay(for: date)
        let folderName = folderFormatter.string(from: normalized)
        return editingSessionsDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    func clearEditingSession(for date: Date) {
        let directory = editingDirectory(for: date)
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
    }

    func prepareEditingAsset(for date: Date, sourceURL: URL) throws -> URL {
        let directory = editingDirectory(for: date)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if sourceURL.deletingLastPathComponent() == directory {
            return sourceURL
        }

        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: sourceURL, to: destination)
        if sourceURL.path.hasPrefix(NSTemporaryDirectory()) {
            try? fileManager.removeItem(at: sourceURL)
        }
        return destination
    }

    struct EditingSourceRecord: Codable {
        let order: Int
        let filename: String
    }

    func saveEditingSources(_ urls: [URL], for date: Date) {
        let directory = editingDirectory(for: date)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let records = urls.enumerated().map { index, url in
            EditingSourceRecord(order: index, filename: url.lastPathComponent)
        }

        let metaURL = directory.appendingPathComponent("sources.json")
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    func loadEditingSources(for date: Date) -> [URL] {
        let directory = editingDirectory(for: date)
        let metaURL = directory.appendingPathComponent("sources.json")
        guard let data = try? Data(contentsOf: metaURL),
              let records = try? JSONDecoder().decode([EditingSourceRecord].self, from: data) else {
            return []
        }

        return records
            .sorted(by: { $0.order < $1.order })
            .compactMap { record in
                let url = directory.appendingPathComponent(record.filename)
                return fileManager.fileExists(atPath: url.path) ? url : nil
            }
    }

    func loadImportedBackgroundTracks() -> [BackgroundTrackOption] {
        guard let urls = try? fileManager.contentsOfDirectory(at: backgroundTracksDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }

        return urls.map { url in
            BackgroundTrackOption(displayName: url.deletingPathExtension().lastPathComponent,
                                  source: .file(url),
                                  defaultVolume: 0.6)
        }
        .sorted(by: { $0.displayName.lowercased() < $1.displayName.lowercased() })
    }

    func importBackgroundTrack(from sourceURL: URL) throws -> BackgroundTrackOption {
        let accessGranted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationURL = backgroundTracksDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        return BackgroundTrackOption(displayName: displayName, source: .file(destinationURL), defaultVolume: 0.6)
    }

    func exportMonthlyCompilation(for clips: [DayClip], monthDate: Date) async throws -> URL {
        guard !clips.isEmpty else {
            throw VideoProcessingError.noSelectedSegments
        }

        let mixComposition = AVMutableComposition()
        guard let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessingError.unableToCreateTrack
        }
        videoTrack.preferredTransform = .identity
        let audioTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var placements: [ClipPlacement] = []
        var renderSize = CGSize(width: 1080, height: 1920)

        for clip in clips.sorted(by: { $0.date < $1.date }) {
            let asset = AVAsset(url: clip.videoURL)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            let baseTransform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let renderRect = CGRect(origin: .zero, size: naturalSize).applying(baseTransform)
            let trackSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
            if placements.isEmpty {
                renderSize = trackSize
            }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
                if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                    try audioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
                }
                let outputRange = CMTimeRange(start: cursor, duration: duration)
                placements.append(ClipPlacement(timeRange: outputRange, transform: baseTransform))
                cursor = CMTimeAdd(cursor, duration)
            } catch {
                continue
            }
        }

        guard cursor.seconds > 0, !placements.isEmpty else {
            throw VideoProcessingError.exportFailed
        }

        let normalizedMonth = calendar.startOfMonth(for: monthDate) ?? monthDate
        let fileName = "Monthly-\(folderFormatter.string(from: normalizedMonth))-share.mov"
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessingError.exportFailed
        }

        let sessionBox = ExportSessionBox(session: exportSession)
        sessionBox.session.outputURL = outputURL
        sessionBox.session.outputFileType = .mov
        sessionBox.session.shouldOptimizeForNetworkUse = true

        if let videoComposition = makeVideoComposition(for: mixComposition, placements: placements, renderSize: renderSize) {
            sessionBox.session.videoComposition = videoComposition
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionBox.session.exportAsynchronously {
                switch sessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let error = sessionBox.session.error ?? VideoProcessingError.exportFailed
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }

        return outputURL
    }

    func exportComposition(draft: EditorCompositionDraft, date: Date) async throws -> DayClip {
        guard !draft.clipSelections.isEmpty else {
            throw VideoProcessingError.noSelectedSegments
        }

        let normalizedDate = calendar.startOfDay(for: date)
        let folderName = folderFormatter.string(from: normalizedDate)
        let targetDirectory = clipsDirectory.appendingPathComponent(folderName, isDirectory: true)

        if fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.removeItem(at: targetDirectory)
        }
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        let mixComposition = AVMutableComposition()

        guard let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoProcessingError.unableToCreateTrack
        }
        videoTrack.preferredTransform = .identity
        let audioTrack = draft.muteOriginalAudio ? nil : mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var audioInputParameters: [AVMutableAudioMixInputParameters] = []
        var placements: [ClipPlacement] = []

        for selection in draft.clipSelections.sorted(by: { $0.order < $1.order }) {
            let asset = AVAsset(url: selection.url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideo = videoTracks.first else { continue }
            let baseTransform = try await sourceVideo.load(.preferredTransform)
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let renderRect = CGRect(origin: .zero, size: naturalSize).applying(baseTransform)
            let baseSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
            let combinedTransform = baseTransform.concatenating(rotationTransform(for: selection.rotationQuarterTurns, size: baseSize))

            let audioTracks = draft.muteOriginalAudio ? nil : (try? await asset.loadTracks(withMediaType: .audio))
            let sourceAudioTrack = audioTracks?.first

            let range = selection.timeRange
            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
                if let audioTrack, let sourceAudioTrack {
                    try audioTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
                }
                let outputRange = CMTimeRange(start: cursor, duration: range.duration)
                placements.append(ClipPlacement(timeRange: outputRange, transform: combinedTransform))
                cursor = CMTimeAdd(cursor, range.duration)
            } catch {
                continue
            }
        }

        if let audioTrack {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            params.setVolume(1.0, at: CMTime.zero)
            audioInputParameters.append(params)
        }

        guard cursor.seconds > 0 else {
            throw VideoProcessingError.noSelectedSegments
        }

        if let background = draft.backgroundTrack, let bgURL = background.option.resolvedURL() {
            let bgAsset = AVAsset(url: bgURL)
            let bgTracks = try await bgAsset.loadTracks(withMediaType: .audio)
            guard let sourceBGAudio = bgTracks.first else {
                throw VideoProcessingError.backgroundTrackLoadFailed
            }

            guard let bgTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw VideoProcessingError.unableToCreateTrack
            }

            var bgCursor = CMTime.zero
            let bgDuration = try await bgAsset.load(.duration)
            while bgCursor < cursor {
                let remaining = CMTimeSubtract(cursor, bgCursor)
                let segmentDuration = CMTimeCompare(bgDuration, remaining) == 1 ? remaining : bgDuration
                try bgTrack.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: sourceBGAudio, at: bgCursor)
                bgCursor = CMTimeAdd(bgCursor, segmentDuration)
            }

            let bgParams = AVMutableAudioMixInputParameters(track: bgTrack)
            bgParams.setVolume(background.volume, at: .zero)
            audioInputParameters.append(bgParams)
        } else if draft.backgroundTrack != nil {
            throw VideoProcessingError.backgroundTrackMissing
        }

        let storedVideoURL = targetDirectory.appendingPathComponent("clip").appendingPathExtension("mp4")
        if fileManager.fileExists(atPath: storedVideoURL.path) {
            try fileManager.removeItem(at: storedVideoURL)
        }

        guard let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessingError.exportFailed
        }

        exportSession.outputURL = storedVideoURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        let sessionBox = ExportSessionBox(session: exportSession)
        if !audioInputParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioInputParameters
            sessionBox.session.audioMix = audioMix
        }

        if let videoComposition = makeVideoComposition(for: mixComposition,
                                                       placements: placements,
                                                       renderSize: draft.renderSize) {
            sessionBox.session.videoComposition = videoComposition
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionBox.session.exportAsynchronously {
                switch sessionBox.session.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    let error = sessionBox.session.error ?? VideoProcessingError.exportFailed
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
        }

        let thumbnailImage = try await generateThumbnail(for: storedVideoURL)
        let thumbnailURL = targetDirectory.appendingPathComponent("thumbnail.jpg")

        if let data = thumbnailImage.jpegData(compressionQuality: 0.85) {
            try data.write(to: thumbnailURL, options: .atomic)
        } else {
            throw VideoStorageError.thumbnailCreationFailed
        }

        return DayClip(date: normalizedDate, videoURL: storedVideoURL, thumbnailURL: thumbnailURL, thumbnail: thumbnailImage, createdAt: Date())
    }

    private func generateThumbnail(for url: URL) async throws -> UIImage {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds.isFinite ? duration.seconds : 0
        let time = CMTime(seconds: min(max(durationSeconds / 2, 0.5), 2.0), preferredTimescale: 600)
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        return UIImage(cgImage: cgImage)
    }

    func makeVideoComposition(for composition: AVMutableComposition,
                              placements: [ClipPlacement],
                              renderSize: CGSize) -> AVMutableVideoComposition? {
        guard let videoTrack = composition.tracks(withMediaType: .video).first else { return nil }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        for placement in placements.sorted(by: { $0.timeRange.start < $1.timeRange.start }) {
            layerInstruction.setTransform(placement.transform, at: placement.timeRange.start)
        }
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = renderSize

        return videoComposition
    }
}

// MARK: - Picked Movie Transfer Wrapper
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDirectory = FileManager.default.temporaryDirectory
            let targetURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: received.file, to: targetURL)
            return PickedMovie(url: targetURL)
        }
    }
}

// MARK: - Video Storage Errors
private enum VideoStorageError: LocalizedError {
    case assetUnavailable
    case thumbnailCreationFailed

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "선택한 영상을 불러올 수 없습니다."
        case .thumbnailCreationFailed:
            return "영상 썸네일을 생성할 수 없습니다."
        }
    }
}

// MARK: - Video Processing Errors
private enum VideoProcessingError: LocalizedError {
    case missingDay
    case noSelectedSegments
    case unableToCreateTrack
    case exportFailed
    case backgroundTrackMissing
    case backgroundTrackLoadFailed

    var errorDescription: String? {
        switch self {
        case .missingDay:
            return "편집을 저장할 날짜 정보를 확인할 수 없습니다."
        case .noSelectedSegments:
            return "선택된 영상 구간이 없습니다."
        case .unableToCreateTrack:
            return "영상 합성을 위한 트랙을 만들 수 없습니다."
        case .exportFailed:
            return "편집본을 내보내는 중 오류가 발생했습니다."
        case .backgroundTrackMissing:
            return "선택한 배경 음악 파일을 찾을 수 없습니다."
        case .backgroundTrackLoadFailed:
            return "배경 음악을 불러오는 중 문제가 발생했습니다."
        }
    }
}

// MARK: - Aspect Fill Video Player
private struct AspectFillVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        controller.player = player
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.videoGravity = .resizeAspectFill
    }
}

// MARK: - Monthly Playback ViewModel
private final class MonthlyPlaybackViewModel: ObservableObject {
    @Published var player = AVPlayer()
    @Published var isPlaying = false
    @Published var currentIndex = 0
    @Published var didFinish = false

    let clips: [DayClip]

    private var currentItemObserver: NSObjectProtocol?
    private var currentItem: AVPlayerItem?
    private var didStart = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M월 d일"
        return formatter
    }()

    init(clips: [DayClip]) {
        self.clips = clips
    }

    deinit {
        removeObserver()
    }

    var hasNext: Bool {
        currentIndex + 1 < clips.count
    }

    var progressLabel: String {
        guard !clips.isEmpty else { return "0/0" }
        return "\(currentIndex + 1)/\(clips.count)"
    }

    var currentClipLabel: String {
        guard clips.indices.contains(currentIndex) else { return "" }
        return Self.dateFormatter.string(from: clips[currentIndex].date)
    }

    func start() {
        guard !clips.isEmpty else {
            didFinish = true
            return
        }

        if !didStart {
            didStart = true
            currentIndex = min(currentIndex, clips.count - 1)
            didFinish = false
            activatePlaybackAudioSession()
            loadCurrentItem(playAutomatically: true)
        }
    }

    func stop() {
        player.pause()
        isPlaying = false
        didFinish = false
        removeObserver()
    }

    func togglePlayback() {
        guard !didFinish else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func skipForward() {
        guard !didFinish else { return }
        guard clips.indices.contains(currentIndex + 1) else {
            finishPlayback()
            return
        }
        currentIndex += 1
        loadCurrentItem(playAutomatically: isPlaying)
    }

    func restart() {
        guard !clips.isEmpty else { return }
        currentIndex = 0
        didFinish = false
        activatePlaybackAudioSession()
        loadCurrentItem(playAutomatically: true)
    }

    private func loadCurrentItem(playAutomatically: Bool) {
        guard clips.indices.contains(currentIndex) else {
            finishPlayback()
            return
        }

        removeObserver()
        let item = AVPlayerItem(url: clips[currentIndex].videoURL)
        currentItem = item
        player.replaceCurrentItem(with: item)
        addObserver(for: item)
        player.seek(to: .zero)

        if playAutomatically {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    private func addObserver(for item: AVPlayerItem) {
        currentItemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.handleCurrentItemEnded()
        }
    }

    private func removeObserver() {
        if let observer = currentItemObserver {
            NotificationCenter.default.removeObserver(observer)
            currentItemObserver = nil
        }
        currentItem = nil
    }

    private func handleCurrentItemEnded() {
        guard clips.indices.contains(currentIndex) else { return }

        if currentIndex + 1 < clips.count {
            currentIndex += 1
            loadCurrentItem(playAutomatically: true)
        } else {
            finishPlayback()
        }
    }

    private func finishPlayback() {
        player.pause()
        isPlaying = false
        didFinish = true
        removeObserver()
    }
}

// MARK: - Monthly Playback Screen
private struct MonthlyPlaybackView: View {
    let session: MonthlyPlaybackSession
    let onClose: () -> Void

    @StateObject private var viewModel: MonthlyPlaybackViewModel
    @State private var isExportingShare = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var shareError: String?

    init(session: MonthlyPlaybackSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: MonthlyPlaybackViewModel(clips: session.clips))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.clips.isEmpty {
                Text("저장된 영상이 없습니다.")
                    .foregroundStyle(.white)
            } else {
                AspectFillVideoPlayer(player: viewModel.player)
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomSection
            }
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .overlay(alignment: .center) {
            if isExportingShare {
                ProgressView("영상 준비 중...")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 8)
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            if let url = shareURL {
                try? FileManager.default.removeItem(at: url)
            }
            shareURL = nil
        }) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            } else {
                Text("공유할 영상이 없습니다.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .alert("공유할 수 없습니다.", isPresented: Binding(get: {
            shareError != nil
        }, set: { newValue in
            if !newValue { shareError = nil }
        }), actions: {
            Button("확인", role: .cancel) {
                shareError = nil
            }
        }, message: {
            Text(shareError ?? "")
        })
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    viewModel.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }

                Spacer()

                VStack(alignment: .center, spacing: 4) {
                    Text(session.monthTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(viewModel.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                Button {
                    shareMonthlyCompilation()
                } label: {
                    if isExportingShare {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 28, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.trailing, 4)
                .disabled(isExportingShare || session.clips.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomSection: some View {
        VStack(spacing: 18) {
            if viewModel.didFinish {
                Text("모든 영상을 재생했어요")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    Button {
                        viewModel.restart()
                    } label: {
                        Label("다시 재생", systemImage: "gobackward")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PlayerActionButtonStyle())

                    Button {
                        viewModel.stop()
                        onClose()
                    } label: {
                        Label("닫기", systemImage: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.12)))
                }
            } else {
                Text(viewModel.currentClipLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        viewModel.skipForward()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 36, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.hasNext ? .white : .white.opacity(0.35))
                    .disabled(!viewModel.hasNext)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func shareMonthlyCompilation() {
        guard !isExportingShare, !session.clips.isEmpty else { return }
        isExportingShare = true
        shareError = nil

        Task {
            do {
                let url = try await VideoStorageManager.shared.exportMonthlyCompilation(for: session.clips, monthDate: session.monthDate)
                await MainActor.run {
                    shareURL = url
                    isExportingShare = false
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    shareError = error.localizedDescription
                    isExportingShare = false
                }
            }
        }
    }
}

// MARK: - Audio Session Activation Helper
fileprivate func activatePlaybackAudioSession() {
    Task {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            #if DEBUG
            print("Audio session error: \(error)")
            #endif
        }
    }
}

// MARK: - Share Sheet Wrapper
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
