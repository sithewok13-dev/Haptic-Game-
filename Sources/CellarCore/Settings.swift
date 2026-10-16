import Foundation

public struct GameSettings: Codable, Equatable {
    public var haptics = true
    /// Soft "presence" sound from walls close on the left, right and ahead.
    public var wallSense = true
    /// Degrees turned by one swipe: 45 (eight directions) or 90 (wall directions only).
    public var turnStep = 45
    /// Speak the new facing ("east") after each turn.
    public var speakDirection = true
    /// Speak a room's short name when entering it.
    public var announceRooms = true
    public var developerMap = false
    /// Set once the practice has been completed or skipped.
    public var practiceDone = false

    public init() {}

    /// Degrees per point for the fine `.turn` gesture (used by the autopilot and tests).
    public static let degreesPerPoint = 0.4
}
