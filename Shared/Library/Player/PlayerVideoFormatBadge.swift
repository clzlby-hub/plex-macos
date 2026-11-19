import Foundation

enum PlayerVideoFormatBadge: String, Identifiable {
    case hdr10
    case hdr10Plus
    case dolbyVision
    case hlg

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hdr10:
            String(localized: "player.badge.hdr10")
        case .hdr10Plus:
            String(localized: "player.badge.hdr10Plus")
        case .dolbyVision:
            String(localized: "player.badge.dolbyVision")
        case .hlg:
            String(localized: "player.badge.hlg")
        }
    }

    var systemImage: String {
        switch self {
        case .dolbyVision:
            "sparkles"
        case .hdr10, .hdr10Plus, .hlg:
            "sun.max.fill"
        }
    }
}
