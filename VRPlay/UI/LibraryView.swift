import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @StateObject private var store = LibraryStore()
    @State private var playing: VideoItem?
    @State private var showImporter = false
    @State private var showAddURL = false
    @State private var urlText = ""
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if store.local.isEmpty && store.remote.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("VRPlay")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    PhotosPicker(selection: $photoSelection, maxSelectionCount: 5, matching: .videos) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    Menu {
                        Button { showImporter = true } label: { Label("从“文件”导入", systemImage: "folder") }
                        Button { urlText = ""; showAddURL = true } label: { Label("添加网络地址", systemImage: "link") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .overlay { if store.isImporting { ProgressView("导入中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
        .alert("添加网络视频", isPresented: $showAddURL) {
            TextField("https://…/video.mp4 或 .m3u8", text: $urlText)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("添加") { store.addRemote(urlText) }
        }
        .alert("提示", isPresented: Binding(get: { store.errorMessage != nil },
                                           set: { if !$0 { store.errorMessage = nil } })) {
            Button("好") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            store.isImporting = true
            Task {
                for item in items { _ = try? await item.loadTransferable(type: MovieFile.self) }
                await MainActor.run {
                    photoSelection = []
                    store.isImporting = false
                    store.reload()
                }
            }
        }
        .onAppear { store.reload() }
    }

    private var list: some View {
        List {
            if !store.local.isEmpty {
                Section("本地视频") {
                    ForEach(store.local) { row($0) }
                        .onDelete { idx in idx.map { store.local[$0] }.forEach(store.delete) }
                }
            }
            if !store.remote.isEmpty {
                Section("网络视频") {
                    ForEach(store.remote) { row($0) }
                        .onDelete { idx in idx.map { store.remote[$0] }.forEach(store.delete) }
                }
            }
        }
    }

    private func row(_ item: VideoItem) -> some View {
        Button { playing = item } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isRemote ? "network" : "film")
                    .font(.title3).frame(width: 28).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(2).foregroundColor(.primary)
                    if let size = item.fileSizeText {
                        Text(size).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.circle").foregroundColor(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "eyeglasses").font(.system(size: 56)).foregroundColor(.secondary)
            Text("还没有视频").font(.title3)
            Text("点右上角导入：相册、“文件”App，或网络地址。\n也可以通过 Finder / iTunes 文件共享，把 mp4 / mov 拖进本 App。")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
            Button("从“文件”导入") { showImporter = true }.buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
