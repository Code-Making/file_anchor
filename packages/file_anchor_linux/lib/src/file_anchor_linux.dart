import 'dart:async';
import 'dart:math';

import 'package:dbus/dbus.dart';
import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';

/// Durable file and folder access on Linux.
///
/// Linux hands out real paths, so [PathAnchorPlatform] and `dart:io` do all the
/// reading, writing and walking. Only the picker is platform-specific, and it
/// goes through the **XDG desktop portal** over D-Bus, which is reachable
/// straight from Dart -- so this implementation contains no C or GTK code.
///
/// The portal is used rather than a GTK file chooser for one concrete reason:
/// inside Flatpak or Snap a sandboxed app cannot open an arbitrary path, and the
/// portal is what grants access. It returns a path under the document portal
/// that the app genuinely can read, and on an unsandboxed system it returns the
/// real path. One code path, correct in both.
///
/// Requires `xdg-desktop-portal` with a backend (GTK, KDE, or similar) to be
/// running, which is the default on current desktops. Folder selection needs
/// portal `FileChooser` version 3 or newer.
final class FileAnchorLinux extends PathAnchorPlatform {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    FileAnchorPlatform.instance = FileAnchorLinux();
  }

  static const String _portalName = 'org.freedesktop.portal.Desktop';
  static const String _portalPath = '/org/freedesktop/portal/desktop';
  static const String _fileChooser = 'org.freedesktop.portal.FileChooser';
  static const String _request = 'org.freedesktop.portal.Request';

  /// Portal response codes: 0 succeeded, 1 cancelled by the user, 2 ended
  /// some other way.
  static const int _responseSuccess = 0;
  static const int _responseCancelled = 1;

  static final Random _random = Random();

  @override
  Future<ResolvedAnchor?> pickDirectory({String? purpose}) =>
      _openFile(directory: true, purpose: purpose);

  @override
  Future<ResolvedAnchor?> pickFile({
    String? purpose,
    List<String>? mimeTypes,
  }) =>
      _openFile(directory: false, purpose: purpose);

  Future<ResolvedAnchor?> _openFile({
    required bool directory,
    String? purpose,
  }) async {
    final client = DBusClient.session();
    try {
      // Forces the connection so `uniqueName` is populated, which the request
      // path below is derived from.
      await client.ping();

      final token = 'file_anchor_${_random.nextInt(1 << 32)}';
      final expectedPath = DBusObjectPath(
        '$_portalPath/request/${_busNameSegment(client.uniqueName)}/$token',
      );

      // Subscribe *before* calling. The portal may answer before the method
      // reply arrives, and a late subscription would miss the signal entirely
      // -- which is exactly why the spec has callers predict the handle.
      final responses = _responseStream(client, expectedPath);
      final subscription = StreamController<DBusSignal>();
      final forwarding = responses.listen(
        subscription.add,
        onError: subscription.addError,
      );

      try {
        final reply = await client.callMethod(
          destination: _portalName,
          path: DBusObjectPath(_portalPath),
          interface: _fileChooser,
          name: 'OpenFile',
          values: [
            // No parent window handle: the portal then places the dialog
            // itself rather than parenting it. Obtaining a real handle needs
            // the compositor-specific export APIs.
            const DBusString(''),
            DBusString(purpose?.isNotEmpty == true ? purpose! : 'Choose'),
            DBusDict.stringVariant({
              'handle_token': DBusString(token),
              'modal': const DBusBoolean(true),
              'multiple': const DBusBoolean(false),
              // Honoured by FileChooser version 3 and later.
              if (directory) 'directory': const DBusBoolean(true),
            }),
          ],
          replySignature: DBusSignature('o'),
        );

        final handle = reply.returnValues.first.asObjectPath();
        final signal = handle == expectedPath
            ? await subscription.stream.first
            // An older portal ignored handle_token and minted its own path, so
            // fall back to whatever it actually returned.
            : await _responseStream(client, handle).first;

        return _readResponse(signal, directory: directory);
      } finally {
        await forwarding.cancel();
        await subscription.close();
      }
    } on DBusServiceUnknownException catch (e) {
      throw AnchorUnsupported(
        'No XDG desktop portal is available. Install and run '
        'xdg-desktop-portal together with a backend such as '
        'xdg-desktop-portal-gtk.',
        e,
      );
    } on DBusMethodResponseException catch (e) {
      throw AnchorIoFailure('The desktop portal rejected the request: $e', e);
    } finally {
      await client.close();
    }
  }

  Stream<DBusSignal> _responseStream(DBusClient client, DBusObjectPath path) =>
      DBusRemoteObjectSignalStream(
        object: DBusRemoteObject(client, name: _portalName, path: path),
        interface: _request,
        name: 'Response',
      );

  ResolvedAnchor? _readResponse(DBusSignal signal, {required bool directory}) {
    if (signal.values.length < 2) {
      throw const AnchorIoFailure('The portal sent a malformed Response.');
    }
    final code = signal.values[0].asUint32();
    if (code == _responseCancelled) return null;
    if (code != _responseSuccess) {
      throw AnchorIoFailure('The portal ended the request with code $code.');
    }

    final results = signal.values[1].asStringVariantDict();
    final uris = results['uris']?.asStringArray().toList() ?? const <String>[];
    if (uris.isEmpty) return null;

    final uri = Uri.parse(uris.first);
    if (uri.scheme != 'file') {
      throw AnchorUnsupported(
        'The portal returned a "${uri.scheme}" location, which cannot be read '
        'as a file. Choose a location on the local filesystem.',
      );
    }
    return describePath(uri.toFilePath());
  }

  /// Turns a bus name into the segment the portal uses in request paths.
  ///
  /// A unique name such as `:1.42` becomes `1_42`: the leading colon is dropped
  /// and dots become underscores, because a D-Bus path segment allows neither.
  static String _busNameSegment(String uniqueName) {
    final trimmed =
        uniqueName.startsWith(':') ? uniqueName.substring(1) : uniqueName;
    return trimmed.replaceAll('.', '_');
  }
}
