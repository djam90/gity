import Foundation

/// A node in a slash-separated ref hierarchy, e.g. `feature/auth/login` becomes
/// `feature` > `auth` > `login`. Folders have no item; leaves have no children.
public struct RefTreeNode<Item: Hashable & Sendable>: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let item: Item?
    /// `nil` for leaves, so SwiftUI's `OutlineGroup` does not draw a disclosure triangle.
    public let children: [RefTreeNode]?

    public var isFolder: Bool { item == nil }

    /// All items in this subtree, depth first.
    public var leaves: [Item] {
        if let item { return [item] }
        return children?.flatMap(\.leaves) ?? []
    }
}

public enum RefTree {
    /// Groups items into folders by the `/`-separated components of `path(item)`.
    /// Folders are listed before leaves, each sorted the way Finder sorts names.
    public static func build<Item: Hashable & Sendable>(
        _ items: [Item],
        idPrefix: String = "",
        path: (Item) -> String
    ) -> [RefTreeNode<Item>] {
        let entries = items.map { item in
            (components: path(item).split(separator: "/").map(String.init)[...], item: item)
        }
        return build(entries, idPrefix: idPrefix)
    }

    private static func build<Item: Hashable & Sendable>(
        _ entries: [(components: ArraySlice<String>, item: Item)],
        idPrefix: String
    ) -> [RefTreeNode<Item>] {
        var leaves: [RefTreeNode<Item>] = []
        var folderOrder: [String] = []
        var folders: [String: [(components: ArraySlice<String>, item: Item)]] = [:]

        for entry in entries {
            guard let first = entry.components.first else { continue }
            if entry.components.count == 1 {
                leaves.append(RefTreeNode(id: idPrefix + first, name: first, item: entry.item, children: nil))
            } else {
                if folders[first] == nil { folderOrder.append(first) }
                folders[first, default: []].append((entry.components.dropFirst(), entry.item))
            }
        }

        let folderNodes = folderOrder.map { name in
            let prefix = idPrefix + name + "/"
            return RefTreeNode<Item>(id: prefix, name: name, item: nil, children: build(folders[name] ?? [], idPrefix: prefix))
        }

        let byName: (RefTreeNode<Item>, RefTreeNode<Item>) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return folderNodes.sorted(by: byName) + leaves.sorted(by: byName)
    }
}
