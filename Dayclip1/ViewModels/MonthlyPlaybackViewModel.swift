//
//  MonthlyPlaybackViewModel.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import AVFoundation
import SwiftUI
import Combine

// MARK: - Monthly Playback ViewModel

@MainActor
final class MonthlyPlaybackViewModel: ObservableObject {
    @Published var player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = false
        return player
    }()
    @Published var isPlaying = false
    @Published var currentIndex = 0
    @Published var didFinish = false
    @Published var isLoading = true

    let clips: [DayClip]

    nonisolated(unsafe) private var currentItemObserver: NSObjectProtocol?
    nonisolated(unsafe) private var currentItem: AVPlayerItem?
    private var didStart = false
    private var clipTimeRanges: [CMTimeRange] = []
    private var timeObserver: Any?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M월 d일"
        return formatter
    }()

    init(clips: [DayClip]) {
        self.clips = clips
    }

    var hasNext: Bool {
        currentIndex + 1 < clips.count
    }

    var progressLabel: String {
        guard !clips.isEmpty else { return "0/0" }
        return "\(currentIndex + 1)/\(clips.count)"
    }

    var currentClipLabel: String {
        guard clips.indices.contains(currentIndex) else { return "" }
        return Self.dateFormatter.string(from: clips[currentIndex].date)
    }

    func start() {
        guard !clips.isEmpty else {
            didFinish = true
            isLoading = false
            return
        }

        if !didStart {
            didStart = true
            isLoading = true
            Task {
                await loadComposition()
            }
        }
    }

    func stop() {
        player.pause()
        isPlaying = false
        didFinish = false
        removeObserver()
        removeTimeObserver()
    }

    func togglePlayback() {
        guard !didFinish, !isLoading else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func skipForward() {
        guard !didFinish, !isLoading else { return }
        guard clips.indices.contains(currentIndex + 1) else {
            finishPlayback()
            return
        }
        currentIndex += 1
        seekToCurrentClip()
    }

    func restart() {
        guard !clips.isEmpty, !isLoading else { return }
        currentIndex = 0
        didFinish = false
        activatePlaybackAudioSession()
        seekToCurrentClip()
        player.play()
        isPlaying = true
    }

    private func loadComposition() async {
        do {
            let (composition, placements, renderSize, timeRanges) = try await VideoStorageManager.shared.makeMonthlyComposition(for: clips)
            clipTimeRanges = timeRanges
            
            let item = AVPlayerItem(asset: composition)
            
            if let videoComposition = VideoStorageManager.shared.makeVideoComposition(for: composition, placements: placements, renderSize: renderSize) {
                item.videoComposition = videoComposition
            }
            
            await MainActor.run {
                removeObserver()
                removeTimeObserver()
                currentItem = item
                player.replaceCurrentItem(with: item)
                player.isMuted = false
                activatePlaybackAudioSession()
                addObserver(for: item)
                addTimeObserver()
                
                currentIndex = 0
                didFinish = false
                isLoading = false
                player.seek(to: .zero)
                player.play()
                isPlaying = true
            }
        } catch {
            await MainActor.run {
                isLoading = false
                didFinish = true
            }
        }
    }

    private func seekToCurrentClip() {
        guard clips.indices.contains(currentIndex),
              clipTimeRanges.indices.contains(currentIndex) else {
            return
        }
        let timeRange = clipTimeRanges[currentIndex]
        player.seek(to: timeRange.start)
    }

    private func addObserver(for item: AVPlayerItem) {
        currentItemObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.handleCurrentItemEnded()
        }
    }

    private func removeObserver() {
        if let observer = currentItemObserver {
            NotificationCenter.default.removeObserver(observer)
            currentItemObserver = nil
        }
        currentItem = nil
    }
    
    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateCurrentIndex(for: time)
        }
    }
    
    private func removeTimeObserver() {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
    
    private func updateCurrentIndex(for time: CMTime) {
        for (index, timeRange) in clipTimeRanges.enumerated() {
            if time >= timeRange.start && time < timeRange.end {
                if currentIndex != index {
                    currentIndex = index
                }
                break
            }
        }
    }
    
    nonisolated deinit {
        if let observer = currentItemObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleCurrentItemEnded() {
        finishPlayback()
    }

    private func finishPlayback() {
        player.pause()
        isPlaying = false
        didFinish = true
        removeObserver()
        removeTimeObserver()
    }
}

