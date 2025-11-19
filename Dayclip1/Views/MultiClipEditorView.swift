//
//  MultiClipEditorView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
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
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 20) {
                    previewSection

                    if viewModel.isLoading {
                        Spacer()
                        ProgressView("영상을 불러오는 중...")
                        Spacer()
                    } else if let error = viewModel.errorMessage, viewModel.clips.isEmpty {
                        Spacer()
                        Text(error)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                        Spacer()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                ForEach(viewModel.clips) { clip in
                                    clipTimeline(clip)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 32)
                        }
                    }
                }
            }

            .toolbar {
                ToolbarItem {
                    HStack{
                        Button {
                            viewModel.stopPlayback()
                            onCancel()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .frame(width:35, height: 35)
                                .background(
                                    Circle()
                                    
                                )
                        }
                        .buttonStyle(.plain)
                       
                        
                        
                        Spacer()
                        
                        Text(formattedDate)
                        Spacer()
                        
                        Button {
                            viewModel.stopPlayback()
                            let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: nil)
                            onComplete(draft)
                        }label: {
                           
                            Text("Done")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
    //                            .padding(.horizontal, 16)
                                .frame(width:60, height: 35)
                                .background(
                                    RoundedRectangle(cornerRadius: 50)
//                                        .fill(.white)
                                )
                                
                        }
                        .buttonStyle(.plain)

                        
                    }
                  
                 
                   
                }

            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            viewModel.stopPlayback()
        }
        .onDisappear {
            viewModel.stopPlayback()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: draft.date)
    }

    private var previewSection: some View {
        VStack(spacing: 12) {
            ZStack {
                AspectFillVideoPlayer(player: viewModel.player)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if viewModel.isLoading {
                    ProgressView()
                } else if !viewModel.hasSelection {
                    Text("선택된 구간이 없습니다.")
                        .font(.footnote)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }

                if viewModel.isBuildingPreview {
                    ProgressView()
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
            .padding(.horizontal, 54)

            // 비디오 아래 컨트롤 바
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
                }
                .buttonStyle(.plain)

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
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .task {
            activatePlaybackAudioSession()
            // 초기 로딩 시 미리보기 생성을 건너뛰어 로딩 속도 개선
            // 사용자가 재생 버튼을 누를 때 rebuildPreviewPlayer가 호출됨
        }
    }

    private func clipTimeline(_ clip: MultiClipEditorViewModel.EditorClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("클립 \(clip.order + 1)")
                    .font(.headline)
                Spacer()
                Text(viewModel.trimDescription(for: clip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineTrimView(
                clip: clip,
                isSelected: viewModel.selectedClipID == clip.id,
                onTrimStartChange: { newStart in
                    // 드래그 중에는 미리보기 재생성 없이 상태만 업데이트
                    viewModel.updateTrimStart(clipID: clip.id, start: newStart, rebuildPreview: false)
                },
                onDragEnd: {
                    if viewModel.selectedClipID == clip.id {
                        // 드래그 종료 후 선택된 2초 구간 재생 (비동기로 실행하여 반응성 개선)
                        Task.detached(priority: .userInitiated) { [weak viewModel, clipID = clip.id] in
                            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1초 딜레이
                            await viewModel?.playSelected2SecondRange(for: clipID)
                        }
                    }
                }
            )
            .frame(height: 86)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectedClipID = clip.id
            }

            HStack {
                Label("영상 길이 \(viewModel.formatDuration(clip.duration))", systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

// MARK: - Timeline Trim View

struct TimelineTrimView: View {
    let clip: MultiClipEditorViewModel.EditorClip
    let isSelected: Bool
    let onTrimStartChange: (Double) -> Void
    let onDragEnd: () -> Void

    @State private var dragOrigin: CGFloat?
    @State private var previewImage: UIImage?
    @State private var previewTime: Double = 0
    @State private var previewOffset: CGFloat = 0
    @State private var showPreview = false

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let duration = max(clip.duration, 0.1)
            let selectedDuration = max(clip.trimDuration, 0.1)
            let minWindowWidth: CGFloat = min(max(totalWidth * 0.2, 110), totalWidth)
            let rawWidth = CGFloat(selectedDuration / duration) * totalWidth
            let selectionWidth = min(max(rawWidth.isFinite ? rawWidth : totalWidth, minWindowWidth), totalWidth)
            let travel = max(totalWidth - selectionWidth, 0)
            let maxStart = max(duration - selectedDuration, 0)
            let ratio = maxStart > 0 ? clip.trimStart / maxStart : 0
            let clampedRatio = min(max(ratio, 0), 1)
            let selectionOffset = travel * CGFloat(clampedRatio)

            let nearestThumbnail: (Double) -> UIImage? = { time in
                guard !clip.timelineFrames.isEmpty else { return nil }
                let target = min(max(time, 0), clip.duration)
                let nearest = clip.timelineFrames.min(by: { abs($0.time - target) < abs($1.time - target) })
                return nearest?.thumbnail
            }

            let presentPreview: (Double, CGFloat) -> Void = { time, offset in
                let clampedTime = min(max(time, 0), clip.duration)
                previewTime = clampedTime
                previewOffset = min(max(offset, 0), travel)
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
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragOrigin == nil { dragOrigin = selectionOffset }
                                let origin = dragOrigin ?? selectionOffset
                                let newOffset = min(max(origin + value.translation.width, 0), travel)
                                let newRatio = travel > 0 ? Double(newOffset / travel) : 0
                                let newStart = newRatio * maxStart
                                presentPreview(newStart, newOffset)
                                onTrimStartChange(newStart)
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                showPreview = false
                                onDragEnd()
                            }
                    )
                }

                if showPreview, let previewImage {
                    let previewWidth: CGFloat = 120
                    let clampedX = min(max(previewOffset + selectionWidth / 2, previewWidth / 2), totalWidth - previewWidth / 2)

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
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isSelected else { return }
                        let rawOffset = min(max(value.location.x - selectionWidth / 2, 0), travel)
                        let newRatio = travel > 0 ? Double(rawOffset / travel) : 0
                        let newStart = newRatio * maxStart
                        presentPreview(newStart, rawOffset)
                        onTrimStartChange(newStart)
                    }
                    .onEnded { _ in
                        showPreview = false
                        if isSelected {
                            onDragEnd()
                        }
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


