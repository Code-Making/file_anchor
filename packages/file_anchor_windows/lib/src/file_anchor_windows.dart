import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:file_anchor_path_io/file_anchor_path_io.dart';
import 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart';
import 'package:win32/win32.dart';

// Win32 ABI values, declared here on purpose.
//
// They are fixed by the platform and will never change, whereas how the `win32`
// package groups its constants has moved between major versions. Declaring the
// six we need locally keeps this file working across those reorganisations,
// while still using `win32` for the functions and COM interfaces themselves.
const int _sOk = 0;
const int _coinitApartmentThreaded = 0x2;
const int _coinitDisableOle1Dde = 0x4;
const int _fosNoChangeDir = 0x8;
const int _fosPickFolders = 0x20;
const int _fosForceFilesystem = 0x40;
const int _sigdnFilesysPath = 0x80058000;

/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`, which is what the dialog returns when
/// the user dismisses it. A cancellation is not an error.
const int _errorCancelledAsHresult = 0x800704C7;

/// Returned by `GetCurrentPackageFullName` when the process is not in an MSIX
/// package.
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
  /// Determined once: it cannot change while the process lives.
  bool get isPackaged => _packaged ??= _detectPackaged();

  static bool _detectPackaged() => using((Arena arena) {
        final length = arena<Uint32>()..value = 0;
        // With a null buffer this only reports the required length, and returns
        // APPMODEL_ERROR_NO_PACKAGE for an unpackaged process.
        final status = GetCurrentPackageFullName(length, nullptr);
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
      // Windows filters by extension, not MIME type. Mapping one to the other
      // reliably is not possible, so the filter is skipped rather than guessed
      // at; the user still picks a file, and callers can validate afterwards.
      _showDialog(pickFolders: false, purpose: purpose);

  /// Runs the common item dialog.
  ///
  /// The dialog is modal and blocks this isolate while it is open, which is
  /// inherent to `IModalWindow::Show`. The app window is blocked by the dialog
  /// anyway, so there is nothing to render in the meantime.
  ResolvedAnchor? _showDialog({required bool pickFolders, String? purpose}) {
    // Returns S_FALSE when the thread is already initialised, in which case we
    // must not uninitialise it on the way out.
    final init = CoInitializeEx(
      nullptr,
      _coinitApartmentThreaded | _coinitDisableOle1Dde,
    );
    final weInitialised = init == _sOk;

    try {
      final dialog = FileOpenDialog.createInstance();
      try {
        return using((Arena arena) {
          final optionsPtr = arena<Uint32>();
          _check(dialog.getOptions(optionsPtr), 'GetOptions');

          var options = optionsPtr.value |
              _fosForceFilesystem |
              // Leave the process-wide working directory alone; a file dialog
              // silently changing it is a classic source of later bugs.
              _fosNoChangeDir;
          if (pickFolders) options |= _fosPickFolders;
          _check(dialog.setOptions(options), 'SetOptions');

          if (purpose != null && purpose.isNotEmpty) {
            dialog.setTitle(purpose.toNativeUtf16(allocator: arena));
          }

          // Owning the dialog to the app window keeps it from slipping behind.
          final hr = dialog.show(GetActiveWindow());
          if (hr == _errorCancelledAsHresult) return null;
          _check(hr, 'Show');

          final itemPtr = arena<Pointer<COMObject>>();
          _check(dialog.getResult(itemPtr), 'GetResult');

          final item = IShellItem(itemPtr.value);
          try {
            final namePtr = arena<Pointer<Utf16>>();
            _check(
              item.getDisplayName(_sigdnFilesysPath, namePtr),
              'GetDisplayName',
            );
            final path = namePtr.value.toDartString();
            // The shell allocated this string; the arena did not.
            CoTaskMemFree(namePtr.value.cast());
            return describePath(path);
          } finally {
            item.release();
          }
        });
      } finally {
        dialog.release();
      }
    } finally {
      if (weInitialised) CoUninitialize();
    }
  }

  /// Converts a failed `HRESULT` into a typed error.
  static void _check(int hr, String what) {
    if (!FAILED(hr)) return;
    final hex = hr.toUnsigned(32).toRadixString(16).padLeft(8, '0');
    throw AnchorIoFailure('IFileOpenDialog::$what failed (0x$hex).');
  }
}
