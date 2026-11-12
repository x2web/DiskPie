import SwiftUI

struct TreeRect {
    let node: FileNode?
    let parent: FileNode
    let count: Int
    let size: Int64
    let rect: CGRect
    let depth: Int
    let hue: Double
}

enum TreemapLayout {
    static let headerHeight: CGFloat = 16

    static func compute(focus: FileNode, in bounds: CGRect, maxDepth: Int = 3) -> [TreeRect] {
        var result: [TreeRect] = []
        guard focus.size > 0, bounds.width > 4, bounds.height > 4 else { return result }

        func layout(_ node: FileNode, in rect: CGRect, depth: Int, hueRange: ClosedRange<Double>?) {
            let minArea: CGFloat = depth == 1 ? 30 : 60
            let scale = Double(rect.width * rect.height) / Double(node.size)
            var items: [(FileNode?, Double, Int64, Int)] = []
            var restSize: Int64 = 0
            var restCount = 0
            for child in node.children where child.size > 0 {
                let area = Double(child.size) * scale
                if area < Double(minArea) || restCount > 0 {
                    restSize += child.size
                    restCount += 1
                } else {
                    items.append((child, area, child.size, 1))
                }
            }
            if restSize > 0 { items.append((nil, Double(restSize) * scale, restSize, restCount)) }

            var cumulative: Int64 = 0
            for (item, frame) in squarify(items, in: rect) {
                let (child, _, size, count) = item
                let fraction = (Double(cumulative) + Double(size) / 2) / Double(node.size)
                cumulative += size
                let hue: Double
                if let hueRange {
                    hue = hueRange.lowerBound + (hueRange.upperBound - hueRange.lowerBound) * fraction
                } else {
                    hue = 0.58 + fraction
                }
                result.append(TreeRect(node: child, parent: node, count: count, size: size, rect: frame, depth: depth, hue: hue))

                guard let child, child.isContainer, depth < maxDepth,
                      frame.width > 60, frame.height > 40 else { continue }
                let inner = CGRect(x: frame.minX + 3, y: frame.minY + headerHeight,
                                   width: frame.width - 6, height: frame.height - headerHeight - 3)
                guard inner.width > 10, inner.height > 10 else { continue }
                let span = Double(size) / Double(node.size) * (hueRange.map { $0.upperBound - $0.lowerBound } ?? 1)
                let centerHue = hue
                layout(child, in: inner, depth: depth + 1, hueRange: (centerHue - span / 2)...(centerHue + span / 2))
            }
        }

        layout(focus, in: bounds, depth: 1, hueRange: nil)
        return result
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk).
    static func squarify<T>(_ items: [(T, Double, Int64, Int)], in rect: CGRect) -> [((T, Double, Int64, Int), CGRect)] {
        var result: [((T, Double, Int64, Int), CGRect)] = []
        var remaining = items[...]
        var r = rect

        func worst(_ row: [Double], side: Double) -> Double {
            let sum = row.reduce(0, +)
            guard sum > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
            let s2 = sum * sum, w2 = side * side
            return max(w2 * mx / s2, s2 / (w2 * mn))
        }

        while !remaining.isEmpty {
            let side = Double(min(r.width, r.height))
            guard side > 0 else { break }
            var row: [(T, Double, Int64, Int)] = []
            var areas: [Double] = []
            while let next = remaining.first {
                let candidate = areas + [next.1]
                if areas.isEmpty || worst(candidate, side: side) <= worst(areas, side: side) {
                    row.append(next)
                    areas = candidate
                    remaining = remaining.dropFirst()
                } else {
                    break
                }
            }
            let rowArea = areas.reduce(0, +)
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            if r.width >= r.height {
                for (item, area) in zip(row, areas) {
                    let h = CGFloat(area) / max(thickness, 0.0001)
                    result.append((item, CGRect(x: r.minX, y: r.minY + offset, width: thickness, height: h)))
                    offset += h
                }
                r = CGRect(x: r.minX + thickness, y: r.minY, width: max(0, r.width - thickness), height: r.height)
            } else {
                for (item, area) in zip(row, areas) {
                    let w = CGFloat(area) / max(thickness, 0.0001)
                    result.append((item, CGRect(x: r.minX + offset, y: r.minY, width: w, height: thickness)))
                    offset += w
                }
                r = CGRect(x: r.minX, y: r.minY + thickness, width: r.width, height: max(0, r.height - thickness))
            }
        }
        return result
    }
}

final class TreemapCache {
    private var key: (ObjectIdentifier, Int, CGFloat, CGFloat)?
    private var value: [TreeRect] = []

    func rects(focus: FileNode, version: Int, bounds: CGRect) -> [TreeRect] {
        let newKey = (ObjectIdentifier(focus), version, bounds.width, bounds.height)
        if let key, key == newKey { return value }
        value = TreemapLayout.compute(focus: focus, in: bounds)
        key = newKey
        return value
    }
}

struct TreemapView: View {
    @Environment(AppModel.self) private var model
    let focus: FileNode
    let version: Int

    @State private var cache = TreemapCache()
    @State private var hoverPoint: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 10, dy: 10)
            let rects = cache.rects(focus: focus, version: version, bounds: bounds)
            let hovered = model.hovered
            let selected = model.selection
            let aggregate = model.hoveredAggregate

            Canvas { ctx, _ in
                for item in rects {
                    let isHovered = (item.node != nil && item.node === hovered)
                        || (item.node == nil && aggregate?.parent === item.parent && aggregate?.count == item.count)
                    let shape = Path(roundedRect: item.rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
                    ctx.fill(shape, with: .color(Palette.color(hue: item.hue, depth: item.depth, node: item.node, highlighted: isHovered)))
                    ctx.stroke(shape, with: .color(Palette.separator), lineWidth: 1)
                    drawLabel(in: &ctx, item)
                }
                if let item = rects.last(where: { $0.node != nil && ($0.node === hovered || $0.node === selected) }) {
                    let shape = Path(roundedRect: item.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3)
                    ctx.stroke(shape, with: .color(item.node === hovered ? .primary : .accentColor), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverPoint = p
                    if let item = hit(p, rects) {
                        if let node = item.node { model.hover(node) }
                        else { model.hover(aggregate: AggregateHover(parent: item.parent, count: item.count, size: item.size)) }
                    } else {
                        model.hover(focus)
                    }
                case .ended:
                    hoverPoint = nil
                    model.hover(nil)
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let item = hit(value.location, rects) else { return }
                if let node = item.node {
                    if node.isContainer { model.enter(node) } else { model.select(node) }
                } else if item.parent !== focus {
                    model.enter(item.parent)
                }
            })
            .contextMenu { NodeMenu(node: model.contextTarget) }
            .overlay(alignment: .topLeading) {
                if let hoverPoint {
                    HoverTooltip(focus: focus)
                        .fixedSize()
                        .offset(x: min(hoverPoint.x + 16, proxy.size.width - 240), y: min(hoverPoint.y + 18, proxy.size.height - 60))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func hit(_ p: CGPoint, _ rects: [TreeRect]) -> TreeRect? {
        rects.last { $0.rect.contains(p) }
    }

    private func drawLabel(in ctx: inout GraphicsContext, _ item: TreeRect) {
        guard item.rect.width > 44, item.rect.height > 15 else { return }
        let title = item.node?.name ?? "\(Fmt.count(item.count)) мелких"
        let hasChildrenDrawn = item.node?.isContainer == true && item.rect.width > 60 && item.rect.height > 40 && item.depth < 3
        let text = ctx.resolve(
            Text(hasChildrenDrawn ? title : "\(title)  \(Fmt.size(item.size))")
                .font(.system(size: 10, weight: hasChildrenDrawn ? .semibold : .regular))
                .foregroundStyle(.black.opacity(0.75))
        )
        let frame = CGRect(x: item.rect.minX + 4, y: item.rect.minY + 2, width: item.rect.width - 8, height: 13)
        ctx.draw(text, in: frame)
    }
}
