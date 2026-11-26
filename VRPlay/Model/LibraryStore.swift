import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

struct VideoItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }
    var isRemote: Bool { !url.isFileURL }
    var title: String {
        if url.isFileURL { return url.deletingPathExtension().lastPathComponent }
        let last = url.lastPathComponent
        return last.isEmpty ? (url.host ?? url.absoluteString) : last
    }
    var fileSizeText: String? {
        guard url.isFileURL,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 从相册选视频时用的可传输类型：直接拷贝到 Documents
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = LibraryStore.uniqueDestination(for: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var local: [VideoItem] = []
    @Published private(set) var remote: [VideoItem] = []
    @Published var isImporting = false
    @Published var errorMessage: String?

    /// AVPlayer 原生支持的容器
    static let supportedExtensions: Set<String> = ["mp4", "m4v", "mov"]
    private let remoteKey = "vr.remoteURLs"

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.documentsURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        local = files
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { VideoItem(url: $0) }

        let strings = UserDefaults.standard.stringArray(forKey: remoteKey) ?? []
        remote = strings.compactMap { URL(string: $0) }.map { VideoItem(url: $0) }
    }

    static func uniqueDestination(for name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = documentsURL.appendingPathComponent(name)
        var i = 1
        while fm.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = documentsURL.appendingPathComponent(newName)
            i += 1
        }
        return candidate
    }

    func importFiles(_ urls: [URL]) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            var failed: [String] = []
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                do {
                    let dest = Self.uniqueDestination(for: u.lastPathComponent)
                    try FileManager.default.copyItem(at: u, to: dest)
                } catch {
                    failed.append(u.lastPathComponent)
                }
                if scoped { u.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                self.isImporting = false
                self.reload()
                if !failed.isEmpty { self.errorMessage = "导入失败：" + failed.joined(separator: "、") }
            }
        }
    }

    @discardableResult
    func addRemote(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = "请输入有效的 http(s) 地址（支持 mp4 / m3u8）"
            return false
        }
        var list = UserDefaults.standard.stringArray(forKey: remoteKey) ?? []
        if !list.contains(trimmed) { list.append(trimmed) }
        UserDefaults.standard.set(list, forKey: remoteKey)
        reload()
        return true
    }

    func delete(_ item: VideoItem) {
        if item.isRemote {
            var list = UserDefaults.standard.stringArray(forKey: remoteKey) ?? []
            list.removeAll { $0 == item.url.absoluteString }
            UserDefaults.standard.set(list, forKey: remoteKey)
        } else {
            try? FileManager.default.removeItem(at: item.url)
        }
        reload()
    }
}
