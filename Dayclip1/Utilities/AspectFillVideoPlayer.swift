//
//  AspectFillVideoPlayer.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import AVKit

// MARK: - Aspect Fill Video Player

struct AspectFillVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = videoGravity
        controller.player = player
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.videoGravity = videoGravity
    }
}

// MARK: - Aspect Fit Video Player (for PRD compliance)

struct AspectFitVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.player = player
        controller.view.backgroundColor = .black
        
        // 영상 회전을 올바르게 처리하기 위해 videoGravity 설정
        // AVPlayerViewController는 자동으로 preferredTransform을 처리하지만,
        // 명시적으로 설정하여 회전 문제 방지
        if let playerItem = player.currentItem,
           let videoTrack = playerItem.asset.tracks(withMediaType: .video).first {
            // preferredTransform이 있으면 자동으로 적용됨
            // videoGravity = .resizeAspect는 비율을 유지하면서 회전도 올바르게 처리
        }
        
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        // videoGravity를 항상 .resizeAspect로 유지하여 회전 문제 방지
        controller.videoGravity = .resizeAspect
    }
}

