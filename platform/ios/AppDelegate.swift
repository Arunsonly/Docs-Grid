import UIKit
import Flutter
import UniformTypeIdentifiers
import CryptoKit

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate, UIDocumentInteractionControllerDelegate {
    private let channelName = "docsgrid/storage"
    private let currentBookmarkKey = "docsgrid_storage_bookmark"
    private let bookmarkListKey = "docsgrid_storage_bookmarks"
    private var pendingFolderResult: FlutterResult?
    private var documentController: UIDocumentInteractionController?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call, result: result)
            }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "chooseFolder":
                guard pendingFolderResult == nil else {
                    result(FlutterError(code: "BUSY", message: "Folder picker is already open.", details: nil))
                    return
                }
                pendingFolderResult = result
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                picker.delegate = self
                picker.allowsMultipleSelection = false
                picker.modalPresentationStyle = .formSheet
                window?.rootViewController?.present(picker, animated: true)
            case "getSelectedFolder":
                result(try selectedFolder())
            case "savePdf":
                let parent = try urlArg(args, "treeUri")
                guard let typed = args["bytes"] as? FlutterStandardTypedData else {
                    throw storageError("PDF bytes were not supplied.")
                }
                let name = try stringArg(args, "name")
                result(try savePdf(parent: parent, name: name, data: typed.data).absoluteString)
            case "createDirectory":
                let parent = try urlArg(args, "parentUri")
                let name = try stringArg(args, "name")
                result(try createDirectory(parent: parent, name: name).absoluteString)
            case "copyPdf":
                let source = try urlArg(args, "sourceUri")
                let parent = try urlArg(args, "parentUri")
                let name = try stringArg(args, "name")
                result(try copyPdf(source: source, parent: parent, name: name).absoluteString)
            case "sha256Pdf":
                let url = try urlArg(args, "uri")
                result(try sha256Pdf(url: url))
            case "readPdf":
                let url = try urlArg(args, "uri")
                result(try readPdf(url: url))
            case "findChildUri":
                let parent = try urlArg(args, "parentUri")
                let name = try stringArg(args, "name")
                result(try findChild(parent: parent, name: name).absoluteString)
            case "renamePdf":
                let url = try urlArg(args, "uri")
                let name = try stringArg(args, "name")
                result(try renameItem(url: url, name: name).absoluteString)
            case "deletePdf":
                let url = try urlArg(args, "uri")
                try deleteItem(url: url)
                result(true)
            case "openPdf":
                let url = try urlArg(args, "uri")
                DispatchQueue.main.async {
                    let controller = UIDocumentInteractionController(url: url)
                    controller.delegate = self
                    self.documentController = controller
                    if let view = self.window?.rootViewController?.view {
                        if !controller.presentPreview(animated: true) {
                            controller.presentOptionsMenu(from: view.bounds, in: view, animated: true)
                        }
                    }
                }
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        } catch {
            result(FlutterError(code: "STORAGE_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func stringArg(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String, !value.isEmpty else {
            throw storageError("Missing required value: \(key)")
        }
        return value
    }

    private func urlArg(_ args: [String: Any], _ key: String) throws -> URL {
        let value = try stringArg(args, key)
        guard let url = URL(string: value), url.isFileURL else {
            throw storageError("Invalid file location.")
        }
        return url
    }

    private func storageError(_ message: String) -> NSError {
        NSError(domain: "DocsGridStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func bookmarkDataList() -> [Data] {
        var values = UserDefaults.standard.array(forKey: bookmarkListKey) as? [Data] ?? []
        if let current = UserDefaults.standard.data(forKey: currentBookmarkKey), !values.contains(current) {
            values.append(current)
        }
        return values
    }

    private func resolvedBookmarks() -> [URL] {
        bookmarkDataList().compactMap { data in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }

    private func withAllBookmarkAccess<T>(_ work: () throws -> T) throws -> T {
        let roots = resolvedBookmarks()
        var started: [URL] = []
        for root in roots {
            if root.startAccessingSecurityScopedResource() {
                started.append(root)
            }
        }
        defer { started.forEach { $0.stopAccessingSecurityScopedResource() } }
        return try work()
    }

    private func selectedFolder() throws -> [String: String]? {
        guard let data = UserDefaults.standard.data(forKey: currentBookmarkKey) else { return nil }
        var stale = false
        let root = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let refreshed = try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(refreshed, forKey: currentBookmarkKey)
            var bookmarks = bookmarkDataList()
            if let index = bookmarks.firstIndex(of: data) {
                bookmarks[index] = refreshed
            } else {
                bookmarks.append(refreshed)
            }
            UserDefaults.standard.set(bookmarks, forKey: bookmarkListKey)
        }
        return ["uri": root.absoluteString, "name": root.lastPathComponent]
    }

    private func uniqueURL(parent: URL, requestedName: String) -> URL {
        let base = (requestedName as NSString).deletingPathExtension
        let ext = (requestedName as NSString).pathExtension
        var candidate = parent.appendingPathComponent(requestedName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = parent.appendingPathComponent(next)
            suffix += 1
        }
        return candidate
    }

    private func savePdf(parent: URL, name: String, data: Data) throws -> URL {
        try withAllBookmarkAccess {
            let target = uniqueURL(parent: parent, requestedName: name)
            try data.write(to: target, options: .atomic)
            let saved = try Data(contentsOf: target)
            guard SHA256.hash(data: data).elementsEqual(SHA256.hash(data: saved)) else {
                try? FileManager.default.removeItem(at: target)
                throw storageError("Saved PDF verification failed.")
            }
            return target
        }
    }

    private func createDirectory(parent: URL, name: String) throws -> URL {
        try withAllBookmarkAccess {
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw storageError("A file with this folder name already exists.")
                }
                return target
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        }
    }

    private func copyPdf(source: URL, parent: URL, name: String) throws -> URL {
        try withAllBookmarkAccess {
            let target = uniqueURL(parent: parent, requestedName: name)
            try FileManager.default.copyItem(at: source, to: target)
            let originalHash = try sha256Pdf(url: source)
            let copiedHash = try sha256Pdf(url: target)
            guard originalHash == copiedHash else {
                try? FileManager.default.removeItem(at: target)
                throw storageError("PDF verification failed; original file was kept.")
            }
            return target
        }
    }

    private func sha256Pdf(url: URL) throws -> String {
        try withAllBookmarkAccess {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private func readPdf(url: URL) throws -> FlutterStandardTypedData {
        try withAllBookmarkAccess {
            return FlutterStandardTypedData(bytes: try Data(contentsOf: url))
        }
    }

    private func findChild(parent: URL, name: String) throws -> URL {
        try withAllBookmarkAccess {
            let children = try FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            guard let match = children.first(where: { $0.lastPathComponent == name }) else {
                throw storageError("Could not find '\(name)' inside the selected folder.")
            }
            return match
        }
    }

    private func renameItem(url: URL, name: String) throws -> URL {
        try withAllBookmarkAccess {
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            if target != url && FileManager.default.fileExists(atPath: target.path) {
                throw storageError("A file or folder with this name already exists.")
            }
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    private func deleteItem(url: URL) throws {
        try withAllBookmarkAccess {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let callback = pendingFolderResult else { return }
        pendingFolderResult = nil
        do {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = bookmarkDataList()
            if !bookmarks.contains(data) { bookmarks.append(data) }
            UserDefaults.standard.set(bookmarks, forKey: bookmarkListKey)
            UserDefaults.standard.set(data, forKey: currentBookmarkKey)
            callback(["uri": url.absoluteString, "name": url.lastPathComponent])
        } catch {
            callback(FlutterError(code: "PERMISSION", message: error.localizedDescription, details: nil))
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let callback = pendingFolderResult
        pendingFolderResult = nil
        callback?(nil)
    }

    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return window?.rootViewController ?? UIViewController()
    }
}
