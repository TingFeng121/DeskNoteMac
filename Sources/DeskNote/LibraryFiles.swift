import Foundation

/// Ordinary Markdown stays ordinary: preserve the exact metadata prefix and compare the
/// complete on-disk document before saving. A concurrent edit never gets overwritten.
enum LibraryFiles {
    struct Snapshot {
        var raw: String
        var prefix: String
        var body: String
        init(_ raw: String) {
            self.raw = raw
            prefix = ""
            body = raw
            let bytes = Array(raw.utf8)
            guard bytes.count >= 4, Array(bytes.prefix(3)) == [45, 45, 45],
                  bytes[3] == 10 || (bytes.count >= 5 && bytes[3] == 13 && bytes[4] == 10) else { return }

            var start = bytes[3] == 10 ? 4 : 5
            while start < bytes.count {
                let lineEnd = bytes[start...].firstIndex(of: 10) ?? bytes.count
                let contentEnd = lineEnd > start && bytes[lineEnd - 1] == 13 ? lineEnd - 1 : lineEnd
                if contentEnd - start == 3 && Array(bytes[start..<contentEnd]) == [45, 45, 45] {
                    let end = lineEnd < bytes.count ? lineEnd + 1 : lineEnd
                    prefix = String(decoding: bytes[..<end], as: UTF8.self)
                    body = String(decoding: bytes[end...], as: UTF8.self)
                    return
                }
                guard lineEnd < bytes.count else { break }
                start = lineEnd + 1
            }
        }
    }
    enum Failure: LocalizedError {
        case invalidName, outsideRoot, exists
        var errorDescription: String? {
            switch self {
            case .invalidName: return "名称不能为空，也不能包含 /、\\、冒号或以点开头。"
            case .outsideRoot: return "只能操作当前库内的文件。"
            case .exists: return "这个名称已存在，请换一个名称。"
            }
        }
    }
    enum Saved { case original, conflict(URL) }

    static func validate(_ url: URL, root: URL) throws {
        let path = resolvedPath(url)
        let base = resolvedPath(root)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path != base, path.hasPrefix(prefix),
              !path.dropFirst(prefix.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw Failure.outsideRoot
        }
    }

    /// Resolve existing path components one at a time. Foundation's resolver can leave a
    /// missing leaf under a directory symlink unresolved, which would let a new file escape.
    private static func resolvedPath(_ url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            if FileManager.default.fileExists(atPath: current.path) {
                current = current.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return current.standardizedFileURL.path
    }
    static func named(_ name: String, in folder: URL, directory: Bool) throws -> URL {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains(where: { "/\\:\n\r".contains($0) }) else { throw Failure.invalidName }
        if !directory && !(name as NSString).pathExtension.lowercased().elementsEqual("md") { name += ".md" }
        let url = folder.appendingPathComponent(name, isDirectory: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists }
        return url
    }
    static func create(name: String, folder: URL, directory: Bool, root: URL) throws -> URL {
        let url = try named(name, in: folder, directory: directory)
        try validate(url, root: root)
        if directory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        else { try Data().write(to: url, options: .withoutOverwriting) }
        return url
    }
    static func rename(_ url: URL, to name: String, directory: Bool, root: URL) throws -> URL {
        try validate(url, root: root)
        let target = try named(name, in: url.deletingLastPathComponent(), directory: directory)
        try validate(target, root: root)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
    static func save(body: String, snapshot: Snapshot, url: URL, root: URL) throws -> Saved {
        try validate(url, root: root)
        let raw = snapshot.prefix + body
        // Missing files are conflicts too: do not resurrect an externally removed document.
        let disk = try? String(contentsOf: url, encoding: .utf8)
        if disk == snapshot.raw {
            try raw.write(to: url, atomically: true, encoding: .utf8)
            return .original
        }
        var copy = Vault.conflictURL(url)
        if !FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path) {
            copy = root.appendingPathComponent(copy.lastPathComponent)
        }
        var index = 2
        let first = copy
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = first.deletingPathExtension().appendingPathExtension("\(index).md")
            index += 1
        }
        try Data(raw.utf8).write(to: copy, options: .withoutOverwriting)
        return .conflict(copy)
    }

    struct Inventory {
        var folders: [URL] = []
        var markdown: [URL] = []
    }

    /// One background traversal supplies both the document scanner and its directory tree.
    static func inventory(_ root: URL) -> Inventory {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                            options: .skipsHiddenFiles) else { return Inventory() }
        var result = Inventory()
        for case let url as URL in iterator {
            if url.lastPathComponent == "node_modules" { iterator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values?.isDirectory == true { result.folders.append(url) }
            else if url.pathExtension.lowercased() == "md" { result.markdown.append(url) }
        }
        return result
    }

    static func folders(_ root: URL) -> [URL] {
        inventory(root).folders.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
