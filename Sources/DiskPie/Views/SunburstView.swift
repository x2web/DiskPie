import SwiftUI

struct SunSegment {
    let node: FileNode?
    let parent: FileNode
    let count: Int
    let size: Int64
    let depth: Int
    let start: Double
    let end: Double
    let hue: Double

    var mid: Double { (start + end) / 2 }
    var span: Double { end - start }
}

enum SunburstLayout {
    static func compute(focus: FileNode, depth: Int, minAngle: Double = 0.012) -> [[SunSegment]] {
        var rings = Array(repeating: [SunSegment](), count: depth)
        guard focus.size > 0 else { return rings }

        // Children inherit the parent hue and drift with their angle, so a branch keeps one color family.
        func place(_ node: FileNode, level: Int, start: Double, end: Double, hue parentHue: Double?) {
            guard level <= depth, node.size > 0 else { return }
            let scale = (end - start) / Double(node.size)
            var angle = start
            var restSize: Int64 = 0
            var restCount = 0
            for child in node.children where child.size > 0 {
                let span = Double(child.size) * scale
                if span < minAngle || restCount > 0 {
                    restSize += child.size
                    restCount += 1
                    continue
                }
                let mid = angle + span / 2
                let hue = parentHue.map { $0 + (mid - (start + end) / 2) / (2 * .pi) * 0.7 } ?? 0.58 + mid / (2 * .pi)
                rings[level - 1].append(SunSegment(node: child, parent: node, count: 1, size: child.size,
                                                   depth: level, start: angle, end: angle + span, hue: hue))
                if child.isContainer { place(child, level: level + 1, start: angle, end: angle + span, hue: hue) }
                angle += span
            }
            if restSize > 0 {
                let span = Double(restSize) * scale
                if span >= minAngle * 0.25 {
                    rings[level - 1].append(SunSegment(node: nil, parent: node, count: restCount, size: restSize,
                                                       depth: level, start: angle, end: min(end, angle + span), hue: 0))
                }
            }
        }

        place(focus, level: 1, start: 0, end: 2 * .pi, hue: nil)
        return rings
    }
}

struct SunGeometry {
    static let startAngle = -Double.pi / 2

    let center: CGPoint
    let radius: CGFloat
    let inner: CGFloat
    let ring: CGFloat

    init(size: CGSize, depth: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(60, min(size.width, size.height) / 2 - 18)
        inner = radius * 0.27
        ring = (radius - inner) / CGFloat(max(1, depth))
    }

    func radii(_ depth: Int) -> (CGFloat, CGFloat) {
        (inner + CGFloat(depth - 1) * ring, inner + CGFloat(depth) * ring)
    }

    func point(angle: Double, radius r: CGFloat) -> CGPoint {
        let a = angle + Self.startAngle
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }

    func path(for s: SunSegment) -> Path {
        let (r0, r1) = radii(s.depth)
        var path = Path()
        if s.span >= 2 * .pi - 1e-6 {
            path.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: r1 * 2, height: r1 * 2))
            path.addEllipse(in: CGRect(x: center.x - r0, y: center.y - r0, width: r0 * 2, height: r0 * 2))
            return path
        }
        let a0 = Angle.radians(s.start + Self.startAngle)
        let a1 = Angle.radians(s.end + Self.startAngle)
        path.addArc(center: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }
}

enum SunHit {
    case center
    case segment(SunSegment)
    case none
}

final class SunburstCache {
    private var key: (ObjectIdentifier, Int, Int)?
    private var value: [[SunSegment]] = []

    func rings(focus: FileNode, version: Int, depth: Int) -> [[SunSegment]] {
        let newKey = (ObjectIdentifier(focus), version, depth)
        if let key, key == newKey { return value }
        value = SunburstLayout.compute(focus: focus, depth: depth)
        key = newKey
        return value
    }
}

struct SunburstView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    let version: Int
    let depth: Int

    @State private var cache = SunburstCache()
    @State private var hoverPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let geometry = SunGeometry(size: proxy.size, depth: depth)
            let rings = cache.rings(focus: focus, version: version, depth: depth)
            let hovered = model.hovered
            let selected = model.selection
            let aggregate = model.hoveredAggregate
            let centerHovered = hoverPoint.map { hypot($0.x - geometry.center.x, $0.y - geometry.center.y) <= geometry.inner } ?? false

            Canvas { ctx, _ in
                draw(in: &ctx, geometry: geometry, rings: rings, hovered: hovered, selected: selected,
                     aggregate: aggregate, centerHovered: centerHovered)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverPoint = point
                    updateHover(hitTest(point, geometry: geometry, rings: rings))
                case .ended:
                    hoverPoint = nil
                    model.hover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                click(hitTest(value.location, geometry: geometry, rings: rings))
            })
            .contextMenu { NodeMenu(node: model.contextTarget) }
            .overlay(alignment: .topLeading) {
                if let hoverPoint, !centerHovered {
                    HoverTooltip(focus: focus)
                        .fixedSize()
                        .offset(x: min(hoverPoint.x + 16, proxy.size.width - 240), y: hoverPoint.y + 18)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Interaction

    private func hitTest(_ p: CGPoint, geometry g: SunGeometry, rings: [[SunSegment]]) -> SunHit {
        let dx = p.x - g.center.x, dy = p.y - g.center.y
        let r = hypot(dx, dy)
        if r <= g.inner { return .center }
        guard r <= g.radius else { return .none }
        let level = Int((r - g.inner) / g.ring)
        guard level >= 0, level < rings.count else { return .none }
        var angle = atan2(Double(dy), Double(dx)) - SunGeometry.startAngle
        if angle < 0 { angle += 2 * .pi }
        if angle >= 2 * .pi { angle -= 2 * .pi }
        let ring = rings[level]
        var lo = 0, hi = ring.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = ring[mid]
            if angle < s.start { hi = mid - 1 }
            else if angle >= s.end { lo = mid + 1 }
            else { return .segment(s) }
        }
        return .none
    }

    private func updateHover(_ hit: SunHit) {
        switch hit {
        case .center: model.hover(focus)
        case .segment(let s):
            if let node = s.node { model.hover(node) }
            else { model.hover(aggregate: AggregateHover(parent: s.parent, count: s.count, size: s.size)) }
        case .none: model.hover(nil)
        }
    }

    private func click(_ hit: SunHit) {
        switch hit {
        case .center: model.goUp()
        case .segment(let s):
            if let node = s.node {
                if node.isContainer && node.size > 0 { model.enter(node) } else { model.select(node) }
            } else if s.parent !== focus {
                model.enter(s.parent)
            }
        case .none: model.select(nil)
        }
    }

    // MARK: Drawing

    private func draw(in ctx: inout GraphicsContext, geometry g: SunGeometry, rings: [[SunSegment]],
                      hovered: FileNode?, selected: FileNode?, aggregate: AggregateHover?, centerHovered: Bool) {
        let separator = Palette.separator
        var highlight: (Path, Bool)?

        for ring in rings {
            for s in ring {
                let path = g.path(for: s)
                let isHovered = (s.node != nil && s.node === hovered)
                    || (s.node == nil && aggregate?.parent === s.parent && aggregate?.count == s.count)
                let color = Palette.color(hue: s.hue, depth: s.depth, node: s.node, highlighted: isHovered)
                ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
                ctx.stroke(path, with: .color(separator), lineWidth: s.span * Double(g.radius) > 4 ? 1 : 0.5)
                if isHovered { highlight = (path, false) }
                if s.node != nil && s.node === selected { highlight = highlight ?? (path, true) }
            }
        }
        if let (path, isSelection) = highlight {
            ctx.stroke(path, with: .color(isSelection ? .accentColor : .primary.opacity(0.85)), lineWidth: 2)
        }

        for ring in rings { drawLabels(in: &ctx, geometry: g, ring: ring) }
        drawCenter(in: &ctx, geometry: g, highlighted: centerHovered)
    }

    private func drawLabels(in ctx: inout GraphicsContext, geometry g: SunGeometry, ring: [SunSegment]) {
        guard let depth = ring.first?.depth else { return }
        let (r0, r1) = g.radii(depth)
        let mid = (r0 + r1) / 2
        for s in ring {
            guard let node = s.node else { continue }
            let arc = s.span * Double(mid)
            guard arc > 46 else { continue }
            let text = ctx.resolve(Text(node.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.black.opacity(0.72)))
            let size = text.measure(in: CGSize(width: 400, height: 40))
            guard size.width < min(arc * 0.85, Double(g.ring) * 1.9) else { continue }
            ctx.draw(text, at: g.point(angle: s.mid, radius: mid))
        }
    }

    private func drawCenter(in ctx: inout GraphicsContext, geometry g: SunGeometry, highlighted: Bool) {
        let r = g.inner - 3
        let circle = Path(ellipseIn: CGRect(x: g.center.x - r, y: g.center.y - r, width: r * 2, height: r * 2))
        ctx.fill(circle, with: .color(Color(nsColor: .controlBackgroundColor).opacity(highlighted ? 0.75 : 1)))
        ctx.stroke(circle, with: .color(.secondary.opacity(highlighted ? 0.8 : 0.35)), lineWidth: highlighted ? 2 : 1)

        let name = ctx.resolve(Text(focus.displayName).font(.system(size: max(10, r * 0.13), weight: .medium)).foregroundStyle(.secondary))
        let size = ctx.resolve(Text(Fmt.size(focus.size)).font(.system(size: max(14, r * 0.28), weight: .bold, design: .rounded)))
        let files = ctx.resolve(Text(Fmt.files(focus.fileCount)).font(.system(size: max(9, r * 0.1))).foregroundStyle(.secondary))
        let width = CGSize(width: r * 1.7, height: 100)
        let nameSize = name.measure(in: width)
        if nameSize.width <= r * 1.7 {
            ctx.draw(name, at: CGPoint(x: g.center.x, y: g.center.y - r * 0.36))
        }
        ctx.draw(size, at: g.center)
        ctx.draw(files, at: CGPoint(x: g.center.x, y: g.center.y + r * 0.34))
        if focus.parent == nil, let space = model.volumeSpace {
            let free = ctx.resolve(Text("свободно \(Fmt.size(space.available))")
                .font(.system(size: max(9, r * 0.1), weight: .medium)).foregroundStyle(.green))
            ctx.draw(free, at: CGPoint(x: g.center.x, y: g.center.y + r * 0.52))
        }
        if highlighted, focus.parent != nil {
            let up = ctx.resolve(Text(Image(systemName: "arrow.up")).font(.system(size: max(10, r * 0.14), weight: .bold)).foregroundStyle(.secondary))
            ctx.draw(up, at: CGPoint(x: g.center.x, y: g.center.y - r * 0.66))
        }
    }
}

struct HoverTooltip: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode

    var body: some View {
        Group {
            if let node = model.hovered {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(Fmt.size(node.size)) · \(Fmt.percent(node.size, of: focus.size))")
                        .font(.caption).foregroundStyle(.secondary)
                    if node.isContainer {
                        Text(Fmt.files(node.fileCount)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let aggregate = model.hoveredAggregate {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Мелкие объекты: \(Fmt.count(aggregate.count))").font(.callout.weight(.semibold))
                    Text("\(Fmt.size(aggregate.size)) · \(Fmt.percent(aggregate.size, of: focus.size))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .opacity(model.hovered == nil && model.hoveredAggregate == nil ? 0 : 1)
    }
}
