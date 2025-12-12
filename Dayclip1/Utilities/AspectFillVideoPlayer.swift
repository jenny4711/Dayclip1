//
//  AspectFillVideoPlayer.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import SwiftUI
import AVKit
import UIKit

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

struct AspectFitVideoPlayer: UIViewRepresentable {
    let player: AVPlayer
    var frameSize: CGSize? = nil
    var videoAspectRatio: CGFloat? = nil // 원본 영상의 aspect ratio
    var cornerRadius: CGFloat = 0 // corner radius

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        view.frameSize = frameSize
        view.videoAspectRatio = videoAspectRatio
        view.cornerRadius = cornerRadius
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.frameSize = frameSize
        view.videoAspectRatio = videoAspectRatio
        view.cornerRadius = cornerRadius
        view.updateLayerFrame()
    }
}

// MARK: - Player Layer View

class PlayerLayerView: UIView {
    var player: AVPlayer? {
        didSet {
            playerLayer.player = player
        }
    }
    
    var frameSize: CGSize? {
        didSet {
            updateLayerFrame()
        }
    }
    
    var videoAspectRatio: CGFloat? {
        didSet {
            updateLayerFrame()
        }
    }
    
    var cornerRadius: CGFloat = 0 {
        didSet {
            updateCornerRadius()
        }
    }
    
    // AVPlayerLayer를 컨테이너 뷰로 감싸기 위해 별도의 layer 사용
    private let playerLayer = AVPlayerLayer()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayer()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        // 컨테이너 뷰의 layer 설정 (corner radius 적용용)
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true  // 항상 true로 설정하여 corner radius가 적용되도록
        layer.backgroundColor = UIColor.black.cgColor
        
        // AVPlayerLayer 설정
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
        
        // AVPlayerLayer를 컨테이너 뷰의 layer에 추가
        layer.addSublayer(playerLayer)
    }
    
    private func updateCornerRadius() {
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true  // 항상 true로 설정
        // corner radius가 변경되면 레이아웃 업데이트
        setNeedsLayout()
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateLayerFrame()
    }
    
    func updateLayerFrame() {
        // bounds가 유효하지 않으면 리턴
        guard bounds.width > 0 && bounds.height > 0 else {
            return
        }
        
        // 컨테이너 뷰의 layer를 bounds로 설정 (corner radius가 적용되도록)
        layer.frame = bounds
        
        // corner radius와 masksToBounds를 다시 설정 (레이아웃 변경 시)
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        
        guard let aspectRatio = videoAspectRatio, aspectRatio > 1.0 else {
            // 세로 영상이면 전체 뷰 크기 사용
            playerLayer.frame = bounds
            playerLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            playerLayer.setAffineTransform(.identity)
            return
        }
        
        // 가로 영상의 경우: 화면 전체 너비를 채우도록 설정
        // Composition이 1080x1920 (세로, 비율 0.5625)이고 가로 영상이 그 안에 배치되어 있습니다.
        // 화면 전체 너비를 채우려면 composition의 비율을 고려해야 합니다.
        
        let screenWidth = bounds.width  // 화면 전체 너비
        let screenHeight = bounds.height
        
        // 안전한 가드: screenHeight가 0이면 기본값 사용
        guard screenHeight > 0 else {
            playerLayer.frame = bounds
            playerLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            playerLayer.videoGravity = .resizeAspect
            return
        }
        
        let screenAspect = screenWidth / screenHeight
        
        // Composition 비율: 1080 / 1920 = 0.5625
        let compositionAspect: CGFloat = 1080.0 / 1920.0
        
        // Composition이 화면에 맞춰질 때의 크기 계산
        // composition이 화면에 aspect fit으로 맞춰지면:
        let compositionFitWidth: CGFloat
        let compositionFitHeight: CGFloat
        
        if screenAspect > compositionAspect {
            // 화면이 composition보다 가로로 길면, composition의 높이가 화면 높이에 맞춰짐
            compositionFitHeight = screenHeight
            compositionFitWidth = compositionFitHeight * compositionAspect
        } else {
            // 화면이 composition보다 세로로 길면, composition의 너비가 화면 너비에 맞춰짐
            compositionFitWidth = screenWidth
            compositionFitHeight = compositionFitWidth / compositionAspect
        }
        
        // 안전한 가드: compositionFitWidth가 0이면 기본값 사용
        guard compositionFitWidth > 0 else {
            playerLayer.frame = bounds
            playerLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            playerLayer.videoGravity = .resizeAspect
            return
        }
        
        // 가로 영상이 화면 전체 너비를 채우려면, composition을 더 크게 확대해야 함
        // composition의 너비가 화면 너비를 채우도록 scale 계산
        let scale = screenWidth / compositionFitWidth
        
        // 확대된 composition 크기
        let scaledCompositionWidth = compositionFitWidth * scale
        let scaledCompositionHeight = compositionFitHeight * scale
        
        // playerLayer를 bounds로 설정하여 corner radius가 제대로 적용되도록
        // videoGravity가 .resizeAspect이므로 비율이 유지되면서 bounds에 맞춰짐
        playerLayer.frame = bounds
        
        // contentsRect를 사용하지 않음 - composition 전체를 표시
        playerLayer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        
        // videoGravity를 resizeAspect로 설정하여 비율 유지
        playerLayer.videoGravity = .resizeAspect
        playerLayer.setAffineTransform(.identity)
    }
}
