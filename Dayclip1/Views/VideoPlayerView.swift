//
//  VideoPlayerView.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import AVFoundation

// MARK: - Daily Clip Player Screen

struct VideoPlayerView: View {
    let clip: DayClip
    let onClose: () -> Void
    let onReplace: () -> Void
    let onDelete: () -> Void
    let onReedit: () -> Void
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?

    init(clip: DayClip, onClose: @escaping () -> Void, onReplace: @escaping () -> Void, onDelete: @escaping () -> Void, onReedit: @escaping () -> Void) {
        self.clip = clip
        self.onClose = onClose
        self.onReplace = onReplace
        self.onDelete = onDelete
        self.onReedit = onReedit
        _player = State(initialValue: AVPlayer(url: clip.videoURL))
    }

    var body: some View {
        GeometryReader { proxy in
            let safeAreaInsets = proxy.safeAreaInsets

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                AspectFillVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onAppear {
                        activatePlaybackAudioSession()
                        player.isMuted = false
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }

                VStack(spacing: 12) {
                    HStack {
                        Button {
                            dismiss()
                            onClose()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        

                        Spacer()

                        Button {
                            shareURL = clip.videoURL
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(radius: 4)
                        }
                        .padding(.trailing, 4)
                    }
//                    .padding(.top, safeAreaInsets.top + 6)
                    .padding(.horizontal, 20)

                    Spacer()

                    VStack(spacing: 12) {
                        Button {
                            dismiss()
                            onReedit()
                        } label: {
                            Label("재편집", systemImage: "scissors")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
//                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle(tint: Color.white.opacity(0.18)))

                        Button {
                            dismiss()
                            onReplace()
                        } label: {
                            Label("새 영상 선택", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
//                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle())

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("삭제", systemImage: "trash")
                                .font(.headline.weight(.semibold))
                                .frame(maxWidth: .infinity)
//                                .padding(.vertical, 14)
                        }
                        .buttonStyle(PlayerActionButtonStyle(tint: Color.red.opacity(0.85)))
                        .confirmationDialog("Delete this clip?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                dismiss()
                                onDelete()
                            }
                            Button("Cancel", role: .cancel) {
                                showDeleteConfirmation = false
                            }
                        } message: {
                            Text("영상을 삭제하면 복구할 수 없습니다.")
                        }
                    }
                    .padding(.horizontal, 24)
//                    .padding(.bottom, max(safeAreaInsets.bottom + 24, 32))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showShareSheet, onDismiss: { shareURL = nil }) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            } else {
                Text("공유할 영상이 없습니다.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

