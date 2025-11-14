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
    let onComplete: (EditorCompositionDraft) -> Void

    @StateObject private var viewModel: MultiClipEditorViewModel
    @State private var muteAudio = false
    @State private var selectedTrackID: UUID? = nil
    @State private var trackVolume: Double = 0.6
    @State private var userTrackOptions: [BackgroundTrackOption] = []
    @State private var showAudioImporter = false
    @State private var isImportingAudio = false

    private var allTrackOptions: [BackgroundTrackOption] {
        BackgroundTrackOption.builtInOptions + userTrackOptions
    }

    init(draft: EditorDraft, onCancel: @escaping () -> Void, onComplete: @escaping (EditorCompositionDraft) -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onComplete = onComplete
        _viewModel = StateObject(wrappedValue: MultiClipEditorViewModel(draft: draft))
    }

    private var selectedTrackOption: BackgroundTrackOption? {
        guard let id = selectedTrackID else { return nil }
        return allTrackOptions.first(where: { $0.id == id })
    }

    private var backgroundSelection: BackgroundTrackSelection? {
        guard let option = selectedTrackOption else { return nil }
        return BackgroundTrackSelection(option: option, volume: Float(trackVolume))
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
            .navigationTitle(formattedDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") {
                        viewModel.stopPlayback()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") {
                        if let draft = viewModel.makeCompositionDraft(muteOriginalAudio: muteAudio, backgroundTrack: backgroundSelection) {
                            viewModel.stopPlayback()
                            onComplete(draft)
                        }
                    }
                    .disabled(!viewModel.hasSelection || viewModel.isLoading || viewModel.isBuildingPreview)
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
        formatter.dateFormat = "yyyy. MM. dd"
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
            }
            .padding(.horizontal)

            HStack {
                Button {
                    viewModel.togglePlayback()
                } label: {
                    Label(viewModel.isPlaying ? "일시정지" : "재생", systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.15)))
                .disabled(viewModel.player.currentItem == nil)

                Spacer()

                Button {
                    Task { await viewModel.rebuildPreviewPlayer(muteOriginal: muteAudio, backgroundTrack: .some(backgroundSelection)) }
                } label: {
                    Label("미리보기 갱신", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.1)))
            }
            .padding(.horizontal)

            Toggle(isOn: $muteAudio) {
                Label(muteAudio ? "음소거 켜짐" : "음소거 해제", systemImage: muteAudio ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .padding(.horizontal)
            .padding(.bottom, 4)
            .onChange(of: muteAudio) { _, newValue in
                Task { await viewModel.rebuildPreviewPlayer(muteOriginal: newValue) }
            }

            VStack(alignment: .leading, spacing: 12) {
                Picker("배경 음악", selection: $selectedTrackID) {
                    Text("없음")
                        .tag(nil as UUID?)
                    ForEach(allTrackOptions) { option in
                        Text(option.displayName)
                            .tag(option.id as UUID?)
                    }
                }
                .pickerStyle(.menu)

                if selectedTrackOption != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("음악 볼륨", systemImage: "music.note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%%", trackVolume * 100))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $trackVolume, in: 0...1)
                            .onChange(of: trackVolume) { _, _ in
                                Task { await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(backgroundSelection)) }
                            }
                    }
                }

                Button {
                    showAudioImporter = true
                } label: {
                    Label(isImportingAudio ? "불러오는 중..." : "파일에서 선택", systemImage: "folder.badge.plus")
                }
                .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.08)))
                .disabled(isImportingAudio)
            }
            .padding(.horizontal)
            .onChange(of: selectedTrackID) { _, newValue in
                if let id = newValue, let option = allTrackOptions.first(where: { $0.id == id }) {
                    trackVolume = option.defaultVolume
                }
                Task { await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(backgroundSelection)) }
            }
        }
        .task {
            userTrackOptions = VideoStorageManager.shared.loadImportedBackgroundTracks()
            if let option = selectedTrackOption {
                trackVolume = option.defaultVolume
            }
            activatePlaybackAudioSession()
            await viewModel.rebuildPreviewPlayer(muteOriginal: muteAudio, backgroundTrack: .some(backgroundSelection))
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await importBackgroundTrack(from: url)
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
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
                Button {
                    viewModel.rotateClip(clip)
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.leading, 8)
            }

            TimelineTrimView(clip: clip) { newStart in
                viewModel.updateTrimStart(clipID: clip.id, start: newStart)
            }
            .frame(height: 86)

            HStack {
                Label("영상 길이 \(viewModel.formatDuration(clip.duration))", systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func importBackgroundTrack(from url: URL) async {
        await MainActor.run {
            isImportingAudio = true
        }

        do {
            let option = try VideoStorageManager.shared.importBackgroundTrack(from: url)
            let selection = await MainActor.run { () -> BackgroundTrackSelection? in
                let resolvedOption: BackgroundTrackOption
                if let existingIndex = userTrackOptions.firstIndex(where: { $0.source == option.source }) {
                    resolvedOption = userTrackOptions[existingIndex]
                } else {
                    userTrackOptions.append(option)
                    resolvedOption = option
                }
                selectedTrackID = resolvedOption.id
                trackVolume = resolvedOption.defaultVolume
                return backgroundSelection
            }
            await viewModel.rebuildPreviewPlayer(backgroundTrack: .some(selection))
        } catch {
            await MainActor.run {
                viewModel.errorMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            isImportingAudio = false
        }
    }
}

// MARK: - Timeline Trim View

struct TimelineTrimView: View {
    let clip: MultiClipEditorViewModel.EditorClip
    let onTrimStartChange: (Double) -> Void

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

                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                    )
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
                            }
                    )

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
                        let rawOffset = min(max(value.location.x - selectionWidth / 2, 0), travel)
                        let newRatio = travel > 0 ? Double(rawOffset / travel) : 0
                        let newStart = newRatio * maxStart
                        presentPreview(newStart, rawOffset)
                    }
                    .onEnded { _ in
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

