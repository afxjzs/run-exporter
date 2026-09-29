import SwiftUI
import UIKit

/// Presents a UIActivityViewController sharing a file URL (not in-memory contents).
/// Calls `onFinish` when the sheet completes or is dismissed, so the caller can clean up temp files.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
