import Foundation

struct RAMAdvisor: Sendable {
    static func detectPhysicalRAMGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    static func recommendedProfile(forRAMGB ramGB: Double) -> WhisperProfile {
        switch ramGB {
        case ..<12:
            return .light
        case ..<24:
            return .medium
        default:
            return .large
        }
    }
}
