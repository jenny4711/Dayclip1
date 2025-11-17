//
//  CalendarViewModel.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import SwiftUI
import Combine

// MARK: - CalendarViewModel

@MainActor
final class CalendarViewModel: ObservableObject {
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

        months = generatedMonths  // 오래된 월이 위에, 최근 월이 아래에
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
    
    func allClips() -> [DayClip] {
        return clips
            .sorted { $0.key < $1.key }
            .map { $0.value }
    }
}

