import Foundation

enum MemoAssetSchemeHandler {
    static let scheme = "memodolmaeng-asset"

    static func resolvedFileURL(for requestURL: URL, rootURL: URL) -> URL? {
        guard requestURL.scheme == scheme,
              requestURL.user == nil,
              requestURL.password == nil,
              requestURL.port == nil,
              requestURL.query == nil,
              requestURL.fragment == nil,
              let host = requestURL.host,
              let noteID = UUID(uuidString: host)
        else { return nil }

        let pathComponents = requestURL.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1 else { return nil }
        let fileName = pathComponents[0]
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              fileName == (fileName as NSString).lastPathComponent,
              !fileName.contains("\\")
        else { return nil }

        let resolvedRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = resolvedRoot
            .appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(resolvedRoot.path + "/") else { return nil }
        return candidate
    }
}
