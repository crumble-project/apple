import apfelkern
import SwiftUI
import UIKit

/// A hardware key the composer may take before the text does.
enum ComposerKey {
  case send, tab, escape, arrowUp, arrowDown
}

/// The message field. SwiftUI's has no paste hook before iOS 27 and offers Paste only for text, so this
/// text view takes files and images from the clipboard. Nil `selection` means the end of the text.
struct ComposerTextView: UIViewRepresentable {
  private static let maxLines: CGFloat = 8

  @Binding var text: String
  @Binding var selection: NSRange?
  let label: String
  let enabled: Bool
  let onKey: (ComposerKey) -> Bool
  let onPaste: ([NSItemProvider]) -> Void

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextView
    /// Text set from SwiftUI reports back through the delegate, inside a view update.
    var updating = false

    init(parent: ComposerTextView) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      guard !updating else { return }
      parent.text = textView.text
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !updating else { return }
      parent.selection = textView.selectedRange
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeUIView(context: Context) -> PastingTextView {
    let view = PastingTextView()
    view.delegate = context.coordinator
    view.font = .preferredFont(forTextStyle: .body)
    view.adjustsFontForContentSizeCategory = true
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return view
  }

  func updateUIView(_ view: PastingTextView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    view.onKey = onKey
    view.onPaste = onPaste
    view.isEditable = enabled
    view.accessibilityLabel = label
    view.show(text, selection: selection)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
    let width = proposal.width ?? view.bounds.width
    guard width > 0, let font = view.font else { return nil }
    let height = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
    return CGSize(width: width, height: min(ceil(height), ceil(font.lineHeight * Self.maxLines)))
  }
}

final class PastingTextView: UITextView {
  var onKey: (ComposerKey) -> Bool = { _ in false }
  var onPaste: ([NSItemProvider]) -> Void = { _ in }

  /// Reads only what the clipboard holds, which iOS allows without asking.
  private var pasteAttachesFiles: Bool {
    let pasteboard = UIPasteboard.general
    return PasteContent.attachesFiles(identifiers: pasteboard.types, hasText: pasteboard.hasStrings)
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), isEditable, pasteAttachesFiles { return true }
    return super.canPerformAction(action, withSender: sender)
  }

  override func paste(_ sender: Any?) {
    if pasteAttachesFiles {
      onPaste(UIPasteboard.general.itemProviders)
    } else {
      super.paste(sender)
    }
  }

  /// Marked text is left alone while it's composing, or an update would break the composition.
  func show(_ text: String, selection: NSRange?) {
    // The Send button empties the draft mid-composition; marked text would keep the sent words here.
    if text.isEmpty, markedTextRange != nil { unmarkText() }
    if self.text != text, markedTextRange == nil { self.text = text }
    let length = (self.text as NSString).length
    let wanted = selection.flatMap { $0.upperBound <= length ? $0 : nil } ?? NSRange(location: length, length: 0)
    if selectedRange != wanted, markedTextRange == nil { selectedRange = wanted }
  }

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    // While composing, these keys belong to the input method: Return confirms, arrows pick a candidate.
    guard markedTextRange == nil, let key = presses.first?.key, let composerKey = composerKey(key), onKey(composerKey)
    else { return super.pressesBegan(presses, with: event) }
  }

  /// Return with Shift or Option stays a line break, which the text view inserts itself.
  private func composerKey(_ key: UIKey) -> ComposerKey? {
    switch key.keyCode {
    case .keyboardReturnOrEnter: key.modifierFlags.isDisjoint(with: [.shift, .alternate]) ? .send : nil
    case .keyboardTab: .tab
    case .keyboardEscape: .escape
    case .keyboardUpArrow: .arrowUp
    case .keyboardDownArrow: .arrowDown
    default: nil
    }
  }
}
