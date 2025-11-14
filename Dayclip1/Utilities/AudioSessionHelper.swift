//
//  AudioSessionHelper.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import AVFoundation

// MARK: - Audio Session Activation Helper

func activatePlaybackAudioSession() {
    Task {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            #if DEBUG
            print("Audio session error: \(error)")
            #endif
        }
    }
}

