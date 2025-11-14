//
//  RotationHelpers.swift
//  Dayclip1
//
//  Created by Ji y LEE on 11/7/25.
//

import Foundation
import CoreGraphics
import UIKit

// MARK: - Rotation Math Helpers

func normalizedQuarterTurns(_ value: Int) -> Int {
    let mod = value % 4
    return mod >= 0 ? mod : mod + 4
}

func rotationTransform(for quarterTurns: Int, size: CGSize) -> CGAffineTransform {
    let turns = normalizedQuarterTurns(quarterTurns)
    switch turns {
    case 0:
        return .identity
    case 1:
        return CGAffineTransform(translationX: size.height, y: 0).rotated(by: .pi / 2)
    case 2:
        return CGAffineTransform(translationX: size.width, y: size.height).rotated(by: .pi)
    case 3:
        return CGAffineTransform(translationX: 0, y: size.width).rotated(by: -.pi / 2)
    default:
        return .identity
    }
}

// MARK: - UIImage Rotation Extension

extension UIImage {
    func rotatedByQuarterTurns(_ turns: Int) -> UIImage {
        let normalized = normalizedQuarterTurns(turns)
        guard normalized != 0 else { return self }

        let angle: CGFloat
        let newSize: CGSize
        switch normalized {
        case 1:
            angle = .pi / 2
            newSize = CGSize(width: size.height, height: size.width)
        case 2:
            angle = .pi
            newSize = size
        case 3:
            angle = -.pi / 2
            newSize = CGSize(width: size.height, height: size.width)
        default:
            angle = 0
            newSize = size
        }

        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return self
        }

        switch normalized {
        case 1:
            context.translateBy(x: newSize.width, y: 0)
        case 2:
            context.translateBy(x: newSize.width, y: newSize.height)
        case 3:
            context.translateBy(x: 0, y: newSize.height)
        default:
            break
        }

        context.rotate(by: angle)
        draw(at: CGPoint(x: 0, y: 0))
        let rotated = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rotated ?? self
    }
}

