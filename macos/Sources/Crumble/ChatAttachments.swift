import apfelkern
import AppKit
import SwiftUI

/// A file in the composer: a thumbnail for an image, the file name for text, with a remove button.
struct PendingAttachmentChip: View {
    let file: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        Group {
            if file.isImage, let image = NSImage(data: file.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 10))
            } else {
                FileLabel(name: file.name)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("Remove \(file.name)", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
                .offset(x: 6, y: -6)
        }
        .help(file.name)
    }
}

/// The files a sent message carries: image thumbnails loaded from the server, text files by name.
struct SentAttachments: View {
    @Environment(AppModel.self) private var model
    let message: Message

    var body: some View {
        let files = Array((message.attachments ?? []).enumerated())
        if !files.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(files, id: \.offset) { index, file in
                    if file.isImage {
                        Group {
                            if let image = model.attachmentImage(message: message, index: index) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06))
                                    .frame(width: 160, height: 120)
                                    .overlay { ProgressView().controlSize(.small) }
                            }
                        }
                        .frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 14))
                        .help(file.name)
                        .task {
                            if let entryID = message.entryId {
                                await model.loadAttachmentImage(entryID: entryID, index: index)
                            }
                        }
                    } else {
                        FileLabel(name: file.name)
                    }
                }
            }
        }
    }
}

struct FileLabel: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "doc.text")
            .lineLimit(1)
            .truncationMode(.middle)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 220)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 10))
    }
}
