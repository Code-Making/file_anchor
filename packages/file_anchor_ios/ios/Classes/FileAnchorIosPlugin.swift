import Flutter
import UIKit
import UniformTypeIdentifiers

/// Error codes shared with `channel_errors.dart`.
///
/// A contract: Dart maps each onto a case of the sealed `AnchorError`
/// hierarchy. Diverge here and a typed error becomes a generic I/O failure.
private enum ErrorCode {
  static let stale = "file_anchor/stale"
  static let revoked = "file_anchor/revoked"
  static let unavailable = "file_anchor/unavailable"
  static let permissionDenied = "file_anchor/permission_denied"
  static let notFound = "file_anchor/not_found"
  static let unsupported = "file_anchor/unsupported"
  static let malformedToken = "file_anchor/malformed_token"
  static let io = "file_anchor/io"
}

/// The iOS side of `file_anchor`.
///
/// Presents the document picker, mints and resolves bookmarks, and holds the
/// access scope. All file I/O happens in Dart against the resolved path.
public class FileAnchorIosPlugin: NSObject, FlutterPlugin,
  UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate
{
  /// The in-flight picker's reply, if any. Only one picker may be open.
  private var pendingPick: FlutterResult?

  /// URLs carrying a live security scope, keyed by path.
  private var scopedUrls: [String: URL] = [:]

  /// Open-scope depth per path, so nested or parallel use cannot close early.
  private var scopeDepth: [String: Int] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.codemaking.file_anchor/apple",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(FileAnchorIosPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickDirectory":
      pick(chooseDirectory: true, call: call, result: result)
    case "pickFile":
      pick(chooseDirectory: false, call: call, result: result)
    case "resolveBookmark":
      resolveBookmark(call, result)
    case "beginAccess":
      beginAccess(call, result)
    case "endAccess":
      endAccess(call, result)
    case "release":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Picking

  private func pick(
    chooseDirectory: Bool,
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard pendingPick == nil else {
      result(
        FlutterError(
          code: ErrorCode.unsupported,
          message: "A picker is already open; await the first one.",
          details: nil
        ))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(
        FlutterError(
          code: ErrorCode.unsupported,
          message: "There is no view controller to present the picker from.",
          details: nil
        ))
      return
    }

    var types: [UTType] = chooseDirectory ? [.folder] : [.item]
    if !chooseDirectory,
       let mimeTypes = (call.arguments as? [String: Any])?["mimeTypes"] as? [String] {
      let mapped = mimeTypes.compactMap { UTType(mimeType: $0) }
      if !mapped.isEmpty { types = mapped }
    }

    // asCopy: false is the whole point. With true, iOS returns a throwaway copy
    // in a temporary directory and there is nothing durable to anchor.
    let picker = UIDocumentPickerViewController(
      forOpeningContentTypes: types,
      asCopy: false
    )
    picker.allowsMultipleSelection = false
    picker.delegate = self
    // Catches a swipe-to-dismiss, which does not call the cancel delegate.
    picker.presentationController?.delegate = self

    // iOS offers no caller-supplied prompt on the picker, so `purpose` is
    // accepted and ignored here. Only macOS can show it, via NSOpenPanel.
    pendingPick = result
    presenter.present(picker, animated: true)
  }

  public func documentPicker(
    _ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]
  ) {
    guard let result = pendingPick else { return }
    pendingPick = nil

    guard let url = urls.first else {
      result(nil)
      return
    }
    do {
      // IMPORTANT: `.withSecurityScope` is macOS-only. On iOS the security
      // scope is implicit in the bookmark, and passing that option throws.
      // Getting this wrong is one of the most common iOS bookmark bugs.
      let data = try url.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      scopedUrls[url.path] = url
      result([
        "bookmark": data.base64EncodedString(),
        "path": url.path,
        "displayName": url.lastPathComponent,
      ])
    } catch let error as NSError {
      result(
        FlutterError(
          code: Self.classify(error),
          message: "Could not bookmark the selection: \(error.localizedDescription)",
          details: nil
        ))
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  public func presentationControllerDidDismiss(
    _ presentationController: UIPresentationController
  ) {
    // A swipe dismissal is a cancellation, and must not leave Dart awaiting a
    // reply that never comes.
    pendingPick?(nil)
    pendingPick = nil
  }

  // MARK: - Bookmarks

  private func resolveBookmark(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let encoded = args["bookmark"] as? String,
          let data = Data(base64Encoded: encoded)
    else {
      result(
        FlutterError(
          code: ErrorCode.malformedToken,
          message: "The bookmark was missing or not valid base64.",
          details: nil
        ))
      return
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      scopedUrls[url.path] = url

      var payload: [String: Any] = ["path": url.path, "isStale": isStale]
      if isStale {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        if let fresh = try? url.bookmarkData(
          options: [],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ) {
          payload["bookmark"] = fresh.base64EncodedString()
        }
      }
      result(payload)
    } catch let error as NSError {
      result(
        FlutterError(
          code: Self.classify(error),
          message: error.localizedDescription,
          details: nil
        ))
    }
  }

  /// Maps a Cocoa error onto the shared error contract.
  private static func classify(_ error: NSError) -> String {
    switch error.code {
    case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
      return ErrorCode.stale
    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
      return ErrorCode.permissionDenied
    case NSFileReadUnknownError:
      return ErrorCode.unavailable
    default:
      return ErrorCode.io
    }
  }

  // MARK: - Access scope

  private func beginAccess(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
    else {
      result(FlutterError(code: ErrorCode.io, message: "beginAccess needs a path.", details: nil))
      return
    }

    var url = scopedUrls[path]
    if url == nil,
       let encoded = args["bookmark"] as? String,
       let data = Data(base64Encoded: encoded) {
      var isStale = false
      url = try? URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      if let resolved = url { scopedUrls[path] = resolved }
    }

    guard let target = url else {
      result(
        FlutterError(
          code: ErrorCode.malformedToken,
          message: "No bookmark is known for \"\(path)\".",
          details: nil
        ))
      return
    }

    let depth = scopeDepth[path] ?? 0
    if depth == 0 {
      _ = target.startAccessingSecurityScopedResource()
    }
    scopeDepth[path] = depth + 1
    result(nil)
  }

  private func endAccess(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
    else {
      result(FlutterError(code: ErrorCode.io, message: "endAccess needs a path.", details: nil))
      return
    }
    let depth = scopeDepth[path] ?? 0
    if depth <= 1 {
      scopedUrls[path]?.stopAccessingSecurityScopedResource()
      scopeDepth[path] = 0
    } else {
      scopeDepth[path] = depth - 1
    }
    result(nil)
  }

  // MARK: - Helpers

  /// Finds the frontmost view controller across connected scenes.
  private static func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let window = windows.first { $0.isKeyWindow } ?? windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
