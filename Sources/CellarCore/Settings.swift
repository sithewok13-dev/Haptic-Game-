import Foundation

public enum TurnSpeed: String, Codable, CaseIterable {
    case slow, normal, fast

    /// Degrees of turn per point of horizontal drag.
    public var degreesPerPoint: Double {
        switch self {
        case .slow: return 0.28
        case .normal: return 0.4
        case .fast: return 0.6
        }
    }
}

public struct GameSettings: Codable, Equatable {
    public var haptics = true
    /// Soft "presence" sound from walls close on the left, right and ahead.
    public var wallSense = true
    public var turnSpeed = TurnSpeed.normal
    public var developerMap = false
    /// Set once the practice has been completed or skipped.
    public var practiceDone = false

    public init() {}
}
