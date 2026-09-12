import Cocoa
import FlutterMacOS

/// Error codes shared with `channel_errors.dart`.
///
/// These strings are a contract: Dart maps each onto a case of the sealed
/// `AnchorError` hierarchy. Change one here without changing it there and a
/// typed error silently becomes a generic I/O failure.
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

/// The macOS side of `file_anchor`.
///
/// Responsibilities are deliberately narrow: show the panel, mint and resolve
/// security-scoped bookmarks, and hold the access scope open. Everything else
/// happens in Dart against a plain path.
public class FileAnchorMacosPlugin: NSObject, FlutterPlugin {

  /// URLs that carry a live security scope, keyed by path.
  private var scopedUrls: [String: URL] = [:]

  /// Open-scope depth per path, so two anchors on one folder cannot close
  /// each other's scope.
  private var scopeDepth: [String: Int] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.codemaking.file_anchor/apple",
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(FileAnchorMacosPlugin(), channel: channel)
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
      // A bookmark needs no handing back; forgetting it in Dart is enough.
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
    let args = call.arguments as? [String: Any]
    let panel = NSOpenPanel()
    panel.canChooseDirectories = chooseDirectory
    panel.canChooseFiles = !chooseDirectory
    panel.canCreateDirectories = chooseDirectory
    panel.allowsMultipleSelection = false
    panel.resolvesAliases = true
    // Unlike Android's picker and iOS's, NSOpenPanel can actually show the
    // caller's prompt, so `purpose` is honoured here.
    if let purpose = args?["purpose"] as? String, !purpose.isEmpty {
      panel.message = purpose
    }

    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        // Cancellation is not an error.
        result(nil)
        return
      }
      result(self.describe(url))
    }
  }

  /// Builds the pick result, preferring a bookmark and falling back to a path.
  ///
  /// A security-scoped bookmark requires the app sandbox. An unsandboxed build
  /// simply cannot mint one, so rather than failing, hand back the path: for a
  /// build with full disk access that is every bit as durable, and the Dart
  /// side already understands a path token.
  private func describe(_ url: URL) -> [String: Any] {
    var payload: [String: Any] = [
      "path": url.path,
      "displayName": url.lastPathComponent,
    ]
    if let data = try? url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    ) {
      scopedUrls[url.path] = url
      payload["bookmark"] = data.base64EncodedString()
    }
    return payload
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
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      scopedUrls[url.path] = url

      var payload: [String: Any] = ["path": url.path, "isStale": isStale]
      if isStale {
        // A stale bookmark still resolved, but will not keep doing so. Mint a
        // replacement now and let Dart re-persist it. Minting needs the scope
        // open.
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        if let fresh = try? url.bookmarkData(
          options: [.withSecurityScope],
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
      // The engine was restarted, or this anchor was resolved before we cached
      // it; re-resolve rather than failing.
      var isStale = false
      url = try? URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
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
      // Returns false for a URL that is not security-scoped, which is the
      // normal case in an unsandboxed build. That is not a failure.
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
}
