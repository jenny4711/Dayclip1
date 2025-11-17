//
//  CalendarModels.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Weekday Enum

enum Weekday: CaseIterable {
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

// MARK: - Calendar Month Model

struct CalendarMonth: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let days: [CalendarDay]

    init(id: UUID = UUID(), date: Date, days: [CalendarDay]) {
        self.id = id
        self.date = date
        self.days = days
    }
    
    static func == (lhs: CalendarMonth, rhs: CalendarMonth) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date
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

// MARK: - Calendar Day Model

struct CalendarDay: Identifiable, Equatable {
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
    
    static func == (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date && lhs.kind == rhs.kind && 
        lhs.isToday == rhs.isToday && lhs.isFuture == rhs.isFuture && lhs.hasClip == rhs.hasClip
        // thumbnail은 UIImage?이므로 Equatable이 아니므로 비교하지 않음
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

    enum DayKind: Equatable {
        case previous
        case current
        case next
    }
}

