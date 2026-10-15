import UIKit

/// Developer-only plan view for checking geometry and collisions. Off by default;
/// gameplay never depends on it. Touches pass straight through to the game.
final class DevMapView: UIView {
    var world: World?
    var playerPosition = Vec2.zero
    var playerHeading = 0.0
    var playerRadius = 0.25

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let world, let ctx = UIGraphicsGetCurrentContext() else { return }
        let rects = world.rooms.map(\.rect)
        let minX = rects.map(\.x0).min()! - 1, maxX = rects.map(\.x1).max()! + 1
        let minY = rects.map(\.y0).min()! - 1, maxY = rects.map(\.y1).max()! + 1
        let inset = bounds.insetBy(dx: 12, dy: 60)
        let scale = min(Double(inset.width) / (maxX - minX), Double(inset.height) / (maxY - minY))
        let originX = Double(inset.minX), bottomY = Double(inset.maxY)
        func pt(_ p: Vec2) -> CGPoint {
            CGPoint(x: CGFloat(originX + (p.x - minX) * scale), y: CGFloat(bottomY - (p.y - minY) * scale))
        }

        ctx.setFillColor(UIColor(white: 0.12, alpha: 1).cgColor)
        for r in rects {
            let a = pt(Vec2(r.x0, r.y1)), b = pt(Vec2(r.x1, r.y0))
            ctx.fill(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        }
        ctx.setLineWidth(2)
        ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1).cgColor)
        for w in world.walls {
            ctx.move(to: pt(w.segment.a))
            ctx.addLine(to: pt(w.segment.b))
        }
        ctx.strokePath()
        ctx.setStrokeColor(UIColor.systemGreen.cgColor)
        ctx.setLineWidth(3)
        for d in world.doorways {
            ctx.move(to: pt(d.segment.a))
            ctx.addLine(to: pt(d.segment.b))
        }
        ctx.strokePath()

        let e = world.definition.exit.rect
        let ea = pt(Vec2(e.x0, e.y1)), eb = pt(Vec2(e.x1, e.y0))
        ctx.setStrokeColor(UIColor.systemPink.cgColor)
        ctx.stroke(CGRect(x: ea.x, y: ea.y, width: eb.x - ea.x, height: eb.y - ea.y))

        let font = UIFont.systemFont(ofSize: 10)
        for s in world.sources {
            let c = pt(s.position)
            ctx.setFillColor(UIColor.systemOrange.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            (s.id as NSString).draw(at: CGPoint(x: c.x + 6, y: c.y - 6),
                                    withAttributes: [.font: font, .foregroundColor: UIColor.systemOrange])
        }

        let p = pt(playerPosition)
        let r = CGFloat(playerRadius * scale)
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        let f = Heading.forward(playerHeading)
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.move(to: p)
        ctx.addLine(to: pt(playerPosition + f * 1.2))
        ctx.strokePath()
    }
}
