//
//  MonthlyPlaybackView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI

// MARK: - Monthly Playback Screen

struct MonthlyPlaybackView: View {
    let session: MonthlyPlaybackSession
    let onClose: () -> Void

    @StateObject private var viewModel: MonthlyPlaybackViewModel
    @State private var isExportingShare = false
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var shareError: String?

    init(session: MonthlyPlaybackSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _viewModel = StateObject(wrappedValue: MonthlyPlaybackViewModel(clips: session.clips))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.clips.isEmpty {
                Text("저장된 영상이 없습니다.")
                    .foregroundStyle(.white)
            } else {
                AspectFillVideoPlayer(player: viewModel.player)
                    .ignoresSafeArea()
                
                if viewModel.isLoading {
                    ProgressView("영상 준비 중...")
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 8)
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomSection
            }
        }
        .onAppear {
            activatePlaybackAudioSession()
            viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .overlay(alignment: .center) {
            if isExportingShare {
                ProgressView("영상 준비 중...")
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
                Text("공유할 영상이 없습니다.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .alert("공유할 수 없습니다.", isPresented: Binding(get: {
            shareError != nil
        }, set: { newValue in
            if !newValue { shareError = nil }
        }), actions: {
            Button("확인", role: .cancel) {
                shareError = nil
            }
        }, message: {
            Text(shareError ?? "")
        })
    }

    private var topBar: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    viewModel.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }

                Spacer()

                VStack(alignment: .center, spacing: 4) {
                    Text(session.monthTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(viewModel.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                Button {
                    shareMonthlyCompilation()
                } label: {
                    if isExportingShare {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 28, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(.trailing, 4)
                .disabled(isExportingShare || session.clips.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomSection: some View {
        VStack(spacing: 18) {
            if viewModel.didFinish {
                Text("모든 영상을 재생했어요")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    Button {
                        viewModel.restart()
                    } label: {
                        Label("다시 재생", systemImage: "gobackward")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PlayerActionButtonStyle())

                    Button {
                        viewModel.stop()
                        onClose()
                    } label: {
                        Label("닫기", systemImage: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.12)))
                }
            } else {
                Text(viewModel.currentClipLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)

                    Button {
                        viewModel.skipForward()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 36, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.hasNext ? .white : .white.opacity(0.35))
                    .disabled(!viewModel.hasNext)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
        .padding(.top, 24)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
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
}

