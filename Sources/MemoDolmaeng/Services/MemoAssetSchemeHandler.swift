import Foundation
import UniformTypeIdentifiers
import WebKit

final class MemoAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "memodolmaeng-asset"

    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let candidate = Self.resolvedFileURL(for: url, rootURL: rootURL)
        else {
            fail(urlSchemeTask, code: .noPermissionsToReadFile)
            return
        }

        do {
            let data = try Data(contentsOf: candidate)
            let mimeType = UTType(filenameExtension: candidate.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let response = URLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            fail(urlSchemeTask, code: .fileDoesNotExist)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

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

    private func fail(_ task: WKURLSchemeTask, code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }
}
