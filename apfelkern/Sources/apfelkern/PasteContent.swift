import UniformTypeIdentifiers

/// What a composer does with the clipboard. As on the web, files and images win over text, so a copied
/// image that also carries a caption attaches instead of pasting the caption. Links stay text.
public enum PasteContent {
  /// The representation to read for an attachment, if a clipboard item has one.
  public static func fileType(in identifiers: [String]) -> UTType? {
    let types = identifiers.compactMap { UTType($0) }
    if let image = types.first(where: { $0.conforms(to: .image) }) { return image }
    guard !types.contains(where: { $0.conforms(to: .plainText) }) else { return nil }
    return types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
  }

  /// Whether a paste attaches files. Takes the identifiers alone, since reading a value can prompt on iOS.
  public static func attachesFiles(identifiers: [String], hasText: Bool) -> Bool {
    let file = fileType(in: identifiers)
    return file?.conforms(to: .image) == true || (!hasText && file != nil)
      || identifiers.contains { UTType($0)?.conforms(to: .fileURL) == true }
  }
}
