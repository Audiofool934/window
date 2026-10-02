import Foundation

public enum WindowDefaults {
    /// Toward the equator, where the sun spends the day. In the tropics the sun crosses overhead, so face the sunset.
    public static func facingDegrees(latitude: Double) -> Double {
        if abs(latitude) < 23.44 { return 270 }
        return latitude > 0 ? 180 : 0
    }
}
