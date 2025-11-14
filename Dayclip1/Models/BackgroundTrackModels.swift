//
//  BackgroundTrackModels.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation

// MARK: - Background Track Options

struct BackgroundTrackOption: Identifiable, Hashable {
    enum Source: Hashable {
        case bundled(resource: String, ext: String)
        case file(URL)
    }

    let id: UUID
    let displayName: String
    let source: Source
    let defaultVolume: Double

    init(id: UUID = UUID(), displayName: String, source: Source, defaultVolume: Double) {
        self.id = id
        self.displayName = displayName
        self.source = source
        self.defaultVolume = defaultVolume
    }

    func resolvedURL() -> URL? {
        switch source {
        case .bundled(let resource, let ext):
            return Bundle.main.url(forResource: resource, withExtension: ext)
        case .file(let url):
            return url
        }
    }

    static let builtInOptions: [BackgroundTrackOption] = [
        BackgroundTrackOption(displayName: "Ambient Sunset", source: .bundled(resource: "AmbientSunset", ext: "mp3"), defaultVolume: 0.6),
        BackgroundTrackOption(displayName: "Gentle Wave", source: .bundled(resource: "GentleWave", ext: "mp3"), defaultVolume: 0.6),
        BackgroundTrackOption(displayName: "Lo-Fi Breeze", source: .bundled(resource: "LoFiBreeze", ext: "mp3"), defaultVolume: 0.55)
    ]
}

// MARK: - Background Track Selection

struct BackgroundTrackSelection {
    let option: BackgroundTrackOption
    let volume: Float
}

