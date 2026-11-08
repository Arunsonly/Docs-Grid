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
            case "getPortableDataLocations":
                guard let selected = try selectedFolder(), let root = URL(string: selected["uri"] ?? "") else {
                    throw storageError("Choose a DocsGrid storage folder first.")
                }
                // Match Android's portable root and preserve any legacy folders.
                let docsGrid = try ensureDirectory(parent: root, name: "DocsGrid")
                let documents = try ensureDirectory(parent: docsGrid, name: "Documents")
                let folders = try ensureDirectory(parent: docsGrid, name: "Folders")
                let database = try ensureDirectory(parent: docsGrid, name: "Database")
                let recovery = try ensureDirectory(parent: docsGrid, name: "Recovery")
                result([
                    "databaseUri": database.absoluteString,
                    "recoveryUri": recovery.absoluteString,
                    "libraryUri": folders.absoluteString,
                    "documentsUri": documents.absoluteString
                ])
            case "getSelectedFolder":
                guard let selected = try selectedFolder(), let root = URL(string: selected["uri"] ?? "") else {
                    result(nil)
                    return
                }
                let docsGrid = try ensureDirectory(parent: root, name: "DocsGrid")
                let folders = try ensureDirectory(parent: docsGrid, name: "Folders")
                result(["uri": folders.absoluteString, "name": "DocsGrid/Folders"])
            case "checkStorageAccess":
                result(checkStorageAccess())
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
            case "copyPdfToPath":
                let source = try urlArg(args, "sourceUri")
                let destinationPath = try stringArg(args, "destinationPath")
                let destination = URL(fileURLWithPath: destinationPath)
                try withAllBookmarkAccess {
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    let parent = destination.deletingLastPathComponent()
                    try FileManager.default.createDirectory(
                        at: parent,
                        withIntermediateDirectories: true
                    )
                    // Never truncate or remove an existing destination. Stage in
                    // the same directory, then atomically publish only on success.
                    guard !FileManager.default.fileExists(atPath: destination.path) else {
                        throw storageError("The destination file already exists.")
                    }
                    let temporary = parent.appendingPathComponent(".docsgrid-copy-\\(UUID().uuidString).tmp")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    FileManager.default.createFile(atPath: temporary.path, contents: nil)
                    let input = try FileHandle(forReadingFrom: source)
                    defer { try? input.close() }
                    let output = try FileHandle(forWritingTo: temporary)
                    defer { try? output.close() }
                    while true {
                        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
                        if chunk.isEmpty { break }
                        try output.write(contentsOf: chunk)
                    }
                    try output.synchronize()
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                result(true)
            case "sha256Pdf":
                let url = try urlArg(args, "uri")
                result(try sha256Pdf(url: url))
            case "writeTextFile":
                let parent = try urlArg(args, "parentUri")
                let name = try stringArg(args, "name")
                let contents = try stringArgAllowEmpty(args, "contents")
                result(try writeTextFile(parent: parent, name: name, contents: contents).absoluteString)
            case "readTextFile":
                let url = try urlArg(args, "uri")
                result(try readTextFile(url: url))
            case "listDirectory":
                let url = try urlArg(args, "uri")
                result(try listDirectory(url: url))
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

    private func stringArgAllowEmpty(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else {
            throw storageError("Missing required value: \\(key)")
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

    private func checkStorageAccess() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: currentBookmarkKey) else {
            return ["status": "not_configured", "message": "No external folder has been selected. App-private storage is available."]
        }
        do {
            var stale = false
            let root = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessed = root.startAccessingSecurityScopedResource()
            defer { if accessed { root.stopAccessingSecurityScopedResource() } }
            guard accessed || FileManager.default.fileExists(atPath: root.path) else {
                return ["status": "revoked", "message": "iOS could not reopen the saved Files folder. Select it again; existing PDF records will be preserved."]
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return ["status": "revoked", "message": "The saved Files folder is unavailable. Select the folder again."]
            }
            return ["status": "available", "message": stale ? "Files access is available; the bookmark will be refreshed on use." : "Saved Files folder access is active.", "name": root.lastPathComponent]
        } catch {
            return ["status": "revoked", "message": "The saved Files permission is no longer valid. Select the folder again; existing PDF records will be preserved."]
        }
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

    private func ensureDirectory(parent: URL, name: String) throws -> URL {
        try withAllBookmarkAccess {
            let target = parent.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw storageError("A file blocks the required DocsGrid folder: \(name)")
                }
                return target
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
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

    private func listDirectory(url: URL) throws -> [[String: Any]] {
        try withAllBookmarkAccess {
            let values = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            return try values.map { child in
                let resource = try child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return [
                    "name": child.lastPathComponent,
                    "uri": child.absoluteString,
                    "isDirectory": resource.isDirectory ?? false,
                    "size": resource.fileSize ?? 0
                ]
            }
        }
    }

    private func readTextFile(url: URL) throws -> String {
        try withAllBookmarkAccess {
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func writeTextFile(parent: URL, name: String, contents: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            throw storageError("Invalid metadata filename.")
        }
        return try withAllBookmarkAccess {
            let target = parent.appendingPathComponent(name)
            let temporary = parent.appendingPathComponent(".\(name).tmp-\(UUID().uuidString)")
            let backup = parent.appendingPathComponent(".\(name).previous-\(UUID().uuidString)")
            let data = Data(contents.utf8)
            try data.write(to: temporary, options: .atomic)
            guard try Data(contentsOf: temporary) == data else {
                try? FileManager.default.removeItem(at: temporary)
                throw storageError("Metadata verification failed.")
            }
            var movedOld = false
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.moveItem(at: target, to: backup)
                    movedOld = true
                }
                try FileManager.default.moveItem(at: temporary, to: target)
                if movedOld { try? FileManager.default.removeItem(at: backup) }
                return target
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if movedOld && !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.moveItem(at: backup, to: target)
                }
                throw error
            }
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
