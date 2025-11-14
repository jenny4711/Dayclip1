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

