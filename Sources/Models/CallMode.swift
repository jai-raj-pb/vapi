import Foundation

public enum CallMode {
    case audio
    case video
    
    var cameraEnabled: Bool {
        switch self {
        case .audio: return false
        case .video: return true
        }
    }
    
    var microphoneEnabled: Bool {
        return true
    }
}

