import AppKit
import Foundation
import UniformTypeIdentifiers

/// A file waiting in the composer, already in a form the server accepts.
struct PendingAttachment: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var mimeType: String
    var data: Data

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var outgoing: OutgoingAttachment {
        OutgoingAttachment(name: name, mimeType: mimeType, data: data.base64EncodedString())
    }
}

enum AttachmentLimits {
    static let count = 8
    static let imageBytes = 5 * 1024 * 1024
    static let textBytes = 512 * 1024
    static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    /// The longest side an image is scaled to when it has to be re-encoded.
    static let imageSide: CGFloat = 2048
}

struct AttachmentError: LocalizedError {
    var errorDescription: String?
}

/// Reads a picked or dropped file into an attachment. Images the server can't take as they are
/// (HEIC, TIFF, or larger than 5 MB) are re-encoded as JPEG; text files must be UTF-8.
func loadAttachment(from url: URL) throws -> PendingAttachment {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = url.lastPathComponent
    let type =
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(
            filenameExtension: url.pathExtension) ?? .data
    let data = try Data(contentsOf: url)
    if type.conforms(to: .image) {
        let mime = type.preferredMIMEType ?? ""
        if AttachmentLimits.imageTypes.contains(mime), data.count <= AttachmentLimits.imageBytes {
            return PendingAttachment(name: name, mimeType: mime, data: data)
        }
        guard let jpeg = jpegData(from: data) else {
            throw AttachmentError(errorDescription: "\(name) couldn't be read as an image.")
        }
        guard jpeg.count <= AttachmentLimits.imageBytes else {
            throw AttachmentError(errorDescription: "\(name) is larger than 5 MB.")
        }
        return PendingAttachment(
            name: (name as NSString).deletingPathExtension + ".jpg", mimeType: "image/jpeg", data: jpeg)
    }
    let isText = [UTType.text, .sourceCode, .json, .xml].contains { type.conforms(to: $0) }
    if isText {
        guard data.count <= AttachmentLimits.textBytes else {
            throw AttachmentError(errorDescription: "\(name) is larger than 512 KB.")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw AttachmentError(errorDescription: "\(name) isn't UTF-8 text.")
        }
        let mime =
            type.preferredMIMEType.flatMap { $0.hasPrefix("text/") || $0 == "application/json" ? $0 : nil }
            ?? "text/plain"
        return PendingAttachment(name: name, mimeType: mime, data: data)
    }
    throw AttachmentError(errorDescription: "\(name) can't be attached. Attach images or text files.")
}

private func jpegData(from data: Data) -> Data? {
    guard let image = NSImage(data: data), let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let scale = min(1, AttachmentLimits.imageSide / CGFloat(max(source.width, source.height)))
    let width = Int(CGFloat(source.width) * scale)
    let height = Int(CGFloat(source.height) * scale)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
}
