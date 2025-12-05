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
                Text("No saved videos.")
                    .foregroundStyle(.white)
            } else {
                AspectFillVideoPlayer(player: viewModel.player)
                    .ignoresSafeArea()
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
        .onAppear {
            activatePlaybackAudioSession()
            viewModel.start()
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
//                .opacity(isExportingShare || session.clips.isEmpty ? 0.5 : 1)
                 
               
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

