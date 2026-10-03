import Foundation

/// How lived-in the wall is, from the coding agents used on this Mac.
///
/// The opening itself stays one size. Zero use over the last day leaves the wall bare.
/// Use takes hold in a few resting states: moss, then dry stems, then a little growth along the frame.
public enum Opening {
    /// A rolling day. Use from this morning counts less by evening, and after a day it is gone.
    public static let day: TimeInterval = 24 * 60 * 60
    /// Daylight kept on a shut wall, so concrete stays visible when the hole is closed by hand.
    /// The ordinary window is above this and is unchanged. `Room.metal` uses the same floor.
    public static let lightFloor = 0.22

    /// How much of the outdoor light the room still uses. The hole can close further than this.
    public static func lightOpenness(_ scale: Double) -> Double {
        min(max(scale, lightFloor), 1)
    }

    /// 0 bare, 1 moss in the joints, 2 a few dry stems, 3 growth along the frame.
    /// `holding` stays put until the day has clearly left that state.
    public static func state(tokens: Double, holding: Int = 0) -> Int {
        let rise = [0.0, 1.0, 40_000.0, 250_000.0]
        let fall = [0.0, 0.5, 12_000.0, 80_000.0]
        var state = min(max(holding, 0), 3)
        while state < 3, tokens >= rise[state + 1] { state += 1 }
        while state > 0, tokens < fall[state] { state -= 1 }
        return state
    }

    /// 0 is bare and 1 is the fullest growth. The picture eases between the resting states.
    public static func growth(for state: Int) -> Double {
        Double(min(max(state, 0), 3)) / 3
    }

    /// Linear fade across the day. A future timestamp more than an hour off is ignored.
    public static func decayed(_ tokens: Double, age: TimeInterval) -> Double {
        guard tokens > 0, age >= -3600 else { return 0 }
        let age = max(age, 0)
        guard age < day else { return 0 }
        return tokens * (1 - age / day)
    }
}
