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
            return "선택한 영상을 불러올 수 없습니다."
        case .thumbnailCreationFailed:
            return "영상 썸네일을 생성할 수 없습니다."
        case .imageConversionFailed:
            return "이미지를 비디오로 변환하는 중 오류가 발생했습니다."
        case .imageLoadFailed:
            return "선택한 이미지를 불러올 수 없습니다."
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

