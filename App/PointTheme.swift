import SwiftUI

enum PointTheme {
    static let accent = oklch(0.51, 0.12, 70)
    static let route = oklch(0.66, 0.14, 70)
    static let background = Color(uiColor: .systemBackground)

    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> Color {
        let a = chroma * cos(hue * .pi / 180), b = chroma * sin(hue * .pi / 180)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ value: Double) -> Double {
            min(1, max(0, value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055))
        }
        return Color(red: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
