import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:win32/win32.dart';

/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`, returned when the user dismisses the
/// dialog. A cancellation is not an error, so it is the one failure that is
/// turned back into a null result.
const int _errorCancelledAsHresult = 0x800704C7;

/// Returned by `GetCurrentPackageFullName` when the process is not inside an
/// MSIX package.
const int _appmodelErrorNoPackage = 15700;

/// Durable file and folder access on Windows.
///
/// Windows hands out real paths, so [PathAnchorPlatform] and `dart:io` do all
/// the reading, writing and walking. The only platform-specific piece is the
/// picker, and `IFileOpenDialog` is reachable straight from Dart through
/// `package:win32` -- which is why this implementation contains no C++ at all.
///
/// ## MSIX packaging
///
/// In an unpackaged build -- how Flutter Windows apps are usually shipped -- a
/// path is durable as-is and survives reboots.
///
/// Inside an MSIX package it is not. Windows grants a packaged app access to a
/// picked location for the session, and durable access needs the WinRT
/// `StorageApplicationPermissions.FutureAccessList`. That is not wired up yet,
/// so rather than silently handing back a token that dies on restart, packaging
/// is detected and reported honestly through
/// [AnchorCapabilities.persistsAcrossReboot]. Check it before persisting a
/// token in a packaged build.
final class FileAnchorWindows extends PathAnchorPlatform {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    FileAnchorPlatform.instance = FileAnchorWindows();
  }

  bool? _packaged;

  /// Whether this process runs inside an MSIX package.
  ///
  /// Determined once; it cannot change while the process lives.
  bool get isPackaged => _packaged ??= _detectPackaged();

  static bool _detectPackaged() => using((Arena arena) {
    final length = arena<Uint32>()..value = 0;
    // With a null buffer this only reports the required length, and returns
    // APPMODEL_ERROR_NO_PACKAGE for an unpackaged process.
    final status = GetCurrentPackageFullName(length, null);
    return status != _appmodelErrorNoPackage;
  });

  @override
  AnchorCapabilities get capabilities => AnchorCapabilities(
    canRandomAccessWrite: true,
    canRename: true,
    canQueryFreeSpace: false,
    requiresExplicitScope: false,
    // See the class comment: honest rather than optimistic.
    persistsAcrossReboot: !isPackaged,
  );

  @override
  Future<ResolvedAnchor?> pickDirectory({String? purpose}) async =>
      _showDialog(pickFolders: true, purpose: purpose);

  @override
  Future<ResolvedAnchor?> pickFile({
    String? purpose,
    List<String>? mimeTypes,
  }) async =>
      // Windows filters by extension, not MIME type, and mapping one onto the
      // other reliably is not possible. The filter is skipped rather than
      // guessed at; the user still picks a file and callers can validate after.
      _showDialog(pickFolders: false, purpose: purpose);

  /// Runs the common item dialog.
  ///
  /// The dialog is modal and blocks this isolate while open, which is inherent
  /// to `IModalWindow::Show`. The app window is blocked by the dialog anyway,
  /// so there is nothing to render in the meantime.
  ResolvedAnchor? _showDialog({required bool pickFolders, String? purpose}) {
    // Returns S_FALSE when this thread is already initialised, in which case we
    // must not uninitialise it on the way out.
    final init = CoInitializeEx(COINIT_APARTMENTTHREADED);
    final weInitialised = init == 0;

    try {
      final dialog = createInstance<IFileOpenDialog>(FileOpenDialog);
      try {
        return using((Arena arena) {
          var options =
              dialog.getOptions() |
              FOS_FORCEFILESYSTEM |
              // Leave the process-wide working directory alone; a file dialog
              // silently changing it is a classic source of later bugs.
              FOS_NOCHANGEDIR;
          if (pickFolders) options |= FOS_PICKFOLDERS;
          dialog.setOptions(FILEOPENDIALOGOPTIONS(options));

          if (purpose != null && purpose.isNotEmpty) {
            dialog.setTitle(PCWSTR(purpose.toNativeUtf16(allocator: arena)));
          }

          // Owning the dialog to the app window keeps it from slipping behind.
          dialog.show(GetActiveWindow());

          final item = dialog.getResult();
          if (item == null) return null;
          try {
            final name = item.getDisplayName(SIGDN_FILESYSPATH);
            final path = name.toDartString();
            // The shell allocated this string; the arena did not.
            CoTaskMemFree(name);
            return describePath(path);
          } finally {
            item.release();
          }
        });
      } finally {
        dialog.release();
      }
    } on WindowsException catch (e) {
      // The one expected failure: the user closed the dialog.
      if (e.hr.toUnsigned(32) == _errorCancelledAsHresult) return null;
      final hex = e.hr.toUnsigned(32).toRadixString(16).padLeft(8, '0');
      throw AnchorIoFailure(
        'The file dialog failed (0x$hex): ${e.toString()}',
        e,
      );
    } finally {
      if (weInitialised) CoUninitialize();
    }
  }
}
