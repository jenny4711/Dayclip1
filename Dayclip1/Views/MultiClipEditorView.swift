//
//  MultiClipEditorView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//
//  SCRUBBING IMPLEMENTATION (YouTube-style)
//  ========================================
//  This file implements YouTube-style video scrubbing for the timeline view.
//
//  Key Changes:
//  - TimelineTrimView now uses progress-based scrubbing (0.0-1.0)
//  - onScrub callback: Calculates progress from drag offset and calls ViewModel.scrub()
//  - onFinishScrubbing callback: Calculates final progress and calls ViewModel.finishScrubbing()
//  - Progress calculation: progress = max(0.0, min(1.0, offset / travel))
//
//  How it works:
//  1. User drags yellow box → Calculate progress from x-position
//  2. Call onScrub(progress) → ViewModel pauses player and seeks to that position
//  3. On drag end → Call onFinishScrubbing(progress) → ViewModel updates trimStart and rebuilds preview
//
//  The yellow box drag now feels like YouTube's seek bar: immediate preview updates as you drag.
//

import SwiftUI
import AVFoundation


// MARK: - Multi Clip Editor Screen

struct MultiClipEditorView: View {
    let draft: EditorDraft
    let onCancel: () -> Void
    let onComplete: (EditorCompositionDraft?) -> Void
    let onDelete: () -> Void

    @StateObject private var viewModel: MultiClipEditorViewModel
    @State private var muteAudio = false
    @State private var showPlayPauseButton = true // 재생/일시정지 버튼 표시 여부

    init(draft: EditorDraft, onCancel: @escaping () -> Void, onComplete: @escaping (EditorCompositionDraft?) -> Void, onDelete: @escaping () -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onComplete = onComplete
        self.onDelete = onDelete
        _viewModel = StateObject(wrappedValue: MultiClipEditorViewModel(draft: draft))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                editorLayout(for: geo)
            }
            .navigationTitle(formattedDate)
            .navigationBarTitleDisplayMode(.inline)
            .overlay { blockingOverlay }
            .toolbar {
                cancelToolbar
                doneToolbar
            }
        }
        
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            viewModel.stopPlayback()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
        .onChange(of: viewModel.isPlaying) { oldValue, newValue in
            if newValue {
                // 재생 시작 시 버튼을 잠시 보여준 후 숨김
                showPlayPauseButton = true
                // 1초 후 버튼 숨김
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // 1초
                    if viewModel.isPlaying {
                        showPlayPauseButton = false
                    }
                }
            } else {
                // 재생 중지 시 버튼 표시
                showPlayPauseButton = true
            }
        }
        .background(Color.black
            .ignoresSafeArea()
        )
    }
    @ViewBuilder
    private func editorLayout(for geo: GeometryProxy) -> some View {
        let metrics = EditorLayoutMetrics(geometry: geo)
        
        return ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                previewSection(availableHeight: metrics.videoAreaHeight)
                    .frame(maxWidth: .infinity)
                
                bottomControlsBar(metrics: metrics)
//                    .padding(.top, metrics.videoToControlsSpacing)
//                    .padding(.bottom, metrics.safeBottomInset)
            }
            .padding(.top, metrics.contentTopInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            
        }
     
    }
    
    @ViewBuilder
    private func timelineSection(containerHeight: CGFloat) -> some View {
        if let error = viewModel.errorMessage, viewModel.clips.isEmpty {
            Text(error)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)

                .frame(height: containerHeight)
        } else if !viewModel.clips.isEmpty {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(viewModel.clips) { clip in
                        clipTimeline(clip)
                    }
                }

            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.never)
            .frame(height: containerHeight, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Color.clear
                .frame(height: containerHeight)
        }
    }

    @ViewBuilder
    private func bottomControlsBar(metrics: EditorLayoutMetrics) -> some View {
        VStack(spacing: 12) {
            bottomControlsSection
                .frame(height: metrics.bottomControlsHeight)
            
            timelineSection(containerHeight: metrics.timelineHeight)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private var blockingOverlay: some View {
        if viewModel.isLoading || viewModel.isBlockingRebuild || !viewModel.isPlayerReady {
            // Keep the "Downloading…" copy visible until all work (download, rebuild,
            // player readiness) is finished so the UI doesn't switch to a bare spinner.
            overlayCard(label: "Downloading…", opacity: 1)
        }
    }
    
    @ViewBuilder
    private func overlayCard(label: String?, opacity: Double) -> some View {
        ZStack {
            Color.black.opacity(opacity).ignoresSafeArea()
            if let label {
                ProgressView(label)
                    .progressViewStyle(.circular)
                    .tint(.white)
//                    .padding(20)
//                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
//                    .padding(20)
//                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
    
    @ToolbarContentBuilder
    private var cancelToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                viewModel.stopPlayback()
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 35, height: 35)
            }
            .buttonStyle(.plain)
            .glassEffect(.identity, in: .circle)
        }
    }
    
    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        if !viewModel.isLoading && !viewModel.isBlockingRebuild && viewModel.isPlayerReady {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.stopPlayback()
                    let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: nil)
                    onComplete(draft)
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 65, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.identity, in: .capsule)
            }
        }
    }
    
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: draft.date)
    }

    private struct EditorLayoutMetrics {
        private let geometry: GeometryProxy
        
        let bottomControlsHeight: CGFloat = 50
        let timelineHeight: CGFloat = 86
        let videoToControlsSpacing: CGFloat = 12
        
        init(geometry: GeometryProxy) {
            self.geometry = geometry
        }
        
        var safeTopInset: CGFloat { geometry.safeAreaInsets.top }
        var safeBottomInset: CGFloat { geometry.safeAreaInsets.bottom }
        var contentTopInset: CGFloat { 0 }
        
        private var bottomBarContentHeight: CGFloat {
            timelineHeight + bottomControlsHeight
        }
        
        var videoAreaHeight: CGFloat {
            let available = geometry.size.height - contentTopInset - safeBottomInset - bottomBarContentHeight - videoToControlsSpacing
            return max(available, 0)
        }
    }


    
    // MARK: Preview Area — occupies everything between nav & bottom controls
    private func previewSection(availableHeight: CGFloat) -> some View {
        let clampedHeight = max(availableHeight, 0)
        
        return GeometryReader { geo in
            let containerSize = CGSize(width: geo.size.width, height: clampedHeight)
            let aspect = viewModel.currentVideoAspectRatio ?? (9.0 / 16.0)
            let videoSize = videoDisplaySize(for: aspect, in: containerSize)
            
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.red)
                    .frame(width: videoSize.width, height: videoSize.height)
                    .overlay(
                        AspectFitVideoPlayer(player: viewModel.player)
                            .frame(width: videoSize.width, height: videoSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    )
                
                if !viewModel.hasSelection && !viewModel.isLoading {
                    Text("선택된 구간이 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .background(.thinMaterial, in: Capsule())
                }
                
                if !viewModel.isLoading && viewModel.hasSelection && !viewModel.isBlockingRebuild && showPlayPauseButton {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height, alignment: .center)
           
        }
        .frame(height: clampedHeight)
        .task {
            activatePlaybackAudioSession()
        }
    }
    
    private func aspectFitSize(for aspectRatio: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0,
              container.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else {
            return .zero
        }
        
        let containerAspect = container.width / container.height
        if aspectRatio > containerAspect {
            let width = container.width
            return CGSize(width: width, height: width / aspectRatio)
        } else {
            let height = container.height
            return CGSize(width: height * aspectRatio, height: height)
        }
    }
    
    /// Returns an aspect-fit size that prefers full width for landscape clips
    /// and full height for portrait/square clips, while never exceeding the
    /// provided container.
    private func videoDisplaySize(for aspectRatio: CGFloat, in container: CGSize) -> CGSize {
        guard container.width > 0,
              container.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else {
            return .zero
        }
        
        // Step 1: choose the dominant dimension (width for landscape, height for portrait).
        var targetWidth: CGFloat
        var targetHeight: CGFloat
        
        if aspectRatio > 1 {
            targetWidth = container.width
            targetHeight = targetWidth / aspectRatio
        } else {
            targetHeight = container.height
            targetWidth = targetHeight * aspectRatio
        }
        
        // Step 2: if the preferred dimensions overflow the container, scale them
        // down uniformly so the video remains fully visible (standard aspect-fit).
        let widthScale = container.width / max(targetWidth, .leastNonzeroMagnitude)
        let heightScale = container.height / max(targetHeight, .leastNonzeroMagnitude)
        let scale = min(1, widthScale, heightScale)
        
        return CGSize(width: targetWidth * scale, height: targetHeight * scale)
    }
    
    // PRD: 하단 기능 아이콘 영역
    private var bottomControlsSection: some View {
        HStack {
            // 로딩 중이 아니고, 클립이 로드되었고, 타임라인이 준비되었을 때만 아이콘 표시
            // clips.isEmpty 체크 추가: 영상과 타임라인이 보여지기 전까지 아이콘 숨김
            if !viewModel.isLoading && !viewModel.isBlockingRebuild && !viewModel.clips.isEmpty {
                // 타임라인 썸네일이 하나라도 로드되었는지 확인
                let hasThumbnails = viewModel.clips.contains { clip in
                    clip.timelineFrames.contains { $0.thumbnail != nil }
                }
                
                if hasThumbnails {
                    // 음소거 토글 버튼 (왼쪽)
                    Button {
                        muteAudio.toggle()
                        viewModel.setMuteOriginal(muteAudio)
                    } label: {
                        Image(muteAudio ? "soundOFF" : "soundON")
                            .renderingMode(.original)
                            .resizable()
                          
                            .interpolation(.none)
                            .antialiased(false)
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                    
                    Spacer()
                    
                    // 휴지통 버튼 (오른쪽)
                    Button {
                        viewModel.stopPlayback()
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.white)
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                } else {
                    // 썸네일이 아직 로드되지 않았을 때는 빈 공간만 유지
               
            Spacer()
                }
            } else {
                // 로딩 중일 때는 빈 공간만 유지
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
      
    }
    
    private func clipTimeline(_ clip: MultiClipEditorViewModel.EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
//            HStack {
//                Text("클립 \(clip.order + 1)")
//                    .font(.headline)
//                Spacer()
//                Text(viewModel.trimDescription(for: clip))
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//            }

            TimelineTrimView(
                clip: clip,
                isSelected: viewModel.selectedClipID == clip.id,
                onTrimStartChange: { newStart in
                    // 호환성을 위해 유지 (finishScrubbing에서도 처리됨)
                    viewModel.updateTrimStart(clipID: clip.id, start: newStart, rebuildPreview: false)
                },
                onScrub: { progress in
                    // 드래그 중 미리보기 영상의 재생 위치를 실시간으로 변경 (YouTube 스타일 scrubbing)
                    viewModel.scrub(to: progress, for: clip.id)
                },
                onFinishScrubbing: { progress in
                    // 드래그 종료 시 최종 위치로 seek하고 상태 업데이트
                    viewModel.finishScrubbing(at: progress, for: clip.id)
                }
            )
            .frame(height: 86, alignment: .top)
            .background(.black)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectClip(clip.id)
            }

//            HStack {
//                Label("영상 길이 \(viewModel.formatDuration(clip.duration))", systemImage: "film")
//                    .font(.caption)
//                    .foregroundStyle(.secondary)
//                Spacer()
//            }
        }
     
      
    }
}

// MARK: - Timeline Trim View

struct TimelineTrimView: View {
    let clip: MultiClipEditorViewModel.EditorClip
    let isSelected: Bool
    let onTrimStartChange: (Double) -> Void
    let onScrub: (Double) -> Void  // progress (0.0-1.0) 기반 scrubbing
    let onFinishScrubbing: (Double) -> Void  // progress (0.0-1.0) 기반 finish
    
    @State private var dragOrigin: CGFloat?
    @State private var previewImage: UIImage?
    @State private var previewTime: Double = 0
    @State private var previewOffset: CGFloat = 0
    @State private var showPreview = false
    // 로컬 드래그 상태 - 드래그 중에는 이 값만 업데이트하여 뷰 재렌더링 최소화
    @State private var localDragOffset: CGFloat?
    // 썸네일 찾기 최적화를 위한 인덱스 캐시
    @State private var lastThumbnailIndex: Int = 0
    
    var body: some View {
        GeometryReader { geometry in
            timelineContent(totalWidth: geometry.size.width)
        }
    }
    
    @ViewBuilder
    private func timelineContent(totalWidth: CGFloat) -> some View {
        let duration = max(clip.duration, 0.1)
        let selectedDuration = max(clip.trimDuration, 0.1)
        
        let context = TimelineContext(
            clip: clip,
            totalWidth: totalWidth,
            duration: duration,
            selectedDuration: selectedDuration,
            localDragOffset: localDragOffset
        )
        
        let selectionWidth = context.selectionWidth
        let travel = context.travel
        let maxStart = context.maxStart
        let selectionOffset = context.selectionOffset
        
        let nearestThumbnail: (Double) -> UIImage? = { time in
            guard !clip.timelineFrames.isEmpty else { return nil }
            let target = min(max(time, 0), clip.duration)
            
            let startIndex = max(0, lastThumbnailIndex - 2)
            let endIndex = min(clip.timelineFrames.count - 1, lastThumbnailIndex + 2)
            
            var nearest: (frame: MultiClipEditorViewModel.TimelineFrame, distance: Double)?
            
            for i in startIndex...endIndex {
                let frame = clip.timelineFrames[i]
                let distance = abs(frame.time - target)
                if nearest == nil || distance < nearest!.distance {
                    nearest = (frame, distance)
                    lastThumbnailIndex = i
                }
            }
            
            if nearest == nil || nearest!.distance > 0.5 {
                for (index, frame) in clip.timelineFrames.enumerated() {
                    let distance = abs(frame.time - target)
                    if nearest == nil || distance < nearest!.distance {
                        nearest = (frame, distance)
                        lastThumbnailIndex = index
                    }
                }
            }
            
            return nearest?.frame.thumbnail
        }
        
        let presentPreview: (Double, CGFloat) -> Void = { time, offset in
            let clampedTime = min(max(time, 0), clip.duration)
            previewTime = clampedTime
            previewOffset = min(max(offset, 0), travel)
            previewImage = nearestThumbnail(clampedTime)
            showPreview = previewImage != nil
        }
        
        let applyDragOffset: (CGFloat) -> Void = { rawOffset in
            let clampedOffset = context.clampOffset(rawOffset)
            localDragOffset = clampedOffset
            let progress = context.progress(for: clampedOffset)
            let newStart = progress * maxStart
            
            if abs(previewOffset - clampedOffset) > 1 {
                presentPreview(newStart, clampedOffset)
            }
            
            onScrub(progress)
        }
        
        let finalizeDrag: () -> Void = {
            if let finalOffset = localDragOffset {
                let finalProgress = context.progress(for: finalOffset)
                let finalStart = finalProgress * maxStart
                onFinishScrubbing(finalProgress)
                onTrimStartChange(finalStart)
            }
            
            dragOrigin = nil
            localDragOffset = nil
            showPreview = false
        }
        
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 80)
            thumbnailStrip(totalWidth: totalWidth, duration: duration)
            selectionOverlay(selectionWidth: selectionWidth, selectionOffset: selectionOffset)
                .allowsHitTesting(isSelected)
                .highPriorityGesture(
                    DragGesture()
                        .onChanged { value in
                            if dragOrigin == nil {
                                let startOffset = localDragOffset ?? selectionOffset
                                dragOrigin = startOffset
                                localDragOffset = startOffset
                            }
                            let origin = dragOrigin ?? selectionOffset
                            let newOffset = min(max(origin + value.translation.width, 0), travel)
                            applyDragOffset(newOffset)
                        }
                        .onEnded { _ in
                            finalizeDrag()
                        }
                )
            
            previewBubble(totalWidth: totalWidth, selectionWidth: selectionWidth)
        }
        .frame(height: 80, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSelected else { return }

                        // 노란 박스 바깥을 잡으면 박스가 그 위치로 곧바로 이동할 수 있게 허용
                        let clampedX = context.clampOffset(value.location.x - selectionWidth / 2)
                        applyDragOffset(clampedX)
                    }
                    .onEnded { _ in
                        guard isSelected else { return }
                        finalizeDrag()
                    }
        )
        .onChange(of: clip.id) { _, _ in
            localDragOffset = nil
            lastThumbnailIndex = 0
            dragOrigin = nil
        }
        .onChange(of: clip.trimStart) { _, _ in
            if localDragOffset == nil {
                dragOrigin = nil
            }
        }
    }
    
    @ViewBuilder
    private func thumbnailStrip(totalWidth: CGFloat, duration: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(clip.timelineFrames) { frame in
                Group {
                    if let image = frame.thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.18)
                    }
                }
                .frame(width: max(CGFloat(frame.length / duration) * totalWidth, 4), height: 80)
                .clipped()
            }
        }
        .frame(height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    private func selectionOverlay(selectionWidth: CGFloat, selectionOffset: CGFloat) -> some View {
        selectionBox(width: selectionWidth)
            .frame(width: selectionWidth, height: 80)
            .offset(x: selectionOffset)
            .contentShape(Rectangle())
    }
    
    private func selectionBox(width: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.yellow.opacity(isSelected ? 0.22 : 0))
            
            SelectionBoxBorderShape(
                width: width,
                height: 80,
                cornerRadius: 12,
                leftRightBorderWidth: 8,
                topBottomBorderWidth: 4
            )
            .fill(Color.yellow, style: FillStyle(eoFill: true))
            .opacity(isSelected ? 1 : 0)
            
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.yellow)
                .opacity(isSelected ? 1 : 0)
        }
    }
    
    @ViewBuilder
    private func previewBubble(totalWidth: CGFloat, selectionWidth: CGFloat) -> some View {
        if showPreview, let previewImage {
            let previewWidth: CGFloat = 120
            let clampedX = min(
                max(previewOffset + selectionWidth / 2, previewWidth / 2),
                totalWidth - previewWidth / 2
            )
            
            VStack(spacing: 6) {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: previewWidth, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                Text(formatTime(previewTime))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
//                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7), in: Capsule())
            }
            .position(x: clampedX, y: -46)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let total = Int(time.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private struct TimelineContext {
        let selectionWidth: CGFloat
        let travel: CGFloat
        let maxStart: Double
        let selectionOffset: CGFloat
        let clip: MultiClipEditorViewModel.EditorClip
        
        init(clip: MultiClipEditorViewModel.EditorClip,
             totalWidth: CGFloat,
             duration: Double,
             selectedDuration: Double,
             localDragOffset: CGFloat?) {
            self.clip = clip
            let minWindowWidth: CGFloat = min(max(totalWidth * 0.2, 110), totalWidth)
            let rawWidth = CGFloat(selectedDuration / duration) * totalWidth
            self.selectionWidth = min(max(rawWidth.isFinite ? rawWidth : totalWidth, minWindowWidth), totalWidth)
            self.travel = max(totalWidth - selectionWidth, 0)
            self.maxStart = max(duration - selectedDuration, 0)
            self.selectionOffset = TimelineContext.selectionOffset(
                travel: travel,
                maxStart: maxStart,
                localDragOffset: localDragOffset,
                clip: clip
            )
        }
        
        private static func selectionOffset(travel: CGFloat, maxStart: Double, localDragOffset: CGFloat?, clip: MultiClipEditorViewModel.EditorClip) -> CGFloat {
            if let value = localDragOffset {
                return min(max(value, 0), travel)
            }
            let ratio = maxStart > 0 ? clip.trimStart / maxStart : 0
            let clamped = min(max(ratio, 0), 1)
            return travel * CGFloat(clamped)
        }
        
        func selectionOffset(localDragOffset: CGFloat?) -> CGFloat {
            Self.selectionOffset(travel: travel, maxStart: maxStart, localDragOffset: localDragOffset, clip: clip)
        }
        
        func selectionOffsetForCurrentState(localDragOffset: CGFloat?) -> CGFloat {
            selectionOffset(localDragOffset: localDragOffset)
        }
        
        func progress(for offset: CGFloat) -> Double {
            guard travel > 0 else { return 0 }
            return Double(min(max(offset / travel, 0), 1))
        }
        
        func clampOffset(_ value: CGFloat) -> CGFloat {
            min(max(value, 0), travel)
        }
    }
    
    
    // MARK: - Selection Box Border Shape
    
    struct SelectionBoxBorderShape: Shape {
        let width: CGFloat
        let height: CGFloat
        let cornerRadius: CGFloat
        let leftRightBorderWidth: CGFloat
        let topBottomBorderWidth: CGFloat
        
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let r = cornerRadius
            let lrWidth = leftRightBorderWidth
            let tbWidth = topBottomBorderWidth
            
            // 외부 경로 (바깥쪽 둥근 사각형) - 시계방향
            let outerRect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            path.addRoundedRect(in: outerRect, cornerSize: CGSize(width: r, height: r), style: .continuous)
            
            // 내부 경로 (안쪽 직각 사각형) - 반시계방향으로 추가하여 홀 생성
            let innerRect = CGRect(
                x: lrWidth,
                y: tbWidth,
                width: width - lrWidth * 2,
                height: height - tbWidth * 2
            )
            // 반시계방향으로 직사각형 추가
            path.move(to: CGPoint(x: innerRect.minX, y: innerRect.minY))
            path.addLine(to: CGPoint(x: innerRect.minX, y: innerRect.maxY))
            path.addLine(to: CGPoint(x: innerRect.maxX, y: innerRect.maxY))
            path.addLine(to: CGPoint(x: innerRect.maxX, y: innerRect.minY))
            path.closeSubpath()
            
            return path
        }
    }
    
}
