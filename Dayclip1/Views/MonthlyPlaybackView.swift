//
//  MonthlyPlaybackView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import AVFoundation

// MARK: - Monthly Playback Screen

struct MonthlyPlaybackView: View {
    let session: MonthlyPlaybackSession
    let onClose: () -> Void

    @StateObject private var viewModel: MonthlyPlaybackViewModel
    @State private var isExportingShare = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var shareError: String?
    
    // 영상 정보
    @State private var aspectRatio: CGFloat?
    
    // 가로 영상 corner radius (원하는 값으로 조정 가능)
    private let horizontalVideoCornerRadius: CGFloat = 22

    init(session: MonthlyPlaybackSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: MonthlyPlaybackViewModel(clips: session.clips))
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                let _ = {
                    let screenSize = UIScreen.main.bounds.size
                    print("🔍 디바이스 전체 사이즈 (UIScreen): width: \(screenSize.width), height: \(screenSize.height)")
                    print("🔍 proxy.size: width: \(proxy.size.width), height: \(proxy.size.height)")
                    print("🔍 safeAreaInsets: top: \(proxy.safeAreaInsets.top), bottom: \(proxy.safeAreaInsets.bottom), leading: \(proxy.safeAreaInsets.leading), trailing: \(proxy.safeAreaInsets.trailing)")
                }()
            }
            
            Group {
                let containerSize = CGSize(width: proxy.size.width, height: proxy.size.height)
                let editorVideoAreaHeight = calculateEditorVideoAreaHeight(geometry: proxy)
                
                let _ = {
                    print("🔍 containerSize: \(containerSize)")
                }()
                
                ZStack {
                    Color.black.ignoresSafeArea()
                    if session.clips.isEmpty {
                        Text("No saved videos.")
                            .foregroundStyle(.white)
                    } else {
                        videoDisplayView(containerSize: containerSize, editorVideoAreaHeight: editorVideoAreaHeight)
                            .allowsHitTesting(false) // 비디오 플레이어가 터치 이벤트를 가로채지 않도록
                        
                        infoOverlay
                        
                        if viewModel.isLoading {
                            ProgressView("Preparing video...")
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .padding(20)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .shadow(radius: 8)
                        }
                    }
                }
            }
        }
        .onAppear {
            activatePlaybackAudioSession()
            viewModel.start()
            loadCurrentClipInfo()
        }
        .onChange(of: viewModel.currentIndex) { _, _ in
            loadCurrentClipInfo()
        }
        .onDisappear { viewModel.stop() }
        .overlay(alignment: .center) {
            if isExportingShare {
                ProgressView("Preparing video...")
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(radius: 8)
            }
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            if let url = shareURL {
                try? FileManager.default.removeItem(at: url)
            }
            shareURL = nil
        }) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            } else {
                Text("No video to share.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .alert("Unable to share.", isPresented: Binding(get: {
            shareError != nil
        }, set: { newValue in
            if !newValue { shareError = nil }
        }), actions: {
            Button("OK", role: .cancel) {
                shareError = nil
            }
        }, message: {
            Text(shareError ?? "")
        })
    }

    private var infoOverlay: some View {
        VStack {
            HStack {
                Button {
                    viewModel.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16,weight: .semibold))
                        .padding(.all,12)
                }
                .buttonStyle(.glass)
                .background(.ultraThinMaterial)
                .clipShape(.circle)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(radius: 3)

                Spacer()

                Button {
                    shareMonthlyCompilation()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16,weight: .semibold))
                        .padding(.all,12)
                }
                .buttonStyle(.glass)
                .background(.ultraThinMaterial)
                .clipShape(.circle)
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
                .shadow(radius: 3)
                .disabled(isExportingShare || session.clips.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            Text(viewModel.currentClipLabel)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
        }
    }

    private func shareMonthlyCompilation() {
        guard !isExportingShare, !session.clips.isEmpty else { return }
        isExportingShare = true
        shareError = nil

        Task {
            do {
                let url = try await VideoStorageManager.shared.exportMonthlyCompilation(for: session.clips, monthDate: session.monthDate)
                await MainActor.run {
                    shareURL = url
                    isExportingShare = false
                    showShareSheet = true
                }
            } catch {
                await MainActor.run {
                    shareError = error.localizedDescription
                    isExportingShare = false
                }
            }
        }
    }
    
    // MARK: - Video Display
    
    @ViewBuilder
    private func videoDisplayView(containerSize: CGSize, editorVideoAreaHeight: CGFloat) -> some View {
        // aspectRatio를 확인해서 가로 영상인지 판단
        let isHorizontal = (aspectRatio ?? 1.0) > 1.0
        
        if isHorizontal {
            // 가로 영상 - width는 전체 사이즈, height는 비율에 맞춰 계산
            let aspect = aspectRatio ?? (16.0 / 9.0)
            let videoWidth = containerSize.width
            let videoHeight = videoWidth / aspect
            let videoSize = CGSize(width: videoWidth, height: videoHeight)
            
            ZStack {
                Color.black.ignoresSafeArea()
                
                // 화면 전체 너비를 채우도록 설정 (좌우 여백 없음)
                AspectFitVideoPlayer(
                    player: viewModel.player,
                    frameSize: videoSize,
                    videoAspectRatio: aspect,
                    cornerRadius: horizontalVideoCornerRadius
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        } else {
            // 세로 영상 - 전체 화면
            AspectFillVideoPlayer(player: viewModel.player)
                .ignoresSafeArea()
        }
    }
    
    // MARK: - Editor Video Area Height Calculation
    
    /// 편집 페이지와 동일한 방식으로 사용 가능한 영상 영역 높이 계산
    private func calculateEditorVideoAreaHeight(geometry: GeometryProxy) -> CGFloat {
        // 편집 페이지의 EditorLayoutMetrics와 동일한 계산
        let bottomControlsHeight: CGFloat = 50
        let timelineHeight: CGFloat = 86
        let videoToControlsSpacing: CGFloat = 12
        let contentTopInset: CGFloat = 0
        
        let bottomBarContentHeight = timelineHeight + bottomControlsHeight
        let available = geometry.size.height - contentTopInset - geometry.safeAreaInsets.bottom - bottomBarContentHeight - videoToControlsSpacing
        
        return max(available, 0)
    }
    
    // MARK: - Video Info Loading
    
    private func loadCurrentClipInfo() {
        guard viewModel.clips.indices.contains(viewModel.currentIndex) else {
            return
        }
        
        let currentClip = viewModel.clips[viewModel.currentIndex]
        
        Task {
            do {
                let asset = AVAsset(url: currentClip.videoURL)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = videoTracks.first else {
                    return
                }
                
                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)
                
                // Transform을 적용한 실제 크기 계산
                let renderRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let actualSize = CGSize(width: abs(renderRect.width), height: abs(renderRect.height))
                
                // 크기가 유효한지 확인
                guard actualSize.width > 0 && actualSize.height > 0 else {
                    return
                }
                
                // Composition 내에서의 실제 표시 비율 계산
                // Composition은 항상 1080x1920 (세로)로 만들어지고,
                // 가로 영상은 scale = max(scaleX, scaleY)로 확대되어 세로 프레임을 채움
                let renderSize = CGSize(width: 1080, height: 1920)
                let scaleX = renderSize.width / actualSize.width
                let scaleY = renderSize.height / actualSize.height
                let scale = max(scaleX, scaleY) // aspect fill 방식
                
                // Composition 내에서 실제로 표시되는 크기
                let displayedWidth = actualSize.width * scale
                let displayedHeight = actualSize.height * scale
                
                // Composition의 크기 대비 실제 표시 비율
                // 가로 영상의 경우 composition이 세로이므로, composition의 width를 기준으로 계산
                let compositionAspectRatio = displayedWidth / renderSize.width
                _ = compositionAspectRatio
                
                await MainActor.run {
                    // 원본 영상의 비율 사용 (composition 내에서 어떻게 배치되든 원본 비율이 중요)
                    self.aspectRatio = actualSize.width / actualSize.height
                }
            } catch {
                // 에러 발생 시 무시
            }
        }
    }
    
    // MARK: - Video Display Size Calculation
    
    /// Returns an aspect-fit size that prefers full width for landscape clips
    /// and full height for portrait/square clips, while never exceeding the
    /// provided container. (편집 페이지와 동일한 로직)
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
}

private extension MonthlyPlaybackView {
    @ViewBuilder
    func glassyCircle(iconName: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.08))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.1)
                        .blur(radius: 0.4)
                )
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.05)
                            ], startPoint: .top, endPoint: .bottom)
                        )
                        .padding(1)
                )
                // .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
                .frame(width: 46, height: 46)
            
            Image(systemName: iconName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
