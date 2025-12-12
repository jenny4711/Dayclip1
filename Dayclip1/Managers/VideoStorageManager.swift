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
    
    // MARK: - Image Storage
    
    /// 이미지를 즉시 저장하고 썸네일을 생성합니다. 비디오 변환은 백그라운드에서 진행됩니다.
    func storeImage(from item: PhotosPickerItem, for date: Date) async throws -> DayClip {
        guard let picked = try await item.loadTransferable(type: PickedImage.self) else {
            throw VideoStorageError.imageLoadFailed
        }
        
        let normalizedDate = calendar.startOfDay(for: date)
        let folderName = folderFormatter.string(from: normalizedDate)
        let targetDirectory = clipsDirectory.appendingPathComponent(folderName, isDirectory: true)
        
        if fileManager.fileExists(atPath: targetDirectory.path) {
            try fileManager.removeItem(at: targetDirectory)
        }
        
        try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        
        // 이미지 파일을 임시로 저장 (나중에 비디오로 교체됨)
        let imageExtension = picked.url.pathExtension.isEmpty ? "jpg" : picked.url.pathExtension
        let tempImageURL = targetDirectory.appendingPathComponent("temp_image").appendingPathExtension(imageExtension)
        
        try fileManager.copyItem(at: picked.url, to: tempImageURL)
        
        defer {
            try? fileManager.removeItem(at: picked.url)
        }
        
        // 즉시 썸네일 생성 (로딩 없음)
        guard let image = UIImage(contentsOfFile: tempImageURL.path) else {
            throw VideoStorageError.imageLoadFailed
        }
        
        let thumbnailImage = resizeImageForThumbnail(image)
        let thumbnailURL = targetDirectory.appendingPathComponent("thumbnail.jpg")
        
        if let data = thumbnailImage.jpegData(compressionQuality: 0.85) {
            try data.write(to: thumbnailURL, options: Data.WritingOptions.atomic)
        } else {
            throw VideoStorageError.thumbnailCreationFailed
        }
        
        // 편집 세션 소스로 원본 이미지 저장 (편집 페이지에서 사용하기 위해)
        let editingDirectory = editingDirectory(for: normalizedDate)
        if !fileManager.fileExists(atPath: editingDirectory.path) {
            try fileManager.createDirectory(at: editingDirectory, withIntermediateDirectories: true)
        }
        
        // 편집 디렉토리에 원본 이미지 복사
        let editingImageURL = editingDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(imageExtension)
        
        try fileManager.copyItem(at: tempImageURL, to: editingImageURL)
        
        // 편집 세션 소스 저장
        saveEditingSources([editingImageURL], for: normalizedDate)
        
        // 비디오 URL 생성
        let videoURL = targetDirectory.appendingPathComponent("clip").appendingPathExtension("mp4")
        
        // 이미지를 비디오로 변환 (1초) - 변환이 완료될 때까지 기다림
        // 이렇게 해야 makeMonthlyComposition에서 파일이 존재하고 duration이 올바르게 로드됨
        let convertedVideoURL = try await convertImageToVideo(imageURL: tempImageURL, outputURL: videoURL, duration: 1.0)
        
        // 변환 완료 후 임시 이미지 파일 삭제 (편집 디렉토리의 이미지는 유지)
        try? fileManager.removeItem(at: tempImageURL)
        
        // 비디오 변환이 완료된 후 DayClip 반환
        return DayClip(date: normalizedDate, videoURL: convertedVideoURL, thumbnailURL: thumbnailURL, thumbnail: thumbnailImage, createdAt: Date())
    }
    
    /// 이미지를 정적 비디오로 변환합니다.
    private func convertImageToVideo(imageURL: URL, outputURL: URL, duration: Double) async throws -> URL {
        guard let image = UIImage(contentsOfFile: imageURL.path),
              let cgImage = image.cgImage else {
            throw VideoStorageError.imageLoadFailed
        }
        
        let renderSize = CGSize(width: 1080, height: 1920) // 세로 비디오 기준
        let fps: Int32 = 30
        let totalFrames = Int(duration * Double(fps))
        
        // 이미지 크기를 renderSize에 맞게 조정 (aspect fill)
        let imageSize = image.size
        let scale = max(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let scaledImage = resizeImage(image, to: scaledSize)
        guard let scaledCGImage = scaledImage.cgImage else {
            throw VideoStorageError.imageConversionFailed
        }
        
        // AVAssetWriter 설정
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderSize.width,
            AVVideoHeightKey: renderSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2000000 // 2Mbps (정적 이미지이므로 낮은 비트레이트)
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: renderSize.width,
            kCVPixelBufferHeightKey as String: renderSize.height
        ]
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        
        guard writer.canAdd(writerInput) else {
            throw VideoStorageError.imageConversionFailed
        }
        writer.add(writerInput)
        
        guard writer.startWriting() else {
            throw VideoStorageError.imageConversionFailed
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // 이미지를 중앙에 배치하기 위한 오프셋 계산
        let offsetX = (renderSize.width - scaledSize.width) / 2
        let offsetY = (renderSize.height - scaledSize.height) / 2
        
        // 각 프레임에 동일한 이미지 추가
        for frameIndex in 0..<totalFrames {
            // 프레임이 준비될 때까지 대기
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 0.01초 대기
            }
            
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(
                kCFAllocatorDefault,
                adaptor.pixelBufferPool!,
                &pixelBuffer
            )
            
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw VideoStorageError.imageConversionFailed
            }
            
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(renderSize.width),
                height: Int(renderSize.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
            
            // 배경을 검은색으로 채우기
            context?.setFillColor(UIColor.black.cgColor)
            context?.fill(CGRect(origin: .zero, size: renderSize))
            
            // 이미지를 중앙에 그리기
            context?.draw(
                scaledCGImage,
                in: CGRect(origin: CGPoint(x: offsetX, y: offsetY), size: scaledSize)
            )
            
            // presentationTime을 정확히 계산: frameIndex / fps
            // 마지막 프레임이 정확히 duration에 도달하도록 함
            let frameTime = Double(frameIndex) / Double(fps)
            let presentationTime = CMTime(seconds: frameTime, preferredTimescale: CMTimeScale(fps))
            
            if !adaptor.append(buffer, withPresentationTime: presentationTime) {
                throw VideoStorageError.imageConversionFailed
            }
        }
        
        writerInput.markAsFinished()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writer.error ?? VideoStorageError.imageConversionFailed)
                }
            }
        }
        
        // 비디오 파일이 완전히 작성되었는지 확인하고 duration 검증
        // 파일 시스템이 완전히 동기화될 때까지 약간의 대기
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1초 대기
        
        // 생성된 비디오의 실제 duration 확인
        let createdAsset = AVAsset(url: outputURL)
        let actualDuration = try await createdAsset.load(.duration)
        
        #if DEBUG
        print("🎬 Created video duration: \(actualDuration.seconds) seconds (expected: \(duration))")
        #endif
        
        // Duration이 예상과 크게 다르면 경고 (비디오는 생성되었으므로 계속 진행)
        let durationDiff = abs(actualDuration.seconds - duration)
        if durationDiff >= 0.1 {
            #if DEBUG
            print("⚠️ Duration mismatch: expected \(duration), got \(actualDuration.seconds)")
            #endif
            // 작은 차이는 허용하지만, 0.5초 차이는 문제
            // 하지만 비디오는 생성되었으므로 계속 진행
        }
        
        return outputURL
    }
    
    /// 썸네일 생성을 위해 이미지 리사이즈
    private func resizeImageForThumbnail(_ image: UIImage) -> UIImage {
        let maxSize: CGFloat = 400
        let size = image.size
        
        if size.width <= maxSize && size.height <= maxSize {
            return image
        }
        
        let scale = min(maxSize / size.width, maxSize / size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return resizeImage(image, to: newSize)
    }
    
    /// 이미지 리사이즈 헬퍼
    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
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

    func prepareEditingAsset(for date: Date, sourceURL: URL) async throws -> URL {
        let directory = editingDirectory(for: date)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // 이미지 파일인지 확인
        let isImageFile = ["jpg", "jpeg", "png", "heic", "heif"].contains(sourceURL.pathExtension.lowercased())
        
        if isImageFile {
            // 이미지는 항상 비디오로 변환 (편집 디렉토리에 있더라도)
            // 이미 변환된 비디오가 있는지 확인 (같은 이름의 .mp4 파일)
            let videoFilename = sourceURL.deletingPathExtension().lastPathComponent + ".mp4"
            let existingVideoURL = directory.appendingPathComponent(videoFilename)
            
            if fileManager.fileExists(atPath: existingVideoURL.path) {
                // 이미 변환된 비디오가 있으면 재사용
                return existingVideoURL
            }
            
            // 비디오로 변환
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            
            // 이미지를 비디오로 변환 (1초)
            let videoURL = try await convertImageToVideo(imageURL: sourceURL, outputURL: destination, duration: 1.0)
            
            if sourceURL.path.hasPrefix(NSTemporaryDirectory()) {
                try? fileManager.removeItem(at: sourceURL)
            }
            return videoURL
        } else {
            // 비디오 파일인 경우
            // 이미 같은 디렉토리에 있으면 복사 불필요
            if sourceURL.deletingLastPathComponent() == directory {
                return sourceURL
            }
            // 비디오 파일은 그대로 복사
            let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            let destination = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }

            // 파일 복사를 백그라운드 스레드에서 실행
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: sourceURL, to: destination)
            }.value
            
            if sourceURL.path.hasPrefix(NSTemporaryDirectory()) {
                try? fileManager.removeItem(at: sourceURL)
            }
            return destination
        }
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
    
    // MARK: - Editing Composition Persistence
    
    func saveEditingComposition(_ draft: EditorCompositionDraft, sourceURLs: [URL], for date: Date) {
        let directory = editingDirectory(for: date)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        
        let persistable = PersistableEditingComposition(from: draft, sourceURLs: sourceURLs)
        let metaURL = directory.appendingPathComponent("composition.json")
        if let data = try? JSONEncoder().encode(persistable) {
            try? data.write(to: metaURL, options: Data.WritingOptions.atomic)
        }
    }
    
    func loadEditingComposition(for date: Date) -> PersistableEditingComposition? {
        let directory = editingDirectory(for: date)
        let metaURL = directory.appendingPathComponent("composition.json")
        guard let data = try? Data(contentsOf: metaURL),
              let composition = try? JSONDecoder().decode(PersistableEditingComposition.self, from: data) else {
            return nil
        }
        return composition
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
            // 파일 존재 여부 확인
            guard fileManager.fileExists(atPath: clip.videoURL.path) else {
                #if DEBUG
                print("⚠️ Video file does not exist: \(clip.videoURL.path)")
                #endif
                continue
            }
            
            let asset = AVAsset(url: clip.videoURL)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
                #if DEBUG
                print("⚠️ Failed to load video track: \(clip.videoURL.path)")
                #endif
                continue
            }
            
            let duration = try await asset.load(.duration)
            
            // Duration이 유효한지 확인 (0보다 크고 유한한 값이어야 함)
            guard duration.isValid && duration.isNumeric && duration.seconds > 0 && duration.seconds.isFinite else {
                #if DEBUG
                print("⚠️ Invalid duration for clip: \(clip.videoURL.path), duration: \(duration.seconds)")
                #endif
                continue
            }
            let baseTransform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity
            let naturalSize = try await sourceVideo.load(.naturalSize)
            let renderRect = CGRect(origin: .zero, size: naturalSize).applying(baseTransform)
            let trackSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
            
            // Calculate scale to fit renderSize while maintaining aspect ratio
            // trackSize is already in the coordinate system after baseTransform
            let scaleX = renderSize.width / trackSize.width
            let scaleY = renderSize.height / trackSize.height
            let scale = min(scaleX, scaleY) // Use min to fit entire video without cropping (aspect fit)
            
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
                placements.append(ClipPlacement(timeRange: outputRange, transform: finalTransform, date: clip.date))
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

        guard let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetMediumQuality) else {
            throw VideoProcessingError.exportFailed
        }

        let sessionBox = ExportSessionBox(session: exportSession)
        sessionBox.session.outputURL = outputURL
        sessionBox.session.outputFileType = .mp4
        sessionBox.session.shouldOptimizeForNetworkUse = true

        if let videoComposition = makeVideoComposition(for: mixComposition, placements: placements, renderSize: renderSize, includeDateOverlay: true) {
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
                placements.append(ClipPlacement(timeRange: outputRange, transform: combinedTransform, date: nil))
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

        guard let exportSession = AVAssetExportSession(asset: mixComposition, presetName: AVAssetExportPresetMediumQuality) else {
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
                                                       renderSize: draft.renderSize,
                                                       includeDateOverlay: false) {
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

        // Export 완료 후 파일이 완전히 쓰여질 때까지 짧은 지연
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1초
        
        // 파일이 존재하고 접근 가능한지 확인
        guard fileManager.fileExists(atPath: storedVideoURL.path) else {
            throw VideoProcessingError.exportFailed
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
                              renderSize: CGSize,
                              includeDateOverlay: Bool = false) -> AVMutableVideoComposition? {
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
        
        // 날짜 텍스트 레이어 추가 (export 시에만)
        if includeDateOverlay {
            let datePlacements = placements.filter { $0.date != nil }
            if !datePlacements.isEmpty {
                let parentLayer = CALayer()
                parentLayer.frame = CGRect(origin: .zero, size: renderSize)
                // UIKit 좌표계 사용 (0,0이 왼쪽 상단)
                parentLayer.isGeometryFlipped = true
                // 비디오는 1:1 scale로 렌더링되므로 contentsScale을 1.0으로 설정
                parentLayer.contentsScale = 1.0
                
                let videoLayer = CALayer()
                videoLayer.frame = CGRect(origin: .zero, size: renderSize)
                videoLayer.contentsScale = 1.0
                parentLayer.addSublayer(videoLayer)
                
                // 각 클립의 날짜 텍스트 레이어 추가
                // 단일 컨테이너 레이어로 관리하여 겹침 방지
                let dateContainerLayer = CALayer()
                dateContainerLayer.frame = CGRect(origin: .zero, size: renderSize)
                dateContainerLayer.contentsScale = 1.0
                
                for placement in datePlacements.sorted(by: { $0.timeRange.start < $1.timeRange.start }) {
                    guard let date = placement.date else { continue }
                    let dateLayer = createDateTextLayer(for: date, renderSize: renderSize)
                    // 정확한 시간 범위에만 표시되도록 설정
                    // beginTime은 부모 레이어 기준 상대 시간 (초 단위)
                    dateLayer.beginTime = placement.timeRange.start.seconds
                    dateLayer.duration = placement.timeRange.duration.seconds
                    // 레이어가 겹치지 않도록 명시적으로 설정
                    dateLayer.isHidden = false
                    dateLayer.opacity = 1.0
                    // 시간 범위 밖에서는 숨김 처리
                    dateLayer.fillMode = .removed
                    dateContainerLayer.addSublayer(dateLayer)
                }
                
                parentLayer.addSublayer(dateContainerLayer)
                
                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                    postProcessingAsVideoLayer: videoLayer,
                    in: parentLayer
                )
            }
        }

        return videoComposition
    }
    
    /// 날짜 텍스트 레이어 생성
    private func createDateTextLayer(for date: Date, renderSize: CGSize) -> CALayer {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMMM d, yyyy"
        let dateString = dateFormatter.string(from: date)
        
        // 텍스트 크기 계산 (더 큰 사이즈: 56pt)
        let font = UIFont.systemFont(ofSize: 56, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let attributedString = NSAttributedString(string: dateString, attributes: attributes)
        let textSize = attributedString.boundingRect(
            with: CGSize(width: renderSize.width - 40, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).size
        
        // 하단 중앙 배치
        // AVVideoCompositionCoreAnimationTool은 UIKit 좌표계 사용 (0,0)은 왼쪽 상단
        let textWidth = textSize.width
        let textHeight = textSize.height
        let textX = (renderSize.width - textWidth) / 2
        // 하단에서 40pt 위 (UIKit 좌표계: Y는 위에서 아래로)
        let textY: CGFloat = renderSize.height - 40 - textHeight
        
        // 텍스트 레이어 생성 (앱과 동일하게 배경/그림자 없음)
        let textLayer = CATextLayer()
        textLayer.frame = CGRect(x: textX, y: textY, width: textWidth, height: textHeight)
        textLayer.string = attributedString
        textLayer.alignmentMode = .center
        textLayer.isWrapped = false
        // 비디오는 1:1 scale로 렌더링되므로 contentsScale을 1.0으로 설정 (선명도 향상)
        textLayer.contentsScale = 1.0
        
        // 그림자 효과 제거 (앱과 동일하게)
        
        return textLayer
    }
}

