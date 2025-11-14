//
//  CalendarHelpers.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation

// MARK: - Calendar Date Helpers

extension Calendar {
    func startOfMonth(for date: Date) -> Date? {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components)
    }

    func startOfNextMonth(for date: Date) -> Date? {
        guard let month = self.date(byAdding: .month, value: 1, to: date) else { return nil }
        return startOfMonth(for: month)
    }
}

