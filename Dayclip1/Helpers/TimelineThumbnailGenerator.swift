//
//  TimelineThumbnailGenerator.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import AVFoundation
import CoreGraphics

// MARK: - Timeline Thumbnail Types

struct TimelineThumbnailRequest: Sendable {
    let clipIndex: Int
    let assetURL: URL
    let renderSize: CGSize
    let rotationQuarterTurns: Int
    let times: [CMTime]
}

struct TimelineThumbnailResult: @unchecked Sendable {
    let frameIndex: Int
    let image: CGImage
}

struct ClipPlacement {
    let timeRange: CMTimeRange
    let transform: CGAffineTransform
}

// MARK: - Timeline Thumbnail Generator

enum TimelineThumbnailGenerator {
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

// MARK: - Constants

let defaultTrimDuration: Double = 2.0

