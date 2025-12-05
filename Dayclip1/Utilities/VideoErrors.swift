//
//  VideoErrors.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation

// MARK: - Video Storage Errors

enum VideoStorageError: LocalizedError {
    case assetUnavailable
    case thumbnailCreationFailed
    case imageConversionFailed
    case imageLoadFailed

    var errorDescription: String? {
        switch self {
        case .assetUnavailable:
            return "Unable to load the selected video."
        case .thumbnailCreationFailed:
            return "Unable to create video thumbnail."
        case .imageConversionFailed:
            return "An error occurred while converting image to video."
        case .imageLoadFailed:
            return "Unable to load the selected image."
        }
    }
}

// MARK: - Video Processing Errors

enum VideoProcessingError: LocalizedError {
    case missingDay
    case noSelectedSegments
    case unableToCreateTrack
    case exportFailed
    case backgroundTrackMissing
    case backgroundTrackLoadFailed

    var errorDescription: String? {
        switch self {
        case .missingDay:
            return "Unable to verify date information for saving the edit."
        case .noSelectedSegments:
            return "No video segments selected."
        case .unableToCreateTrack:
            return "Unable to create track for video composition."
        case .exportFailed:
            return "An error occurred while exporting the edited video."
        case .backgroundTrackMissing:
            return "Unable to find the selected background music file."
        case .backgroundTrackLoadFailed:
            return "A problem occurred while loading background music."
        }
    }
}

