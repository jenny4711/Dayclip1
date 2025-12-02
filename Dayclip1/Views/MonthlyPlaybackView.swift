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
                
                infoOverlay
                
                if viewModel.isLoading {
                    ProgressView("영상 준비 중...")
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(radius: 8)
                }
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

    private var infoOverlay: some View {
        VStack {
            HStack {
                Button {
                    viewModel.stop()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                 .buttonStyle(.plain)
                
                Spacer()

                Button {
                    shareMonthlyCompilation()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(isExportingShare || session.clips.isEmpty)
                .opacity(isExportingShare || session.clips.isEmpty ? 0.5 : 1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 12)

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
}

