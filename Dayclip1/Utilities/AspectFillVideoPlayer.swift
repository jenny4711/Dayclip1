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

        // AVPlayerViewController handles preferredTransform automatically.
        // Keeping videoGravity as .resizeAspect ensures correct rotation and aspect.

        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        // Keep videoGravity as .resizeAspect to maintain correct rotation handling
        controller.videoGravity = .resizeAspect
    }
}
