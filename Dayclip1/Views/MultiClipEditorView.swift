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
import UniformTypeIdentifiers

// MARK: - Multi Clip Editor Screen

struct MultiClipEditorView: View {
    let draft: EditorDraft
    let onCancel: () -> Void
    let onComplete: (EditorCompositionDraft?) -> Void
    let onDelete: () -> Void

    @StateObject private var viewModel: MultiClipEditorViewModel
    @State private var muteAudio = false

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
                // 헤더 위쪽 공간을 완전히 제거 (Safe Area = 0)
                let reducedSafeAreaTop: CGFloat = 0 // 헤더 위쪽 공간 없음
                let previewHeight = safePreviewHeight(screenHeight: geo.size.height, safeAreaInsets: geo.safeAreaInsets, screenWidth: geo.size.width, safeAreaTop: reducedSafeAreaTop)
                // 프레임 높이를 안전하게 보장 (NaN, infinity, 음수 방지)
                let safeFrameHeight: CGFloat = {
                    if previewHeight.isFinite && !previewHeight.isNaN && previewHeight > 0 {
                        return previewHeight + geo.safeAreaInsets.top // Safe Area 전체를 미리보기 영역에 추가
                    }
                    // 안전하지 않은 경우 최소값 사용
                    let minHeight = max(geo.size.width * 1.2, 200)
                    return minHeight.isFinite && !minHeight.isNaN ? minHeight : 200
                }()
                
                // 타임라인 영역의 최대 높이 계산 (남은 공간만 사용)
                let headerHeight: CGFloat = 88 // Safe Area 없이 헤더 높이만
                let bottomControlsHeight: CGFloat = 50
                let safeAreaBottom: CGFloat = geo.safeAreaInsets.bottom
                let spaceBetweenVideoAndTimeline: CGFloat = 10
                let spaceBelowTimeline: CGFloat = 60 // 타임라인 하단 여백 60pt
                let timelineMaxHeight = geo.size.height - headerHeight - safeFrameHeight - bottomControlsHeight - spaceBetweenVideoAndTimeline - spaceBelowTimeline - safeAreaBottom

                ZStack {
                    Color.black
                        .ignoresSafeArea()
                    
                    VStack(spacing: 0) {
//                        // PRD: 상단 헤더 영역 (고정 88pt, 위쪽 공간 없음) - 최상단에 배치
//                        headerSection(safeAreaTop:0) // 헤더 위쪽 공간 없음
//                            .zIndex(10) // 헤더가 항상 최상단에 표시되도록
                       
                        
                        // PRD: 미리보기 영역 (동적 크기, 비율 유지) - 헤더 바로 아래
                        previewSection(availableHeight: safeFrameHeight)
                            .frame(height: safeFrameHeight)
                            // .clipped() 제거하여 위아래가 잘리지 않도록
                        
                        // PRD: 하단 기능 아이콘 영역 (고정 50pt) - 미리보기 영역 바로 아래
                        bottomControlsSection
                            .frame(height: 50)
                            .background(Color.black) // 검은색 배경으로 분리
                        
                        // 영상과 타임라인 사이 공간 (10pt로 줄여 미리보기 영역 확대)
                        Spacer().frame(height: 10)
                        
                        // 타임라인 영역 - 음소거/휴지통 바로 아래
                        Group {
                            if let error = viewModel.errorMessage, viewModel.clips.isEmpty {
                                Text(error)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.white)
                                    .padding()
                                    .frame(height: 86)
                            } else if !viewModel.clips.isEmpty {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 24) {
                                        ForEach(viewModel.clips) { clip in
                                            clipTimeline(clip)
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.bottom, 60) // 타임라인과 페이지 밑 부분 사이 공간 60pt
                                }
                                .frame(height: 86) // 타임라인 영역을 고정 높이로 제한 (파란색 공간 최소화)
                            } else {
                                // 로딩 중에는 빈 상태로 표시 (스피너 제거)
                                Color.clear
                                    .frame(height: 86)
                            }
                        }
                   
                        .padding(.bottom, 20) // 타임라인 아래 여백 20pt
                    }
                }
            }
            .navigationTitle(formattedDate)
            .navigationBarTitleDisplayMode(.inline)
            // 화면 중앙에 전체 로딩 오버레이 하나만 표시
            .overlay {
                if viewModel.isLoading {
                    ZStack {
                        Color.black.opacity(0.7)
                            .ignoresSafeArea()
                        ProgressView("영상을 불러오는 중...")
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } else if viewModel.isBuildingPreview {
                    ZStack {
                        Color.black.opacity(0.5)
                            .ignoresSafeArea()
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .toolbar{
                ToolbarItem(placement:.topBarLeading){
                    Button {
                        viewModel.stopPlayback()
                        onCancel()
                    } label: {
                        

                        Image(systemName: "xmark")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(.white)
                                                    .frame(width: 35, height: 35)
                        .buttonStyle(.plain)
                        
                        .glassEffect(
                            .identity,
                            in:.circle
                                
                        )
                        

                            
                          

                    }

                
                    
  
                }//:xBTN toolbarITEM
                
                ToolbarItem(placement:.topBarTrailing){
                    Button {
                        viewModel.stopPlayback()
                        let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: nil)
                        onComplete(draft)
                    } label: {
                        Text("Done")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 65, height: 40)
                            
                            .glassEffect(
                                .identity,
                                in:.capsule
                            )
                    }
                    .buttonStyle(.plain)
                }
                

                
                
            }
        }
        
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            viewModel.stopPlayback()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
        .background(Color.black
            .ignoresSafeArea()
        )
    }
    
    // PRD: 고정 영역 높이 계산 (타임라인 높이를 고려하여 미리보기 높이 계산)
    private func calculatePreviewHeight(screenHeight: CGFloat, safeAreaInsets: EdgeInsets, safeAreaTop: CGFloat) -> CGFloat {
        let headerHeight: CGFloat = 88 // 헤더 높이만 (Safe Area 없음)
        let bottomControlsHeight: CGFloat = 50
        let spaceBetweenVideoAndTimeline: CGFloat = 10 // 영상과 타임라인 사이 공간
        let estimatedTimelineHeight: CGFloat = 86 // 타임라인 높이 (clipTimeline의 frame height)
        let spaceBelowTimeline: CGFloat = 60 // 타임라인과 페이지 하단 사이 공간 60pt
        let safeAreaBottom: CGFloat = safeAreaInsets.bottom
        
        // 모든 고정 영역을 제외한 미리보기 높이 계산
        let calculatedHeight = screenHeight - headerHeight - bottomControlsHeight - spaceBetweenVideoAndTimeline - estimatedTimelineHeight - spaceBelowTimeline - safeAreaBottom
        
        return calculatedHeight
    }

    // Clamp to finite, non-negative (with a minimum to keep layout stable)
    private func safePreviewHeight(screenHeight: CGFloat, safeAreaInsets: EdgeInsets, screenWidth: CGFloat, safeAreaTop: CGFloat) -> CGFloat {
        // 입력값 유효성 검사
        guard screenHeight.isFinite && !screenHeight.isNaN && screenHeight > 0,
              screenWidth.isFinite && !screenWidth.isNaN && screenWidth > 0 else {
            return 200 // 기본값 반환
        }
        
        let h = calculatePreviewHeight(screenHeight: screenHeight, safeAreaInsets: safeAreaInsets, safeAreaTop: safeAreaTop)
        
        // 계산된 높이 유효성 검사
        guard h.isFinite && !h.isNaN && h > 0 else {
            // 최소 높이를 너비의 1.2배로 설정하여 세로가 더 긴 형태 보장
            let minHeight = max(screenWidth * 1.2, 200)
            return minHeight.isFinite && !minHeight.isNaN ? minHeight : 200
        }
        
        return h
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: draft.date)
    }

    // PRD: 상단 헤더 영역
    private func headerSection(safeAreaTop: CGFloat) -> some View {
        ZStack {
            HStack {
                Button {
                    viewModel.stopPlayback()
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 35, height: 35)
                        .background(
                            Circle()
                                .fill(Color.gray.opacity(0.3))
                        )
                }
                .buttonStyle(.glass)
//                .padding(.leading, 16)
                
                Spacer()
                
                Button {
                    viewModel.stopPlayback()
                    let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: nil)
                    onComplete(draft)
                } label: {
                    Text("Done")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 65, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 50)
                                .fill(Color.gray.opacity(0.3))
                        )
                }
                .buttonStyle(.plain)
                .glassEffect()
//                .padding(.trailing, 16)
            }
            .padding(.top, 0) // 위쪽 패딩 없음
            
            // 날짜를 중앙에 배치
            Text(formattedDate)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white)
                .padding(.top, 0) // 위쪽 패딩 없음
        }
        .frame(maxWidth: .infinity)
        .frame(height: 88) // 헤더 높이만 (위쪽 공간 없음)
        .padding(.horizontal,16)
        .background(Color.red)
        
    }
    
    // PRD: 미리보기 영역 (비율 유지, letterboxing)
    private func previewSection(availableHeight: CGFloat) -> some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            
            // PRD: 미리보기 영역 비율 설정 (width 283, height 544)
            let previewAspectRatio: CGFloat = 283.0 / 544.0 // 약 0.52 (세로가 가로보다 약 1.92배 길음)
            
            // 컨테이너 크기 결정 (고정 비율 유지) - 클로저 표현식으로 변경
            let (containerWidth, containerHeight): (CGFloat, CGFloat) = {
                // 안전한 기본값
                let safeAvailableHeight = availableHeight.isFinite && !availableHeight.isNaN && availableHeight > 0 ? availableHeight : 500
                let safeScreenWidth = screenWidth.isFinite && !screenWidth.isNaN && screenWidth > 0 ? screenWidth : 200
                
                if safeScreenWidth / safeAvailableHeight > previewAspectRatio {
                    // 화면이 더 넓음 → height 기준으로 width 계산
                    let height = safeAvailableHeight
                    let width = height * previewAspectRatio
                    return (max(width, 100), max(height, 100))
                } else {
                    // 화면이 더 좁음 → width 기준으로 height 계산
                    let width = safeScreenWidth
                    let height = width / previewAspectRatio
                    return (max(width, 100), max(height, 100))
                }
            }()
            
            // 영상 비율 가져오기 (회전 고려)
            let videoAspect: CGFloat = {
                if let aspectRatio = viewModel.currentVideoAspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
                    return aspectRatio
                } else {
                    // 기본값 (16:9)
                    return 16.0 / 9.0
                }
            }()
            
            // PRD: 미리보기 크기 결정 로직 (컨테이너 비율 내에서 영상 비율 유지)
            let safeContainerWidth = containerWidth.isFinite && !containerWidth.isNaN && containerWidth > 0 ? containerWidth : 200
            let safeContainerHeight = containerHeight.isFinite && !containerHeight.isNaN && containerHeight > 0 ? containerHeight : 200
            let containerAspect = safeContainerHeight > 0 ? (safeContainerWidth / safeContainerHeight) : 1
            let (previewWidth, previewHeight): (CGFloat, CGFloat) = {
                if videoAspect > containerAspect {
                    // 가로가 더 긴 영상 → width 기준 스케일
                    let width = safeContainerWidth
                    let height = width / videoAspect
                    return (max(width, 100), max(height, 100))
                } else {
                    // 세로가 더 긴 영상 → height 기준 스케일
                    let height = safeContainerHeight
                    let width = height * videoAspect
                    return (max(width, 100), max(height, 100))
                }
            }()
            
            ZStack {
                // 배경은 검은색 (빨간색 박스는 이 영역 안에만 있어야 함)
                Color.black
                 
                 
                
                // 빨간색 박스와 비디오 플레이어를 중앙에 배치
                // availableHeight를 최대한 활용하여 위아래가 잘리지 않도록
                VStack(spacing: 0) {
                    Spacer()
                    ZStack {
                        // 빨간색 박스 - availableHeight를 고려하여 크기 조정 (95% 사용하여 여유 공간 확보)
                        let redBoxWidth = min(285, geo.size.width)
                        let redBoxHeight = min(545, geo.size.height * 0.95) // 95% 사용하여 위아래 여유 공간 확보
                        Color.black
                            .frame(width: redBoxWidth, height: redBoxHeight)
                        
                        // PRD: AspectFit으로 변경하여 원본 비율 유지, 전체 표시
                        VStack(alignment: .center) {
                            Spacer()
                            AspectFitVideoPlayer(player: viewModel.player)
                                .frame(width: max(previewWidth, 100), height: max(previewHeight, 100))
                                .frame(maxWidth: redBoxWidth * 0.96, maxHeight: redBoxHeight * 0.96) // 빨간 박스보다 작게 하여 위아래 여유 공간 확보
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Spacer()
                        }
                        .frame(width: max(safeContainerWidth, 100), height: max(safeContainerHeight, 100))
                    }
                    Spacer()
                }
                .frame(height: geo.size.height) // 정확히 GeometryReader의 높이만 사용
                
                if !viewModel.hasSelection && !viewModel.isLoading {
                    Text("선택된 구간이 없습니다.")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }
                
                // 재생 버튼 오버레이 (일시정지 상태일 때만 표시)
                if !viewModel.isLoading && viewModel.hasSelection && !viewModel.isBuildingPreview && !viewModel.isPlaying {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image("stop")
                            .renderingMode(.original)
                            .resizable()
                            .interpolation(.none)
                            .antialiased(false)
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                    }
                    .buttonStyle(.plain)
                }
            }
           
            
        }
        .task {
            activatePlaybackAudioSession()
        }
    }
    
    // PRD: 하단 기능 아이콘 영역
    private var bottomControlsSection: some View {
        HStack {
            // 음소거 토글 버튼 (왼쪽)
            Button {
                muteAudio.toggle()
                Task { await viewModel.rebuildPreviewPlayer(muteOriginal: muteAudio) }
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
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
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
            .frame(height: 86)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectedClipID = clip.id
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
            let totalWidth = geometry.size.width
            let duration = max(clip.duration, 0.1)
            let selectedDuration = max(clip.trimDuration, 0.1)
            let minWindowWidth: CGFloat = min(max(totalWidth * 0.2, 110), totalWidth)
            let rawWidth = CGFloat(selectedDuration / duration) * totalWidth
            
            // 계산 결과 (캐싱 제거 - SwiftUI가 자동으로 최적화)
            let selectionWidth = min(max(rawWidth.isFinite ? rawWidth : totalWidth, minWindowWidth), totalWidth)
            let travel = max(totalWidth - selectionWidth, 0)
            let maxStart = max(duration - selectedDuration, 0)
            
            // 드래그 중이면 로컬 offset 사용, 아니면 실제 clip.trimStart 사용
            let (ratio, selectionOffset): (Double, CGFloat) = {
                if let localOffset = localDragOffset {
                    // 드래그 중: 로컬 offset 사용
                    let calculatedRatio = travel > 0 ? Double(localOffset / travel) : 0
                    return (calculatedRatio, localOffset)
                } else {
                    // 드래그 중이 아님: 실제 clip.trimStart 사용
                    let calculatedRatio = maxStart > 0 ? clip.trimStart / maxStart : 0
                    let clampedRatio = min(max(calculatedRatio, 0), 1)
                    let calculatedOffset = travel * CGFloat(clampedRatio)
                    return (calculatedRatio, calculatedOffset)
                }
            }()

            // 썸네일 찾기 최적화 - 이진 검색 대신 인덱스 기반 접근
            let nearestThumbnail: (Double) -> UIImage? = { time in
                guard !clip.timelineFrames.isEmpty else { return nil }
                let target = min(max(time, 0), clip.duration)
                
                // 마지막 인덱스 주변부터 검색 (연속된 드래그에 최적화)
                let startIndex = max(0, lastThumbnailIndex - 2)
                let endIndex = min(clip.timelineFrames.count - 1, lastThumbnailIndex + 2)
                
                var nearest: (frame: MultiClipEditorViewModel.TimelineFrame, distance: Double)?
                
                // 주변 인덱스 먼저 검색
                for i in startIndex...endIndex {
                    let frame = clip.timelineFrames[i]
                    let distance = abs(frame.time - target)
                    if nearest == nil || distance < nearest!.distance {
                        nearest = (frame, distance)
                        lastThumbnailIndex = i
                    }
                }
                
                // 주변에서 찾지 못하면 전체 검색
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

            // 프리뷰 표시 최적화 - throttle 적용
            let presentPreview: (Double, CGFloat) -> Void = { time, offset in
                let clampedTime = min(max(time, 0), clip.duration)
                previewTime = clampedTime
                previewOffset = min(max(offset, 0), travel)
                // 썸네일 찾기는 드래그 중에는 덜 자주 호출되도록 최적화
                previewImage = nearestThumbnail(clampedTime)
                showPreview = previewImage != nil
            }

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(clip.timelineFrames) { frame in
                        Group {
                            if let image = frame.thumbnail {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.secondary.opacity(0.18)
                                    .overlay {
                                        ProgressView()
                                            .tint(.secondary)
                                            .scaleEffect(0.6)
                                    }
                            }
                        }
                        .frame(width: max(CGFloat(frame.length / duration) * totalWidth, 4), height: 80)
                        .clipped()
                    }
                }
                .frame(height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
               
                // 2초 선택 박스 (노란색) - 선택된 클립에만 표시
                if isSelected {
                    ZStack {
                        // 배경
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.yellow.opacity(0.22))
                            .frame(width: selectionWidth, height: 80)
                        
                        // 전체 테두리 (바깥쪽만 둥글게, 안쪽은 직각)
                        SelectionBoxBorderShape(
                            width: selectionWidth,
                            height: 80,
                            cornerRadius: 12,
                            leftRightBorderWidth: 8,
                            topBottomBorderWidth: 4
                        )
                        .fill(Color.yellow, style: FillStyle(eoFill: true))
                        
                        // 양방향 화살표 아이콘
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.yellow)
                    }
                    .frame(width: selectionWidth, height: 80)
                    .offset(x: selectionOffset)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture()
                            .onChanged { value in
                                if dragOrigin == nil {
                                    // 드래그 시작 시 현재 selectionOffset을 기준으로 설정
                                    // localDragOffset이 있으면 그것을 사용, 없으면 실제 clip.trimStart 기반 계산값 사용
                                    let startOffset = localDragOffset ?? selectionOffset
                                    dragOrigin = startOffset
                                    localDragOffset = startOffset
                                }
                                let origin = dragOrigin ?? selectionOffset
                                let newOffset = min(max(origin + value.translation.width, 0), travel)
                                
                                // 드래그 중에는 로컬 상태만 업데이트 (뷰 재렌더링 최소화)
                                localDragOffset = newOffset
                                
                                // progress 계산 (0.0-1.0)
                                let progress = travel > 0 ? max(0.0, min(1.0, Double(newOffset / travel))) : 0.0
                                let newStart = progress * maxStart
                                
                                // 프리뷰는 조금만 이동해도 즉시 업데이트 (1pt 이상)
                                if abs(previewOffset - newOffset) > 1 {
                                    presentPreview(newStart, newOffset)
                                    // 드래그 중 미리보기 영상의 재생 위치를 실시간으로 변경 (YouTube 스타일 scrubbing)
                                    onScrub(progress)
                                }
                                
                                // 실제 상태 업데이트는 하지 않음 (드래그 종료 시에만)
                            }
                            .onEnded { _ in
                                // 드래그 종료 시 최종 progress 계산 및 finishScrubbing 호출
                                if let finalOffset = localDragOffset {
                                    let finalProgress = travel > 0 ? max(0.0, min(1.0, Double(finalOffset / travel))) : 0.0
                                    let finalStart = finalProgress * maxStart
                                    
                                    // finishScrubbing 호출 (내부에서 trimStart 업데이트 및 rebuildPreviewPlayer 처리)
                                    onFinishScrubbing(finalProgress)
                                    
                                    // 호환성을 위해 onTrimStartChange도 호출 (내부에서 중복 처리 방지됨)
                                    onTrimStartChange(finalStart)
                                }
                                
                                // 상태 초기화
                                dragOrigin = nil
                                localDragOffset = nil
                                showPreview = false
                            }
                    )
                }

                if showPreview, let previewImage {
                    let previewWidth: CGFloat = 120
                    let clampedX = min(max(previewOffset + selectionWidth / 2, previewWidth / 2), geometry.size.width - previewWidth / 2)

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
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.7), in: Capsule())
                    }
                    .position(x: clampedX, y: -46)
                    .transition(.opacity)
                }
            }
            .onChange(of: clip.id) { _, _ in
                // clip이 변경되면 로컬 상태 초기화
                localDragOffset = nil
                lastThumbnailIndex = 0
                dragOrigin = nil
            }
            .onChange(of: clip.trimStart) { _, _ in
                // clip.trimStart가 변경되면 로컬 드래그 상태 초기화 (상태 동기화)
                if localDragOffset == nil {
                    // 드래그 중이 아닐 때만 초기화 (드래그 중에는 로컬 상태 유지)
                    dragOrigin = nil
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // 노란 박스가 아닌 영역에서만 작동하도록
                        guard isSelected else { return }
                        // 노란 박스 영역인지 확인 (offset을 고려)
                        let currentOffset = localDragOffset ?? selectionOffset
                        let boxStart = currentOffset
                        let boxEnd = currentOffset + selectionWidth
                        let touchX = value.location.x
                        
                        // 노란 박스 영역이 아니면 전체 타임라인 드래그
                        if touchX < boxStart || touchX > boxEnd {
                            let rawOffset = min(max(value.location.x - selectionWidth / 2, 0), travel)
                            
                            // 드래그 중에는 로컬 상태만 업데이트
                            localDragOffset = rawOffset
                            
                            let progress = travel > 0 ? max(0.0, min(1.0, Double(rawOffset / travel))) : 0.0
                            let newStart = progress * maxStart
                            
                            // 프리뷰는 조금만 이동해도 즉시 업데이트 (1pt 이상)
                            if abs(previewOffset - rawOffset) > 1 {
                                presentPreview(newStart, rawOffset)
                                // 드래그 중 미리보기 영상의 재생 위치를 실시간으로 변경 (YouTube 스타일 scrubbing)
                                onScrub(progress)
                            }
                        }
                    }
                    .onEnded { _ in
                        // 드래그 종료 시 최종 progress 계산 및 finishScrubbing 호출
                        if let finalOffset = localDragOffset {
                            let finalProgress = travel > 0 ? max(0.0, min(1.0, Double(finalOffset / travel))) : 0.0
                            let finalStart = finalProgress * maxStart
                            
                            // finishScrubbing 호출 (내부에서 trimStart 업데이트 및 rebuildPreviewPlayer 처리)
                            onFinishScrubbing(finalProgress)
                            
                            // 호환성을 위해 onTrimStartChange도 호출
                            onTrimStartChange(finalStart)
                        }
                        showPreview = false
                    }
            )
        }
    }

    private func formatTime(_ time: Double) -> String {
        let total = Int(time.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
