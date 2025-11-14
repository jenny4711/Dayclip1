//
//  DayClip.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import UIKit

// MARK: - Day Clip Model

struct DayClip: Identifiable {
    let id = UUID()
    let date: Date
    let videoURL: URL
    let thumbnailURL: URL
    let thumbnail: UIImage
    let createdAt: Date
}

// MARK: - Day Clip Metadata Bridge

extension DayClip {
    var metadata: ClipMetadata {
        ClipMetadata(date: date, videoURL: videoURL, thumbnailURL: thumbnailURL, createdAt: createdAt)
    }
}

// MARK: - Monthly Playback Session Model

struct MonthlyPlaybackSession: Identifiable {
    let id = UUID()
    let monthDate: Date
    let clips: [DayClip]

    var monthTitle: String {
        guard !clips.isEmpty else {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy년 M월"
            return formatter.string(from: monthDate)
        }
        
        let sortedClips = clips.sorted { $0.date < $1.date }
        guard let firstDate = sortedClips.first?.date,
              let lastDate = sortedClips.last?.date else {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy년 M월"
            return formatter.string(from: monthDate)
        }
        
        let calendar = Calendar.current
        let firstYear = calendar.component(.year, from: firstDate)
        let firstMonth = calendar.component(.month, from: firstDate)
        let lastYear = calendar.component(.year, from: lastDate)
        let lastMonth = calendar.component(.month, from: lastDate)
        
        if firstYear == lastYear && firstMonth == lastMonth {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy년 M월"
            return formatter.string(from: firstDate)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy년 M월"
            let firstTitle = formatter.string(from: firstDate)
            let lastTitle = formatter.string(from: lastDate)
            return "\(firstTitle) ~ \(lastTitle)"
        }
    }

    var clipCount: Int {
        clips.count
    }
}

