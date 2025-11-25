//
//  MultiClipEditorViewModel.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//
//  SCRUBBING IMPLEMENTATION (YouTube-style)
//  ========================================
//  This file implements YouTube-style video scrubbing for the edit screen.
//
//  Key Changes:
//  - Added scrub(to:for:) method: Called during drag, pauses player and seeks to progress position
//  - Added finishScrubbing(at:for:) method: Called on drag end, updates trimStart and rebuilds preview
//  - Progress-based approach: Uses 0.0-1.0 progress instead of raw time values
//  - convertClipTimeToCompositionTime(): Helper to convert clip time to composition time for multi-clip support
//
//  How it works:
//  1. User drags yellow box → View calculates progress (0.0-1.0) from x-position
//  2. View calls scrub(to:progress, for:clipID) → Player pauses and seeks to composition time
//  3. On drag end → View calls finishScrubbing(at:progress, for:clipID) → Updates trimStart and rebuilds preview
//
//  The yellow box drag now feels like YouTube's seek bar: immediate preview updates as you drag.
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

    @Published var clips: [EditorClip] = [] {
        didSet { compositionOffsetsDirty = true }
    }
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = false
        return player
    }()
    @Published var isPlaying = false
    @Published var isBuildingPreview = false
    @Published var isBlockingRebuild = false
    @Published var selectedClipID: UUID? = nil

    private let draft: EditorDraft
    private var currentMuteOriginal = false
    private var currentBackgroundTrack: BackgroundTrackSelection?
    private var rebuildTask: Task<AVPlayerItem?, Never>?
    private var seekTask: Task<Void, Never>?
    private var thumbnailTasks: [Task<Void, Never>] = []
    private let maxTimelineFrames = 80
    private let defaultTrimDuration: Double = 2.0
    private var lastSeekTime: Double?
    private let seekThrottleInterval: TimeInterval = 0.03 // 0.03초마다 seek (매우 빠른 반응)
    private var segmentTimeObserver: Any? // 2초 세그먼트 재생 완료 감지용
    private var segmentEndObserver: NSObjectProtocol? // 재생 완료 알림용
    private var previewRebuildDebounceTask: Task<Void, Never>?
    private var compositionOffsets: [UUID: CMTime] = [:]
    private var compositionOffsetsDirty = true

    init(draft: EditorDraft) {
        self.draft = draft
        Task {
            await loadClips()
        }
    }

    var hasSelection: Bool {
        clips.contains { effectiveTrimRange(for: $0) != nil }
    }

    func selectClip(_ clipID: UUID) {
        guard selectedClipID != clipID,
              let clip = clips.first(where: { $0.id == clipID }) else {
            return
        }
        selectedClipID = clipID

        Task { [weak self] in
            await self?.loadClipForPreview(clip)
        }
    }

    func setMuteOriginal(_ mute: Bool) {
        currentMuteOriginal = mute
        player.isMuted = mute
    }

    private func loadClipForPreview(_ clip: EditorClip) async {
        let item = AVPlayerItem(asset: clip.asset)
        await MainActor.run {
            player.replaceCurrentItem(with: item)
            player.isMuted = currentMuteOriginal
            activatePlaybackAudioSession()
        }
    }

    func rebuildPreviewPlayer(muteOriginal: Bool? = nil,
                              backgroundTrack: BackgroundTrackSelection?? = nil,
                              showBlockingIndicator: Bool = true) async {
        previewRebuildDebounceTask?.cancel()
        previewRebuildDebounceTask = nil
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
            if showBlockingIndicator {
                isBlockingRebuild = false
            }
            return
        }

        let mute = currentMuteOriginal
        let backgroundSelection = currentBackgroundTrack
        let clipsSnapshot = clips
        let renderSize = currentRenderSize

        rebuildTask?.cancel()
        isBuildingPreview = true
        if showBlockingIndicator {
            isBlockingRebuild = true
        }

        rebuildTask = Task(priority: .userInitiated) {
            guard let selectedID = selectedClipID,
                  let selectedClip = clipsSnapshot.first(where: { $0.id == selectedID }) ?? clipsSnapshot.first else {
                return await MultiClipEditorViewModel.buildPreviewItem(
                    clips: clipsSnapshot,
                    muteOriginal: mute,
                    backgroundSelection: backgroundSelection,
                    renderSize: renderSize
                )
            }
            return await MultiClipEditorViewModel.buildPreviewItem(
                clips: [selectedClip],
                muteOriginal: mute,
                backgroundSelection: backgroundSelection,
                renderSize: renderSize
            )
        }

        let item = await rebuildTask?.value
        guard !Task.isCancelled else {
            isBuildingPreview = false
            if showBlockingIndicator {
                isBlockingRebuild = false
            }
            return
        }

        await MainActor.run {
            player.replaceCurrentItem(with: item)
            player.isMuted = false
            activatePlaybackAudioSession()
            
            // rebuildPreviewPlayer 완료 후 현재 선택된 클립의 trimStart 위치로 자동 seek
            if let item, let selectedClipID = selectedClipID,
               let targetTime = compositionOffset(for: selectedClipID) {
                item.seek(
                    to: targetTime,
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600),
                    completionHandler: { [weak self] _ in
                        if let self = self, self.isPlaying {
                            self.player.play()
                        }
                    }
                )
            } else if let item, isPlaying {
                item.seek(to: .zero, completionHandler: { [weak self] _ in
                    self?.player.play()
                })
            } else if isPlaying {
                player.play()
            }
            isBuildingPreview = false
            if showBlockingIndicator {
                isBlockingRebuild = false
            }
        }
    }

    func togglePlayback() {
        guard let selectedClipID = selectedClipID,
              let clip = clips.first(where: { $0.id == selectedClipID }),
              let trimRange = effectiveTrimRange(for: clip) else {
            // 선택된 클립이 없거나 유효한 trim 범위가 없으면 재생 불가
            return
        }
        
        if isPlaying {
            // 재생 중이면 일시정지
            player.pause()
            removeSegmentObservers()
            isPlaying = false
        } else {
            // 재생 중이 아니면 선택된 2초 세그먼트 재생
            if player.currentItem == nil {
                Task {
                    await loadClipForPreview(clip)
                    await playSelectedSegment(clipID: selectedClipID)
                }
            } else {
                Task {
                    await playSelectedSegment(clipID: selectedClipID)
                }
            }
        }
    }
    
    /// 선택된 클립의 2초 세그먼트 재생
    private func playSelectedSegment(clipID: UUID) async {
        guard let clip = clips.first(where: { $0.id == clipID }),
              let trimRange = effectiveTrimRange(for: clip) else {
            return
        }
        
        // 기존 관찰자 제거
        removeSegmentObservers()
        
        let startTime = CMTime(seconds: clip.trimStart, preferredTimescale: 600)
        let endTime = CMTimeAdd(startTime, CMTime(seconds: clip.trimDuration, preferredTimescale: 600))
        
        await player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        // 재생 시작
        player.play()
        isPlaying = true
        
        // 2초 세그먼트 재생 완료를 감지하기 위한 시간 관찰자 설정
        segmentTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] currentTime in
            guard let self = self else { return }
            // 재생 시간이 세그먼트 끝을 넘어가면 일시정지
            if CMTimeCompare(currentTime, endTime) >= 0 {
                self.player.pause()
                self.removeSegmentObservers()
                self.isPlaying = false
            }
        }
        
        // 재생 완료 알림도 처리 (백업)
        if let currentItem = player.currentItem {
            segmentEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.removeSegmentObservers()
                self.isPlaying = false
            }
        }
    }

    func stopPlayback() {
        player.pause()
        isPlaying = false
        seekTask?.cancel()
        seekTask = nil
        removeSegmentObservers()
    }
    
    /// 2초 세그먼트 재생 관련 관찰자 제거
    private func removeSegmentObservers() {
        if let observer = segmentTimeObserver {
            player.removeTimeObserver(observer)
            segmentTimeObserver = nil
        }
        if let observer = segmentEndObserver {
            NotificationCenter.default.removeObserver(observer)
            segmentEndObserver = nil
        }
    }
    
    // MARK: - Scrubbing Methods
    
    /// 드래그 중 미리보기 영상의 재생 위치를 실시간으로 변경 (YouTube 스타일 scrubbing)
    /// - Parameters:
    ///   - progress: 0.0-1.0 범위의 진행률 (타임라인에서의 위치)
    ///   - clipID: 선택된 클립의 ID
    func scrub(to progress: Double, for clipID: UUID?) {
        // 사용자가 새 드래그를 시작하면 대기 중이던 재빌드 작업/디바운스를 모두 취소
        previewRebuildDebounceTask?.cancel()
        previewRebuildDebounceTask = nil

        if isBuildingPreview {
            rebuildTask?.cancel()
            rebuildTask = nil
            isBuildingPreview = false
            isBlockingRebuild = false
        }
        
        // clipID가 없거나 클립을 찾을 수 없으면 종료
        guard let clipID = clipID,
              let clip = clips.first(where: { $0.id == clipID }) else {
            return
        }
        
        // player.currentItem이 없으면 종료 (아직 미리보기가 생성되지 않음)
        guard let currentItem = player.currentItem else {
            return
        }
        
        // 현재 재생 중이면 일시정지
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        
        // throttle: 너무 자주 호출되지 않도록 제한 (약 30ms마다)
        let now = Date().timeIntervalSince1970
        if let lastSeek = lastSeekTime,
           now - lastSeek < seekThrottleInterval {
            return
        }
        lastSeekTime = now
        
        // 이전 seek 작업 취소
        seekTask?.cancel()
        
        // progress를 클램핑 (0.0-1.0)
        let clampedProgress = max(0.0, min(1.0, progress))
        
        // progress를 원본 클립의 시간(초)으로 변환
        let duration = max(clip.duration, 0.1)
        let maxStart = max(duration - clip.trimDuration, 0)
        let startSeconds = clampedProgress * maxStart
        
        // seek 실행 (작은 tolerance로 빠른 반응)
        seekTask = Task { @MainActor [weak self] in
            guard let self = self, !Task.isCancelled else { return }
            
            await currentItem.seek(
                to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            
            if !Task.isCancelled {
                self.seekTask = nil
            }
        }
    }
    
    /// 드래그 종료 시 최종 위치로 seek하고 상태 업데이트
    /// - Parameters:
    ///   - progress: 0.0-1.0 범위의 최종 진행률
    ///   - clipID: 선택된 클립의 ID
    func finishScrubbing(at progress: Double, for clipID: UUID?) {
        guard let clipID = clipID,
              let clip = clips.first(where: { $0.id == clipID }) else {
            return
        }
        
        // progress를 클램핑
        let clampedProgress = max(0.0, min(1.0, progress))
        
        // progress를 원본 클립의 시간(초)으로 변환
        let duration = max(clip.duration, 0.1)
        let maxStart = max(duration - clip.trimDuration, 0)
        let startSeconds = clampedProgress * maxStart
        
        // trimStart 업데이트
        updateTrimStart(clipID: clipID, start: startSeconds, rebuildPreview: false)
        
        if let currentItem = player.currentItem {
            seekTask?.cancel()
            seekTask = Task { @MainActor [weak self] in
                guard let self = self, !Task.isCancelled else { return }
                await currentItem.seek(
                    to: CMTime(seconds: startSeconds, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600)
                )
                if !Task.isCancelled {
                    self.seekTask = nil
                }
            }
        }
    }

    /// 클립의 원본 시간을 composition 내의 시간으로 변환
    /// - Parameters:
    ///   - clipTime: 원본 클립의 시간(초)
    ///   - clipID: 클립의 ID
    /// - Returns: composition 내의 CMTime, 변환 실패 시 nil
    private func convertClipTimeToCompositionTime(clipTime: Double, for clipID: UUID) -> CMTime? {
        guard let clip = clips.first(where: { $0.id == clipID }) else {
            return nil
        }
        guard let baseOffset = compositionOffset(for: clipID) else {
            return nil
        }

        let clampedTime = min(max(clipTime, 0), clip.duration)
        let safeStart = min(max(clip.trimStart, 0), clip.duration)
        let relativeTime = max(0, clampedTime - safeStart)
        return CMTimeAdd(baseOffset, CMTime(seconds: relativeTime, preferredTimescale: 600))
    }

    private func compositionOffset(for clipID: UUID) -> CMTime? {
        ensureCompositionOffsets()
        return compositionOffsets[clipID]
    }

    private func ensureCompositionOffsets() {
        guard compositionOffsetsDirty else { return }
        compositionOffsets.removeAll(keepingCapacity: true)
        var cursor: CMTime = .zero
        for clip in clips.sorted(by: { $0.order < $1.order }) {
            compositionOffsets[clip.id] = cursor
            let safeStart = min(max(clip.trimStart, 0), clip.duration)
            let remaining = max(clip.duration - safeStart, 0)
            let trimmedDuration = min(max(clip.trimDuration, 0.1), remaining)
            cursor = CMTimeAdd(cursor, CMTime(seconds: trimmedDuration, preferredTimescale: 600))
        }
        compositionOffsetsDirty = false
    }
    
    // 드래그 중 미리보기 영상의 재생 위치를 실시간으로 변경 (레거시 - 호환성을 위해 유지)
    func seekPreviewToTime(time: Double, for clipID: UUID) {
        // 재빌드 중이면 취소하고 바로 scrubbing 가능하게
        if isBuildingPreview {
            rebuildTask?.cancel()
            isBuildingPreview = false
            isBlockingRebuild = false
        }
        
        // 현재 재생 중이면 일시정지
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        
        // throttle: 너무 자주 호출되지 않도록 제한 (드래그 중에는 더 자주 업데이트)
        let now = Date().timeIntervalSince1970
        if let lastSeek = lastSeekTime,
           now - lastSeek < seekThrottleInterval {
            return
        }
        lastSeekTime = now
        
        // 이전 seek 작업 취소
        seekTask?.cancel()
        
        guard let clip = clips.first(where: { $0.id == clipID }) else {
            return
        }
        
        // player.currentItem이 없으면 rebuildPreviewPlayer가 완료될 때까지 대기
        guard let currentItem = player.currentItem else {
            // currentItem이 없으면 나중에 다시 시도하기 위해 Task로 예약
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1초 대기
                self?.seekPreviewToTime(time: time, for: clipID)
            }
            return
        }
        
        // time은 사용자가 드래그한 새로운 시작 시간 (원본 영상의 시간)
        // buildPreviewItem에서는 각 클립의 trimStart부터 시작하는 구간을 composition에 삽입하므로,
        // composition 내에서의 시간 = 이전 클립들의 duration 합 + (time - 현재 클립의 trimStart)
        
        let clampedTime = min(max(time, 0), clip.duration)
        
        // 여러 클립이 있을 경우 order를 고려하여 composition 내의 시간 계산
        // buildPreviewItem에서 사용하는 로직과 정확히 일치하도록 구현
        let sortedClips = clips.sorted(by: { $0.order < $1.order })
        var compositionTime: CMTime = .zero
        
        // 선택된 클립 이전의 모든 클립의 trimDuration을 합산
        for previousClip in sortedClips {
            if previousClip.id == clipID {
                // 선택된 클립 내에서의 상대 시간 계산
                // buildPreviewItem: trimStart부터 시작하는 구간을 cursor 위치에 삽입
                // 따라서 composition 내에서의 시간 = 이전 클립들의 duration 합 + (clampedTime - trimStart)
                // 주의: composition은 이전 trimStart 값으로 만들어졌으므로, 새로운 time 위치로 seek하려면
                // 이전 trimStart를 기준으로 상대 시간을 계산해야 함
                let currentTrimStart = previousClip.trimStart // 현재 composition에 사용된 trimStart
                let safeStart = min(max(currentTrimStart, 0), previousClip.duration)
                let relativeTime = max(0, clampedTime - safeStart) // trimStart 기준 상대 시간
                compositionTime = CMTimeAdd(compositionTime, CMTime(seconds: relativeTime, preferredTimescale: 600))
                break
            } else {
                // 이전 클립의 trimDuration 추가 (buildPreviewItem과 정확히 동일한 로직)
                let safeStart = min(max(previousClip.trimStart, 0), previousClip.duration)
                let remaining = max(previousClip.duration - safeStart, 0)
                let trimmedDuration = min(max(previousClip.trimDuration, 0.1), remaining)
                compositionTime = CMTimeAdd(compositionTime, CMTime(seconds: trimmedDuration, preferredTimescale: 600))
            }
        }
        
        seekTask = Task { @MainActor [weak self] in
            guard let self = self, !Task.isCancelled else { return }
            
            // seek 실행 (tolerance를 설정하여 더 빠른 seek 가능)
            await currentItem.seek(to: compositionTime, toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
            
            // seek 완료 후 Task 정리
            if !Task.isCancelled {
                self.seekTask = nil
            }
        }
    }
    
    func playSelected2SecondRange(for clipID: UUID) async {
        guard let clip = clips.first(where: { $0.id == clipID }) else { return }
        guard let range = effectiveTrimRange(for: clip) else { return }
        
        // 선택된 클립의 2초 구간만 재생하기 위해 새로운 플레이어 아이템 생성
        let asset = clip.asset
        let composition = AVMutableComposition()
        
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        
        do {
            try compositionVideoTrack.insertTimeRange(range, of: videoTrack, at: .zero)
            
            let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks?.first,
               let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compositionAudioTrack.insertTimeRange(range, of: audioTrack, at: .zero)
            }
            
            let item = AVPlayerItem(asset: composition)
            await MainActor.run {
                player.replaceCurrentItem(with: item)
                player.seek(to: .zero)
                player.play()
                isPlaying = true
            }
            
            // 2초 후 자동 정지
            try? await Task.sleep(nanoseconds: UInt64(range.duration.seconds * 1_000_000_000))
            await MainActor.run {
                if isPlaying {
                    player.pause()
                    isPlaying = false
                }
            }
        } catch {
            // 에러 처리
        }
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
                            storedURL = try await VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: movie.url)
                        case .file(let url):
                            storedURL = try await VideoStorageManager.shared.prepareEditingAsset(for: self.draft.date, sourceURL: url)
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
        
        // 저장된 편집 정보 로드 (trim 정보 복원용)
        let savedComposition = VideoStorageManager.shared.loadEditingComposition(for: draft.date)
        let filenameToSelection: [String: PersistableEditingComposition.PersistableClipSelection] = {
            guard let savedComposition = savedComposition else { return [:] }
            return Dictionary(uniqueKeysWithValues: savedComposition.clipSelections.map { ($0.filename, $0) })
        }()
        
        for result in results.sorted(by: { $0.index < $1.index }) {
            let filename = result.url.lastPathComponent
            let savedSelection = filenameToSelection[filename]
            
            // 저장된 편집 정보가 있으면 복원, 없으면 기본값 사용
            let trimStart: Double
            let trimDuration: Double
            let rotationQuarterTurns: Int
            
            if let saved = savedSelection {
                trimStart = saved.trimStart
                trimDuration = min(saved.trimDuration, result.duration - trimStart)
                rotationQuarterTurns = saved.rotationQuarterTurns
            } else {
                trimStart = 0
                trimDuration = min(defaultTrimDuration, max(result.duration, 0.1))
                rotationQuarterTurns = 0
            }
            
            let frames = makeTimelineFrames(duration: result.duration)
            built.append(EditorClip(order: result.index,
                                    url: result.url,
                                    asset: result.asset,
                                    duration: result.duration,
                                    renderSize: result.renderSize,
                                    rotationQuarterTurns: rotationQuarterTurns,
                                    trimDuration: trimDuration,
                                    trimStart: trimStart,
                                    timelineFrames: frames))
            storedURLs.append(result.url)
        }

        // clips 배열이 채워지면 즉시 isLoading을 false로 설정하여 UI 반응성 개선
        clips = built
        isLoading = false
        
        // 첫 번째 클립을 기본 선택으로 설정
        if let firstClip = built.first {
            selectedClipID = firstClip.id
            await loadClipForPreview(firstClip)
        }

        // 비동기 작업들을 백그라운드에서 처리
        let draftDate = draft.date
        Task.detached(priority: .utility) { [storedURLs, draftDate] in
            if !storedURLs.isEmpty {
                VideoStorageManager.shared.saveEditingSources(storedURLs, for: draftDate)
            }
        }

        // 모든 썸네일 생성을 백그라운드로 이동하여 초기 로딩 속도 개선
        // 첫 번째 클립부터 우선 생성하되, await 없이 백그라운드에서 실행
        if !built.isEmpty {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.scheduleThumbnailGeneration(for: [0])
            }
        }
        
        // 나머지 클립의 썸네일은 백그라운드에서 생성
        if built.count > 1 {
            let remainingIndexes = Array(1..<built.count)
            Task.detached(priority: .utility) { [weak self] in
                await self?.scheduleThumbnailGeneration(for: remainingIndexes)
            }
        }
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

    func scheduleThumbnailGeneration(for targetIndexes: [Int]? = nil) async {
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

    func rotateClip(_ clip: EditorClip) async {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index].rotationQuarterTurns = normalizedQuarterTurns(clips[index].rotationQuarterTurns + 1)

        for frameIndex in clips[index].timelineFrames.indices {
            if let thumbnail = clips[index].timelineFrames[frameIndex].thumbnail {
                clips[index].timelineFrames[frameIndex].thumbnail = thumbnail.rotatedByQuarterTurns(1)
            }
        }

        await scheduleThumbnailGeneration(for: [index])

        Task { [weak self] in
            await self?.rebuildPreviewPlayer()
        }
    }

    func updateTrimStart(clipID: UUID, start: Double, rebuildPreview: Bool = false) {
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
        compositionOffsetsDirty = true

        // 드래그 중에는 미리보기 재생성을 건너뛰어 반응성 개선
        if rebuildPreview {
            Task { [weak self] in
                await self?.rebuildPreviewPlayer()
            }
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
    
    // PRD: 영상 비율 정보 제공
    func videoAspectRatio(for clipID: UUID?) -> CGFloat? {
        guard let clipID = clipID,
              let clip = clips.first(where: { $0.id == clipID }),
              clip.renderSize.height > 0 else {
            return nil
        }
        return clip.renderSize.width / clip.renderSize.height
    }
    
    // PRD: 현재 선택된 클립의 비율 정보
    var currentVideoAspectRatio: CGFloat? {
        videoAspectRatio(for: selectedClipID)
    }
    
    // PRD: 현재 선택된 클립의 renderSize
    var currentVideoSize: CGSize? {
        guard let selectedClipID = selectedClipID,
              let clip = clips.first(where: { $0.id == selectedClipID }) else {
            return nil
        }
        return clip.renderSize
    }

    deinit {
        previewRebuildDebounceTask?.cancel()
    }
}

