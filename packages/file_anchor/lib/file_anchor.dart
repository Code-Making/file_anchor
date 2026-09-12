/// Pick a file or folder once and keep durable access to it across app
/// restarts and device reboots, on Android, iOS and Windows.
///
/// A filesystem path is the wrong abstraction for this: on Android a location is
/// a revocable `content://` grant, on iOS it is a bookmark whose path changes
/// underneath you, and only on Windows is it really a path. `file_anchor`
/// replaces the path with an opaque, durable [Anchor.token] that all three
/// platforms can represent honestly.
library;

export 'package:file_anchor_platform_interface/file_anchor_platform_interface.dart'
    show
        AnchorCapabilities,
        AnchorEntry,
        AnchorEntryNotFound,
        AnchorError,
        AnchorIoFailure,
        AnchorKind,
        AnchorPermissionDenied,
        AnchorQuotaExceeded,
        AnchorRevoked,
        AnchorStale,
        AnchorStat,
        AnchorToken,
        AnchorTokenMalformed,
        AnchorUnavailable,
        AnchorUnsupported;

export 'src/anchor.dart' show Anchor, AnchorIo;
export 'src/file_anchor.dart' show FileAnchor;
export 'src/memory_anchor.dart' show MemoryAnchor;
export 'src/platform_anchor.dart' show PlatformAnchor;
