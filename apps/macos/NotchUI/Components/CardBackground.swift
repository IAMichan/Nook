import SwiftUI

extension View {
    /// A rounded card behind the content: `fill` inside and a 1 pt `stroke` along the edge, both on the same shape.
    /// Used for field cards (`NookTheme.field` with `NookTheme.line2`) and tinted notices (amber, coral or iris at a low
    /// opacity, with a slightly stronger stroke of the same color). `style` nil keeps SwiftUI's default corner style.
    func cardBackground<Fill: ShapeStyle, Stroke: ShapeStyle>(_ fill: Fill, stroke: Stroke, radius: CGFloat,
                                                              style: RoundedCornerStyle? = nil) -> some View {
        let shape = style.map { RoundedRectangle(cornerRadius: radius, style: $0) } ?? RoundedRectangle(cornerRadius: radius)
        return background(shape.fill(fill)).overlay(shape.stroke(stroke, lineWidth: 1))
    }
}
