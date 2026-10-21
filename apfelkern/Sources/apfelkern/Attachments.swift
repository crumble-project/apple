import Foundation

public struct PendingAttachment: Identifiable, Hashable, Sendable {
  public let id = UUID()
  public var name: String
  public var mimeType: String
  public var data: Data

  public init(name: String, mimeType: String, data: Data) {
    self.name = name
    self.mimeType = mimeType
    self.data = data
  }

  public var isImage: Bool { mimeType.hasPrefix("image/") }
  public var outgoing: OutgoingAttachment {
    OutgoingAttachment(name: name, mimeType: mimeType, data: data.base64EncodedString())
  }
}

public enum AttachmentLimits {
  public static let count = 8
  public static let imageBytes = 5 * 1024 * 1024
  public static let textBytes = 512 * 1024
  public static let imageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
  public static let imageSide: CGFloat = 2048
}

public struct AttachmentError: LocalizedError {
  public var errorDescription: String?

  public init(errorDescription: String? = nil) {
    self.errorDescription = errorDescription
  }
}
