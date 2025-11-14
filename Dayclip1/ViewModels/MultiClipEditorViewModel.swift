//
//  MultiClipEditorViewModel.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import AVFoundation
import SwiftUI
import Combine
import PhotosUI

// MARK: - Multi Clip Editor ViewModel

@MainActor
final class MultiClipEditorViewModel: ObservableObject {
    struct EditorClip: Identifiable {
        let id = UUID()
        let order: Int
        let url: URL
        let asset: AVAsset
        let duration: Double
        let renderSize: CGSize
        var rotationQuarterTurns: Int
        var trimDuration: Double
        var trimStart: Double
        var timelineFrames: [TimelineFrame]
    }

    struct TimelineFrame: Identifiable {
        let id = UUID()
        let index: Int
        let time: Double
        let length: Double
        var thumbnail: UIImage?
    }

    @Published var clips: [EditorClip] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = false
        return player
    }()
    @Published var isPlaying = false
    @Published var isBuildingPreview = false

    private let draft: EditorDraft
    private var currentMuteOriginal = false
    private var currentBackgroundTrack: BackgroundTrackSelection?
    private var rebuildTask: Task<AVPlayerItem?, Never>?
    private var thumbnailTasks: [Task<Void, Never>] = []
    private let maxTimelineFrames = 80

    init(draft: EditorDraft) {
        self.draft = draft
        Task {
            await loadClips()
        }
    }

    var hasSelection: Bool {
        clips.contains { effectiveTrimRange(for: $0) != nil }
    }

    func rebuildPreviewPlayer(muteOriginal: Bool? = nil, backgroundTrack: BackgroundTrackSelection?? = nil) async {
        if let muteOriginal {
            currentMuteOriginal = muteOriginal
        }
        if let backgroundTrack {
            switch backgroundTrack {
            case .some(let selection):
                currentBackgroundTrack = selection
            case .none:
                currentBackgroundTrack = nil
            }
        }

        guard !clips.isEmpty else {
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            isBuildingPreview = false
            return
        }

        let mute = currentMuteOriginal
        let backgroundSelection = currentBackgroundTrack
        let clipsSnapshot = clips
        let renderSize = currentRenderSize

        rebuildTask?.cancel()
        isBuildingPreview = true

        rebuildTask = Task(priority: .userInitiated) {
            await MultiClipEditorViewModel.buildPreviewItem(
                clips: clipsSnapshot,
                muteOriginal: mute,
                backgroundSelection: backgroundSelection,
                renderSize: renderSize
            )
        }

        let item = await rebuildTask?.value
        guard !Task.isCancelled else { return }

        await MainActor.run {
            player.replaceCurrentItem(with: item)
            player.isMuted = false
            activatePlaybackAudioSession()
            if let item, isPlaying {
                item.seek(to: .zero, completionHandler: { [weak self] _ in
                    self?.player.play()
                })
            } else if isPlaying {
                player.play()
            }
            isBuildingPreview = false
        }
    }

    func togglePlayback() {
        if player.currentItem == nil {
            // 미리보기가 없으면 먼저 생성
            Task {
                await rebuildPreviewPlayer()
                if player.currentItem != nil {
                    await player.seek(to: .zero)
                    player.play()
                    isPlaying = true
                }
            }
            return
        }
        
        if isPlaying {
            player.pause()
        } else {
            Task {
                await player.seek(to: .zero)
                player.play()
            }
        }
        isPlaying.toggle()
    }

    func stopPlayback() {
        player.pause()
        isPlaying = false
    }

    func makeCompositionDraft(muteOriginalAudio: Bool, backgroundTrack: BackgroundTrackSelection?) -> EditorCompositionDraft? {
        let selections: [EditorClipSelection] = clips
            .sorted(by: { $0.order < $1.order })
            .compactMap { clip in
                guard let range = effectiveTrimRange(for: clip) else { return nil }
                return EditorClipSelection(url: clip.url,
                                           order: clip.order,
                                           timeRange: range,
                                           rotationQuarterTurns: clip.rotationQuarterTurns)
            }

        guard !selections.isEmpty else { return nil }
        return EditorCompositionDraft(
            date: draft.date,
            clipSelections: selections,
            muteOriginalAudio: muteOriginalAudio,
            backgroundTrack: backgroundTrack,
            renderSize: currentRenderSize
        )
    }

    func formatDuration(_ duration: Double) -> String {
        formatDuration(seconds: duration)
    }

    private func loadClips() async {
        thumbnailTasks.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        isLoading = true

        let results: [(index: Int, url: URL, asset: AVAsset, duration: Double, renderSize: CGSize)] = await withTaskGroup(of: (Int, URL, AVAsset, Double, CGSize)?.self) { group in
            for (index, source) in draft.sources.enumerated() {
                group.addTask {
                    do {
                        let storedURL: URL
                        switch source {
                        case .picker(let pickerItem):
                            guard let movie = try await pickerItem.loadTransferable(type: PickedMovie.self) else { return nil }
                            storedURL = try VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: movie.url)
                        case .file(let url):
                            storedURL = try VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: url)
                        }

                        let asset = AVAsset(url: storedURL)
                        // 병렬로 메타데이터 로드
                        async let durationTime = asset.load(.duration)
                        async let videoTracks = asset.loadTracks(withMediaType: .video)
                        
                        let duration = try await durationTime
                        let durationSeconds = duration.seconds
                        let tracks = try await videoTracks
                        guard let primaryTrack = tracks.first else { return nil }
                        
                        // 트랙 속성도 병렬로 로드
                        async let naturalSize = primaryTrack.load(.naturalSize)
                        async let transform = primaryTrack.load(.preferredTransform)
                        
                        let size = try await naturalSize
                        let trackTransform = (try? await transform) ?? .identity
                        let renderRect = CGRect(origin: .zero, size: size).applying(trackTransform)
                        let renderSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
                        return (index, storedURL, asset, durationSeconds, renderSize == .zero ? size : renderSize)
                    } catch {
                        await MainActor.run {
                            self.errorMessage = error.localizedDescription
                        }
                        return nil
                    }
                }
            }

            var collected: [(Int, URL, AVAsset, Double, CGSize)] = []
            for await result in group {
                if let value = result {
                    collected.append(value)
                }
            }
            return collected
        }

        var storedURLs: [URL] = []
        var built: [EditorClip] = []
        for result in results.sorted(by: { $0.index < $1.index }) {
            let initialDuration = min(defaultTrimDuration, max(result.duration, 0.1))
            let frames = makeTimelineFrames(duration: result.duration)
            built.append(EditorClip(order: result.index,
                                    url: result.url,
                                    asset: result.asset,
                                    duration: result.duration,
                                    renderSize: result.renderSize,
                                    rotationQuarterTurns: 0,
                                    trimDuration: initialDuration,
                                    trimStart: 0,
                                    timelineFrames: frames))
            storedURLs.append(result.url)
        }

        clips = built
        isLoading = false

        // 비동기 작업들을 백그라운드에서 처리
        let draftDate = draft.date
        Task.detached(priority: .utility) { [storedURLs, draftDate] in
            if !storedURLs.isEmpty {
                VideoStorageManager.shared.saveEditingSources(storedURLs, for: draftDate)
            }
        }

        scheduleThumbnailGeneration()

        // 미리보기는 즉시 생성 (사용자가 바로 재생할 수 있도록)
        await rebuildPreviewPlayer()
    }

    private func makeTimelineFrames(duration: Double) -> [TimelineFrame] {
        let totalSeconds = max(duration, 0.1)
        let interval = max(defaultTrimDuration / 2, 0.5)
        let estimatedCount = Int(ceil(totalSeconds / interval))
        let frameCount = min(max(estimatedCount, 1), maxTimelineFrames)
        let actualInterval = totalSeconds / Double(frameCount)

        return (0..<frameCount).map { index in
            let start = Double(index) * actualInterval
            let length = index == frameCount - 1 ? (totalSeconds - start) : actualInterval
            return TimelineFrame(index: index, time: start, length: max(length, 0.1), thumbnail: nil)
        }
    }

    private func scheduleThumbnailGeneration(for targetIndexes: [Int]? = nil) {
        let indexes = targetIndexes ?? Array(clips.indices)
        guard !indexes.isEmpty else { return }

        let requests: [TimelineThumbnailRequest] = indexes.compactMap { index in
            guard clips.indices.contains(index) else { return nil }
            let clip = clips[index]
            let times = clip.timelineFrames.map { frame in
                CMTime(seconds: min(frame.time + frame.length / 2, clip.duration), preferredTimescale: 600)
            }
            return TimelineThumbnailRequest(
                clipIndex: index,
                assetURL: clip.url,
                renderSize: clip.renderSize,
                rotationQuarterTurns: clip.rotationQuarterTurns,
                times: times
            )
        }

        guard !requests.isEmpty else { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            for request in requests {
                if Task.isCancelled { return }
                let results = TimelineThumbnailGenerator.generate(for: request)
                if results.isEmpty { continue }

                await MainActor.run { [weak self, request, results] in
                    guard let self else { return }
                    guard self.clips.indices.contains(request.clipIndex) else { return }

                    for result in results {
                        guard self.clips[request.clipIndex].timelineFrames.indices.contains(result.frameIndex) else { continue }
                        let baseImage = UIImage(cgImage: result.image)
                        let finalImage = baseImage.rotatedByQuarterTurns(request.rotationQuarterTurns)
                        self.clips[request.clipIndex].timelineFrames[result.frameIndex].thumbnail = finalImage
                    }
                }
            }
        }

        thumbnailTasks.append(task)
    }

    private func formatDuration(seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded(.toNearestOrAwayFromZero))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func buildPreviewItem(clips: [EditorClip],
                                         muteOriginal: Bool,
                                         backgroundSelection: BackgroundTrackSelection?,
                                         renderSize: CGSize) async -> AVPlayerItem? {
        guard !clips.isEmpty else { return nil }

        let mixComposition = AVMutableComposition()
        guard let videoTrack = mixComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        videoTrack.preferredTransform = .identity
        let originalAudioTrack = muteOriginal ? nil : mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var audioInputParameters: [AVMutableAudioMixInputParameters] = []
        if let originalAudioTrack {
            let params = AVMutableAudioMixInputParameters(track: originalAudioTrack)
            params.setVolume(1.0, at: .zero)
            audioInputParameters.append(params)
        }

        var cursor = CMTime.zero
        var placements: [ClipPlacement] = []

        for clip in clips.sorted(by: { $0.order < $1.order }) {
            guard let sourceVideoTrack = try? await clip.asset.loadTracks(withMediaType: .video).first else { continue }
            let baseTransform = (try? await sourceVideoTrack.load(.preferredTransform)) ?? .identity
            let combinedTransform = baseTransform.concatenating(rotationTransform(for: clip.rotationQuarterTurns, size: clip.renderSize))

            let audioTracks = muteOriginal ? nil : (try? await clip.asset.loadTracks(withMediaType: .audio))
            let sourceAudioTrack = audioTracks?.first

            let safeStart = min(max(clip.trimStart, 0), clip.duration)
            let remaining = max(clip.duration - safeStart, 0)
            let trimmedDuration = min(max(clip.trimDuration, 0.1), remaining)
            guard trimmedDuration > 0 else { continue }

            if Task.isCancelled { return nil }
            let range = CMTimeRange(start: CMTime(seconds: safeStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: trimmedDuration, preferredTimescale: 600))

            do {
                try videoTrack.insertTimeRange(range, of: sourceVideoTrack, at: cursor)
                if let originalAudioTrack, let sourceAudioTrack {
                    try originalAudioTrack.insertTimeRange(range, of: sourceAudioTrack, at: cursor)
                }
                let outputRange = CMTimeRange(start: cursor, duration: range.duration)
                placements.append(ClipPlacement(timeRange: outputRange, transform: combinedTransform))
                cursor = CMTimeAdd(cursor, range.duration)
            } catch {
                continue
            }
        }

        guard cursor.seconds > 0, !placements.isEmpty else {
            return nil
        }

        if let backgroundSelection, let bgURL = backgroundSelection.option.resolvedURL() {
            do {
                let bgAsset = AVAsset(url: bgURL)
                let bgTracks = try await bgAsset.loadTracks(withMediaType: .audio)
                if let sourceBG = bgTracks.first,
                   let bgTrack = mixComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {

                    var bgCursor = CMTime.zero
                    let bgDuration = try await bgAsset.load(.duration)

                    while bgCursor < cursor {
                        if Task.isCancelled { return nil }
                        let remaining = CMTimeSubtract(cursor, bgCursor)
                        let segmentDuration = CMTimeCompare(bgDuration, remaining) == 1 ? remaining : bgDuration
                        try bgTrack.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: sourceBG, at: bgCursor)
                        bgCursor = CMTimeAdd(bgCursor, segmentDuration)
                    }

                    let bgParams = AVMutableAudioMixInputParameters(track: bgTrack)
                    bgParams.setVolume(backgroundSelection.volume, at: .zero)
                    audioInputParameters.append(bgParams)
                }
            } catch {
                return nil
            }
        }

        let item = AVPlayerItem(asset: mixComposition)
        if !audioInputParameters.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioInputParameters
            item.audioMix = audioMix
        }

        if let videoComposition = VideoStorageManager.shared.makeVideoComposition(for: mixComposition,
                                                                                  placements: placements,
                                                                                  renderSize: renderSize) {
            item.videoComposition = videoComposition
        }

        return item
    }

    private func rotatedSize(for clip: EditorClip) -> CGSize {
        if clip.rotationQuarterTurns % 2 == 0 {
            return clip.renderSize
        } else {
            return CGSize(width: clip.renderSize.height, height: clip.renderSize.width)
        }
    }

    private var primaryClip: EditorClip? {
        clips.sorted(by: { $0.order < $1.order }).first
    }

    var currentRenderSize: CGSize {
        guard let clip = primaryClip else {
            return CGSize(width: 1080, height: 1920)
        }
        return rotatedSize(for: clip)
    }

    func rotateClip(_ clip: EditorClip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].rotationQuarterTurns = normalizedQuarterTurns(clips[index].rotationQuarterTurns + 1)

        for frameIndex in clips[index].timelineFrames.indices {
            if let thumbnail = clips[index].timelineFrames[frameIndex].thumbnail {
                clips[index].timelineFrames[frameIndex].thumbnail = thumbnail.rotatedByQuarterTurns(1)
            }
        }

        scheduleThumbnailGeneration(for: [index])

        Task { [weak self] in
            await self?.rebuildPreviewPlayer()
        }
    }

    func updateTrimStart(clipID: UUID, start: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[index]
        let targetDuration = min(defaultTrimDuration, clip.duration)
        let maxStart = max(0, clip.duration - targetDuration)
        let clampedStart = min(max(0, start), maxStart)

        let current = clips[index]
        if abs(current.trimStart - clampedStart) < 0.01 && abs(current.trimDuration - targetDuration) < 0.01 {
            return
        }

        clips[index].trimStart = clampedStart
        clips[index].trimDuration = targetDuration

        Task { [weak self] in
            await self?.rebuildPreviewPlayer()
        }
    }

    func effectiveTrimRange(for clip: EditorClip) -> CMTimeRange? {
        let safeStart = min(max(clip.trimStart, 0), clip.duration)
        let remaining = max(clip.duration - safeStart, 0)
        let trimmedDuration = min(max(clip.trimDuration, 0.1), remaining)
        guard trimmedDuration > 0 else { return nil }
        let startTime = CMTime(seconds: safeStart, preferredTimescale: 600)
        let durationTime = CMTime(seconds: trimmedDuration, preferredTimescale: 600)
        return CMTimeRange(start: startTime, duration: durationTime)
    }

    func trimDescription(for clip: EditorClip) -> String {
        guard let range = effectiveTrimRange(for: clip) else { return "0.0s" }
        let start = range.start.seconds
        let end = CMTimeAdd(range.start, range.duration).seconds
        return "\(formatDuration(seconds: start)) - \(formatDuration(seconds: end))"
    }
}

