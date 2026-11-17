import Foundation

public struct DonutWedge: Equatable, Sendable {
    public let startAngle: Double   // degrees, 0 at top, clockwise
    public let endAngle: Double
    public let fraction: Double

    public init(startAngle: Double, endAngle: Double, fraction: Double) {
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.fraction = fraction
    }
}

public enum DonutGeometry {
    public static func wedges(fractions: [Double]) -> [DonutWedge] {
        let positive = fractions.map { max(0, $0) }
        let sum = positive.reduce(0, +)
        guard sum > 0 else { return [] }

        var result: [DonutWedge] = []
        var cursor = 0.0
        for value in positive where value > 0 {
            let fraction = value / sum
            let start = cursor
            let end = cursor + fraction * 360
            result.append(DonutWedge(startAngle: start, endAngle: end, fraction: fraction))
            cursor = end
        }
        return result
    }
}
