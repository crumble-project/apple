import Foundation
import UIKit
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
  /// Avoid reading an unbounded local file into memory before validating its type/size.
  static let maxInputBytes = 32 * 1024 * 1024
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
  if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
    let fileSize = values.fileSize, fileSize > AttachmentLimits.maxInputBytes
  {
    throw AttachmentError(errorDescription: "\(name) is too large to attach.")
  }
  let data = try Data(contentsOf: url, options: [.mappedIfSafe])
  guard data.count <= AttachmentLimits.maxInputBytes else {
    throw AttachmentError(errorDescription: "\(name) is too large to attach.")
  }
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
  if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
    || type.conforms(to: .xml)
  {
    guard data.count <= AttachmentLimits.textBytes else {
      throw AttachmentError(errorDescription: "\(name) is larger than 512 KB.")
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw AttachmentError(errorDescription: "\(name) isn't UTF-8 text.")
    }
    let mime =
      type.preferredMIMEType.flatMap {
        $0.hasPrefix("text/") || $0 == "application/json" ? $0 : nil
      } ?? "text/plain"
    return PendingAttachment(name: name, mimeType: mime, data: data)
  }
  throw AttachmentError(errorDescription: "\(name) can't be attached. Attach images or text files.")
}

private func jpegData(from data: Data) -> Data? {
  guard let image = UIImage(data: data) else { return nil }
  let longestSide = max(image.size.width, image.size.height)
  let scale = min(1, AttachmentLimits.imageSide / max(longestSide, 1))
  let size = CGSize(
    width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
  let format = UIGraphicsImageRendererFormat.default()
  format.scale = 1
  format.opaque = true
  let renderer = UIGraphicsImageRenderer(size: size, format: format)
  let rendered = renderer.image { _ in
    UIColor.white.setFill()
    UIRectFill(CGRect(origin: .zero, size: size))
    image.draw(in: CGRect(origin: .zero, size: size))
  }
  return rendered.jpegData(compressionQuality: 0.85)
}
