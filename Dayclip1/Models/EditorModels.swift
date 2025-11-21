//
//  EditorModels.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - Editor Clip Sources

enum EditorClipSource {
    case picker(PhotosPickerItem)
    case file(URL)
}

// MARK: - Editor Draft Model

struct EditorDraft: Identifiable {
    let id = UUID()
    let date: Date
    let sources: [EditorClipSource]
}

// MARK: - Editor Clip Selection Model

struct EditorClipSelection: Identifiable {
    let id = UUID()
    let url: URL
    let order: Int
    let timeRange: CMTimeRange
    let rotationQuarterTurns: Int
}

// MARK: - Composition Draft Model

struct EditorCompositionDraft: Identifiable {
    let id = UUID()
    let date: Date
    let clipSelections: [EditorClipSelection]
    let muteOriginalAudio: Bool
    let backgroundTrack: BackgroundTrackSelection?
    let renderSize: CGSize
}

// MARK: - Persistable Editing Composition (for saving/loading)

struct PersistableEditingComposition: Codable {
    struct PersistableClipSelection: Codable {
        let filename: String
        let order: Int
        let trimStart: Double
        let trimDuration: Double
        let rotationQuarterTurns: Int
    }
    
    let clipSelections: [PersistableClipSelection]
    let muteOriginalAudio: Bool
    let renderSizeWidth: Double
    let renderSizeHeight: Double
    
    init(from draft: EditorCompositionDraft, sourceURLs: [URL]) {
        // URL을 filename으로 매핑
        let urlToFilename: [URL: String] = Dictionary(uniqueKeysWithValues: sourceURLs.map { ($0, $0.lastPathComponent) })
        
        self.clipSelections = draft.clipSelections
            .sorted(by: { $0.order < $1.order })
            .compactMap { selection in
                guard let filename = urlToFilename[selection.url] else { return nil }
                return PersistableClipSelection(
                    filename: filename,
                    order: selection.order,
                    trimStart: selection.timeRange.start.seconds,
                    trimDuration: selection.timeRange.duration.seconds,
                    rotationQuarterTurns: selection.rotationQuarterTurns
                )
            }
        self.muteOriginalAudio = draft.muteOriginalAudio
        self.renderSizeWidth = Double(draft.renderSize.width)
        self.renderSizeHeight = Double(draft.renderSize.height)
    }
}

