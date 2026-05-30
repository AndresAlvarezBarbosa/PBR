import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageIngestView: View {
    var generator: TextureGenerator
    @State private var isTargeted = false
    @State private var isImporting = false
    @State private var pathText = ""
    @State private var pathError = false
    @State private var loadedFileName: String?

    var body: some View {
        VStack(spacing: 8) {
            dropZone
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        loadImage(from: url)
                    }
                }

            // Path / URL entry row
            HStack(spacing: 6) {
                TextField("Paste file path or file:// URL…", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(pathError ? .red : .primary)
                    .onSubmit { loadFromPath() }

                Button("Open") { loadFromPath() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(pathText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Drop Zone

    @ViewBuilder
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.05) : Color.black.opacity(0.1))
                )

            if let name = displayName {
                // Loaded state — show filename + swap button
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.green)
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 280)
                    Button("Load Different…") { isImporting = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding()
            } else {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundColor(isTargeted ? .accentColor : .secondary)
                    Text("Drop PNG, JPEG, TIFF or HEIC")
                        .font(.subheadline)
                    Text("Standardized to 1024×1024")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Browse File…") { isImporting = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted, perform: loadFromDrop)
    }

    // Non-nil only when an image is actually present in the generator.
    private var displayName: String? {
        guard generator.sourceImage != nil else { return nil }
        return loadedFileName ?? "Image loaded"
    }

    // MARK: - Load Helpers

    private func loadFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Prefer a direct NSImage payload (drags from Photos, Preview, etc.)
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let image = obj as? NSImage else { return }
                Task { @MainActor in
                    loadedFileName = nil
                    await generator.ingest(image: image)
                }
            }
            return true
        }

        // Finder drag: provider gives a file URL
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url  = URL(dataRepresentation: data, relativeTo: nil),
                      let img  = NSImage(contentsOf: url) else { return }
                let name = url.lastPathComponent
                Task { @MainActor in
                    loadedFileName = name
                    await generator.ingest(image: img)
                }
            }
            return true
        }

        return false
    }

    private func loadImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url) else { return }
        let name = url.lastPathComponent
        Task { @MainActor in
            loadedFileName = name
            await generator.ingest(image: image)
        }
    }

    private func loadFromPath() {
        var raw = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip file:// scheme if pasted from Finder "Copy as Pathname" or terminal
        if raw.hasPrefix("file://") { raw = String(raw.dropFirst(7)) }
        // Decode percent-encoded characters (%20 → space, etc.)
        raw = raw.removingPercentEncoding ?? raw
        // Strip surrounding quotes (common when pasting shell paths)
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") { raw = String(raw.dropFirst().dropLast()) }

        let url = URL(fileURLWithPath: raw)
        guard let image = NSImage(contentsOf: url) else {
            pathError = true
            return
        }
        pathError = false
        let name = url.lastPathComponent
        pathText = ""
        Task { @MainActor in
            loadedFileName = name
            await generator.ingest(image: image)
        }
    }
}
