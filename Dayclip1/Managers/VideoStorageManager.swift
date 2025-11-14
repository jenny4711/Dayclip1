//
//  VideoStorageManager.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import AVFoundation
import SwiftUI
import PhotosUI
import UIKit

// MARK: - Export Session Wrapper

struct ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
}

// MARK: - Video Storage Manager

final class VideoStorageManager {
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
            try data.write(to: thumbnailURL, options: Data.WritingOptions.atomic)
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
            try? data.write(to: metaURL, options: Data.WritingOptions.atomic)
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

    func makeMonthlyComposition(for clips: [DayClip]) async throws -> (composition: AVMutableComposition, placements: [ClipPlacement], renderSize: CGSize, clipTimeRanges: [CMTimeRange]) {
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
        var clipTimeRanges: [CMTimeRange] = []
        let renderSize = CGSize(width: 1080, height: 1920)

        for clip in clips.sorted(by: { $0.date < $1.date }) {
            let asset = AVAsset(url: clip.videoURL)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else { continue }
            let duration = try await asset.load(.duration)
            let baseTransform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let renderRect = CGRect(origin: .zero, size: naturalSize).applying(baseTransform)
            let trackSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
            
            // Calculate scale to fit renderSize while maintaining aspect ratio
            // trackSize is already in the coordinate system after baseTransform
            let scaleX = renderSize.width / trackSize.width
            let scaleY = renderSize.height / trackSize.height
            let scale = max(scaleX, scaleY) // Use max to fill the entire frame
            
            // Calculate translation to center the video
            let scaledWidth = trackSize.width * scale
            let scaledHeight = trackSize.height * scale
            let translateX = (renderSize.width - scaledWidth) / 2
            let translateY = (renderSize.height - scaledHeight) / 2
            
            // Apply transforms: baseTransform first (rotation/orientation), then scale, then translate
            // This ensures proper handling of rotated videos
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let translateTransform = CGAffineTransform(translationX: translateX, y: translateY)
            let scaleAndTranslate = scaleTransform.concatenating(translateTransform)
            
            // baseTransform handles rotation/orientation, apply it first
            let finalTransform = baseTransform.concatenating(scaleAndTranslate)

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
                if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                    try audioTrack.insertTimeRange(timeRange, of: sourceAudio, at: cursor)
                }
                let outputRange = CMTimeRange(start: cursor, duration: duration)
                placements.append(ClipPlacement(timeRange: outputRange, transform: finalTransform))
                clipTimeRanges.append(outputRange)
                cursor = CMTimeAdd(cursor, duration)
            } catch {
                continue
            }
        }

        guard cursor.seconds > 0, !placements.isEmpty else {
            throw VideoProcessingError.exportFailed
        }
        
        return (mixComposition, placements, renderSize, clipTimeRanges)
    }

    func exportMonthlyCompilation(for clips: [DayClip], monthDate: Date) async throws -> URL {
        let (mixComposition, placements, renderSize, _) = try await makeMonthlyComposition(for: clips)

        let normalizedMonth = calendar.startOfMonth(for: monthDate) ?? monthDate
        let fileName = "Monthly-\(folderFormatter.string(from: normalizedMonth))-share.mp4"
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetHighestQuality) else {
            throw VideoProcessingError.exportFailed
        }

        let sessionBox = ExportSessionBox(session: exportSession)
        sessionBox.session.outputURL = outputURL
        sessionBox.session.outputFileType = .mp4
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
            try data.write(to: thumbnailURL, options: Data.WritingOptions.atomic)
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

