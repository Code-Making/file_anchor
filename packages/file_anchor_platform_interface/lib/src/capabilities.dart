/// What an anchor can actually do on the current platform.
///
/// The three platforms genuinely differ, and pretending otherwise is how
/// cross-platform packages lose trust. `file_anchor` unifies what can be
/// unified and reports the rest here, so callers can branch deliberately
/// instead of discovering a silent no-op in production.
final class AnchorCapabilities {
  const AnchorCapabilities({
    required this.canRandomAccessWrite,
    required this.canRename,
    required this.canQueryFreeSpace,
    required this.requiresExplicitScope,
    required this.persistsAcrossReboot,
  });

  /// Whether writes can start at an arbitrary offset.
  ///
  /// False on Android SAF, where a document is effectively append/replace only.
  final bool canRandomAccessWrite;

  /// Whether an entry can be renamed in place.
  final bool canRename;

  /// Whether free space on the backing volume can be queried.
  final bool canQueryFreeSpace;

  /// Whether the platform needs a security scope opened before I/O.
  ///
  /// True on iOS and macOS. `Anchor.use` handles this for you; this flag is for
  /// diagnostics and tests.
  final bool requiresExplicitScope;

  /// Whether access genuinely survives a device reboot.
  ///
  /// False only in degraded cases, such as an unpackaged Windows build pointing
  /// at a removable volume.
  final bool persistsAcrossReboot;

  /// Conservative defaults: the intersection of what all platforms support.
  static const AnchorCapabilities minimal = AnchorCapabilities(
    canRandomAccessWrite: false,
    canRename: false,
    canQueryFreeSpace: false,
    requiresExplicitScope: false,
    persistsAcrossReboot: true,
  );

  @override
  String toString() => 'AnchorCapabilities('
      'randomAccessWrite: $canRandomAccessWrite, '
      'rename: $canRename, '
      'freeSpace: $canQueryFreeSpace, '
      'explicitScope: $requiresExplicitScope, '
      'persists: $persistsAcrossReboot)';
}
