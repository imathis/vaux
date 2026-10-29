import Foundation

/// A line in the Effects list: an effect, a group's name over its effects,
/// or where a group ends: an unseen line under its last effect, or, empty,
/// a place to drop the first. Dropped above its end, an effect's in the
/// group; below, it isn't.
enum EffectListRow: Identifiable {
    case effect(Effect)
    case group(EffectGroup)
    case end(EffectGroup, empty: Bool)

    var id: String {
        switch self {
        case .effect(let effect): "effect-\(effect.id)"
        case .group(let group): "group-\(group.id)"
        case .end(let group, _): "end-\(group.id)"
        }
    }

    /// Its height in the list, its insets in.
    var height: CGFloat {
        if case .end(_, let empty) = self, !empty { 1 } else { 36 }
    }
}

extension EffectListRow {
    /// Dropped. An effect goes in the group it lands inside, or none. A
    /// group's name takes the group and its effects along, between other
    /// things, never into another group. A group's end stays put.
    static func moved(_ rows: [Self], _ offsets: IndexSet, to destination: Int) -> [Self] {
        let dragged = offsets.map { rows[$0] }
        if let group = dragged.lazy.compactMap({ if case .group(let group) = $0 { group } else { nil } }).first {
            return moving(group, in: rows, to: destination)
        }
        let effects = IndexSet(offsets.filter { if case .effect = rows[$0] { true } else { false } })
        var moved = rows
        moved.move(fromOffsets: effects, toOffset: destination)
        return moved
    }

    /// A group, its name to its end, moved to `destination`, or, if that's
    /// inside another group, to just past it.
    private static func moving(_ group: EffectGroup, in rows: [Self], to destination: Int) -> [Self] {
        guard let start = rows.firstIndex(where: { $0.id == "group-\(group.id)" }),
              let end = rows.firstIndex(where: { $0.id == "end-\(group.id)" }),
              destination < start || destination > end + 1
        else { return rows }
        let block = Array(rows[start...end])
        var rest = rows
        rest.removeSubrange(start...end)
        var at = destination > end ? destination - block.count : destination
        // The group, if any, open where it would land.
        var inside = false
        for row in rest[..<at] {
            switch row {
            case .group: inside = true
            case .end: inside = false
            case .effect: break
            }
        }
        if inside, let close = rest[at...].firstIndex(where: { if case .end = $0 { true } else { false } }) { at = close + 1 }
        rest.insert(contentsOf: block, at: at)
        return rest
    }

    /// The list as it stands: effects in order, each in the group it's
    /// inside; groups in order; and the outline of effects in no group and
    /// groups.
    static func arrangement(of rows: [Self]) -> (effects: [Effect], groups: [EffectGroup], outline: [UUID]) {
        var group: UUID?
        var effects: [Effect] = []
        var groups: [EffectGroup] = []
        var outline: [UUID] = []
        for row in rows {
            switch row {
            case .group(let header):
                group = header.id
                groups.append(header)
                outline.append(header.id)
            case .end:
                group = nil
            case .effect(var effect):
                effect.group = group
                effects.append(effect)
                if group == nil { outline.append(effect.id) }
            }
        }
        return (effects, groups, outline)
    }
}
