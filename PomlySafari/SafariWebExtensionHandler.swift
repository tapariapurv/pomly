import Foundation

/// Safari requires a principal class. The extension talks to Firebase directly, so native messaging stays unused.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) { context.completeRequest(returningItems: [], completionHandler: nil) }
}
