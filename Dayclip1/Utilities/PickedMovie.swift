//
//  PickedMovie.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Picked Movie Transfer Wrapper

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDirectory = FileManager.default.temporaryDirectory
            let targetURL = tempDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: received.file, to: targetURL)
            return PickedMovie(url: targetURL)
        }
    }
}

