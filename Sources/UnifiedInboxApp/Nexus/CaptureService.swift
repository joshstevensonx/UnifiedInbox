import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import Vision

/// Screenshots via the system `screencapture` tool and on-device OCR via Vision (spec §6.1, §3.5).
/// Nothing is uploaded. macOS asks once for Screen Recording permission.
@MainActor
final class CaptureService: ObservableObject {
    enum Mode: Equatable {
        case region, window, fullScreen
        case delayed(Int)
    }

    enum Destination: String, CaseIterable, Identifiable {
        case clipboard = "Clipboard", desktop = "Desktop", pictures = "Pictures/Screenshots"
        var id: String { rawValue }
    }

    @Published var destination: Destination {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "captureDestination") }
    }
    @Published private(set) var status: String?
    @Published private(set) var lastOCRText: String?
    @Published private(set) var isBusy = false

    init() {
        destination = Destination(rawValue: UserDefaults.standard.string(forKey: "captureDestination") ?? "") ?? .clipboard
    }

    // MARK: Screenshots

    func screenshot(_ mode: Mode) {
        var args: [String] = []
        switch mode {
        case .region: args = ["-i"]
        case .window: args = ["-iW"]            // starts in window-picking mode
        case .fullScreen: args = ["-m"]          // main display
        case .delayed(let s): args = ["-T", "\(s)", "-m"]
        }
        let file = outputURL()
        if let file { args.append(file.path) } else { args.append("-c") }
        let label: String
        switch mode {
        case .region: label = "Region"
        case .window: label = "Window"
        case .fullScreen: label = "Screen"
        case .delayed(let s): label = "Screen in \(s)s"
        }
        if case .delayed(let s) = mode { flash("Capturing in \(s) seconds…", for: Double(s)) }
        run(args) { [weak self] ok in
            guard let self else { return }
            if !ok { self.flash("Screenshot cancelled"); return }
            if let file, FileManager.default.fileExists(atPath: file.path) {
                self.flash("\(label) saved: \(file.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else if file == nil {
                self.flash("\(label) copied to clipboard")
            } else {
                self.flash("Screenshot cancelled")
            }
        }
    }

    private func outputURL() -> URL? {
        let fm = FileManager.default
        let dir: URL
        switch destination {
        case .clipboard: return nil
        case .desktop: dir = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        case .pictures: dir = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Screenshots")
        }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = f.string(from: Date())
        return dir.appendingPathComponent("Screenshot \(stamp).png")
    }

    // MARK: OCR

    /// Select a region; its text is recognised on-device and copied to the clipboard.
    func captureText() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-ocr-\(UUID().uuidString).png")
        run(["-i", "-x", tmp.path]) { [weak self] ok in
            guard let self else { return }
            guard ok, FileManager.default.fileExists(atPath: tmp.path) else { self.flash("Text capture cancelled"); return }
            self.recognize(fileURL: tmp, deleteAfter: true)
        }
    }

    /// Pick an image or PDF page and extract its text.
    func ocrFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "Extract Text"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognize(fileURL: url, deleteAfter: false)
    }

    func recognize(fileURL: URL, deleteAfter: Bool) {
        isBusy = true
        flash("Recognising text…", for: 30)
        Task.detached(priority: .userInitiated) {
            let text = Self.ocr(fileURL)
            if deleteAfter { try? FileManager.default.removeItem(at: fileURL) }
            await MainActor.run {
                self.isBusy = false
                guard let text, !text.isEmpty else { self.flash("No text found"); return }
                self.lastOCRText = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let lines = text.split(separator: "\n").count
                self.flash("Copied \(lines) line\(lines == 1 ? "" : "s") of text")
            }
        }
    }

    nonisolated private static func ocr(_ url: URL) -> String? {
        var image: CGImage?
        if url.pathExtension.lowercased() == "pdf", let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) {
            image = render(page)
        } else if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func render(_ page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Helpers

    private func run(_ args: [String], completion: @escaping @MainActor (Bool) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        p.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in completion(ok) }
        }
        do { try p.run() } catch { flash("Couldn't start screencapture: \(error.localizedDescription)") }
    }

    private func flash(_ text: String, for seconds: Double = 2.5) {
        status = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.status == text { self?.status = nil }
        }
    }
}

/// Capture buttons used on the Overview page.
struct CaptureCard: View {
    @EnvironmentObject private var capture: CaptureService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Capture")
                Spacer()
                Picker("", selection: $capture.destination) {
                    ForEach(CaptureService.Destination.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().frame(width: 170).controlSize(.small)
                .help("Where screenshots go")
            }
            HStack(spacing: 8) {
                QuickAction(title: "Region", systemImage: "rectangle.dashed", hint: nil) { capture.screenshot(.region) }
                QuickAction(title: "Window", systemImage: "macwindow", hint: nil) { capture.screenshot(.window) }
                QuickAction(title: "Screen", systemImage: "display", hint: nil) { capture.screenshot(.fullScreen) }
                QuickAction(title: "In 5s", systemImage: "timer", hint: nil) { capture.screenshot(.delayed(5)) }
                QuickAction(title: "Copy Text", systemImage: "text.viewfinder", hint: "OCR") { capture.captureText() }
                    .help("Select part of the screen; its text is recognised on this Mac and copied")
                QuickAction(title: "From File", systemImage: "doc.text.magnifyingglass", hint: nil) { capture.ocrFile() }
                    .help("Extract text from an image or PDF")
            }
            Text(capture.status ?? "Screenshots use macOS's screencapture; text recognition runs on-device (Vision).")
                .font(.system(size: 11))
                .foregroundStyle(capture.status == nil ? Theme.tertiary : Theme.accent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
