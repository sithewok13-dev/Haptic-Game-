import Foundation

// Content layer: the plain data that describes a world. Rooms, openings and
// sound sources live in a JSON file (Content/basement.json) so the layout or
// soundscape can be changed without touching simulation code.

public enum Surface: String, Codable, CaseIterable {
    case wetConcrete
    case dryConcrete
    case woodBoards
    case metalGrate
    case grit
    case stoneStairs
    case outside

    /// Words used by the orientation aid.
    public var spokenName: String {
        switch self {
        case .wetConcrete: return "wet concrete"
        case .dryConcrete: return "dry concrete"
        case .woodBoards: return "wooden boards"
        case .metalGrate: return "metal grating"
        case .grit: return "gritty concrete"
        case .stoneStairs: return "stone steps"
        case .outside: return "open ground"
        }
    }
}

/// Room acoustic character. The audio layer maps each style to a reverb setting.
public enum Acoustics: String, Codable, CaseIterable {
    case smallRoom
    case mediumRoom
    case largeRoom
    case corridor
    case stairwell
}

public struct SurfaceZone: Codable, Equatable {
    public var rect: Rect
    public var surface: Surface
    /// Stairs slow the player and shorten the stride.
    public var stairs: Bool?
}

public struct RoomDefinition: Codable, Equatable {
    public var id: String
    /// Spoken by the orientation aid; describes what the player can sense, never the route.
    public var description: String
    public var rect: Rect
    public var surface: Surface
    public var acoustics: Acoustics
    public var zones: [SurfaceZone]?
}

public struct DoorwayDefinition: Codable, Equatable {
    public var id: String
    /// Exactly two room ids.
    public var rooms: [String]
    /// The opening's two jambs; must lie along a shared edge of both rooms.
    public var a: Vec2
    public var b: Vec2
}

public struct SoundSourceDefinition: Codable, Equatable {
    public var id: String
    /// Sound asset name (procedural id or bundled file name without extension).
    public var sound: String
    public var position: Vec2
    /// Linear gain at or inside the reference distance.
    public var level: Double
    public var referenceDistance: Double
    /// 0...1, how much of this source feeds the room reverb.
    public var reverbBlend: Double
    /// If set, the orientation aid may mention this source when in the same room.
    public var landmark: String?
}

public struct StartDefinition: Codable, Equatable {
    public var position: Vec2
    public var headingDegrees: Double
}

public struct ExitDefinition: Codable, Equatable {
    public var room: String
    public var rect: Rect
}

public struct WorldDefinition: Codable, Equatable {
    public var name: String
    public var version: Int
    public var playerRadius: Double
    public var rooms: [RoomDefinition]
    public var doorways: [DoorwayDefinition]
    public var sources: [SoundSourceDefinition]
    public var start: StartDefinition
    public var exit: ExitDefinition

    public static func load(from data: Data) throws -> WorldDefinition {
        try JSONDecoder().decode(WorldDefinition.self, from: data)
    }

    public static func load(contentsOf url: URL) throws -> WorldDefinition {
        try load(from: Data(contentsOf: url))
    }
}
