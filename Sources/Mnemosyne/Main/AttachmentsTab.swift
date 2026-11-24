import AppKit
import MnemosyneCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// «Приложения»: скриншоты, документы и другие файлы к встрече. Копируются в `attachments/` папки встречи.
/// Файлы добавляются перетаскиванием на вкладку или кнопкой «Выбрать файлы…».
struct AttachmentsTab: View {
    @Bindable var library: LibraryModel
    let detail: MeetingDetail

    @State private var files: [URL] = []
    @State private var targeted = false
    @State private var failed: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            if let failed {
                Text(failed).font(.system(size: 13)).foregroundStyle(Theme.red)
            }
            if !files.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(files, id: \.self) { url in
                        AttachmentTile(url: url, open: { NSWorkspace.shared.open(url) }, remove: { remove(url) })
                    }
                }
            }
        }
        .frame(minHeight: 420, alignment: .top)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted, perform: drop)
        .onAppear(perform: reload)
        .onChange(of: detail.folder) { _, _ in reload() }
    }

    private var dropZone: some View {
        HStack(spacing: 14) {
            Image(systemName: "paperclip").font(.system(size: 16)).foregroundStyle(Theme.sec)
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "Отпустите, чтобы приложить" : "Перетащите сюда скриншоты, документы и другие файлы")
                    .font(.system(size: 14))
                Text("Копии сохранятся в папке встречи. Видны только вам.")
                    .font(.system(size: 12)).foregroundStyle(Theme.sec)
            }
            Spacer()
            Button("Выбрать файлы…", action: choose).buttonStyle(Pill())
        }
        .padding(.horizontal, 18).frame(height: files.isEmpty ? 160 : 72)
        .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Theme.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Theme.sec.opacity(0.6) : Theme.line,
                                                                 style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    // MARK: - Действия

    /// Папка встречи по UUID: её могли переименовать, пока вкладка открыта.
    private var folder: URL { library.store.locate(id: detail.meta.id) ?? detail.folder }

    private func reload() { files = Attachments.list(folder) }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Приложить")
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let target = folder
        var errors = 0
        for url in urls where (try? Attachments.add(url, to: target)) == nil { errors += 1 }
        failed = errors == 0 ? nil : String(localized: "Не удалось приложить файлов: \(errors)")
        reload()
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let target = folder
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                // Картинка без файла — например, из браузера: сохраняем как PNG.
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let image = obj as? NSImage, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                    let name = String(localized: "Изображение") + " " + stamp.replacingOccurrences(of: ":", with: ".") + ".png"
                    Task { @MainActor in
                        failed = (try? Attachments.add(data: png, named: name, to: target)) == nil
                            ? String(localized: "Не удалось сохранить изображение") : nil
                        reload()
                    }
                }
            }
        }
        return true
    }

    private func remove(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { _, _ in
            Task { @MainActor in reload() }
        }
    }
}

/// Плитка файла: превью Quick Look, имя, размер. Щелчок открывает файл.
private struct AttachmentTile: View {
    let url: URL
    let open: () -> Void
    let remove: () -> Void

    @State private var thumb: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.hoverSoft)
                    Image(nsImage: thumb ?? NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .aspectRatio(contentMode: thumb == nil ? .fit : .fill)
                        .frame(maxWidth: thumb == nil ? 56 : .infinity, maxHeight: thumb == nil ? 56 : .infinity)
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hovering ? Theme.sec.opacity(0.5) : Theme.line))
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    Text(Self.size(url)).font(.system(size: 12)).foregroundStyle(Theme.sec)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help(url.lastPathComponent)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Открыть", action: open)
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Удалить", role: .destructive, action: remove)
        }
        .task(id: url) { thumb = await Self.thumbnail(url) }
    }

    static func thumbnail(_ url: URL) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 360, height: 240), scale: scale,
                                                   representationTypes: .thumbnail)
        // Обработчик вместо async-варианта: результат не Sendable и не переживает переход между акторами.
        let cg: CGImage? = await withCheckedContinuation { done in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                let image = rep?.cgImage
                done.resume(returning: image)
            }
        }
        return cg.map { NSImage(cgImage: $0, size: .zero) }
    }

    static func size(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if v?.isDirectory == true { return String(localized: "Папка") }
        return ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
    }
}
