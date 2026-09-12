/// The sealed error hierarchy for all `file_anchor` operations.
///
/// Every failure surfaces as one of these. A platform implementation must never
/// let a raw `PlatformException` escape: consumers cannot write correct recovery
/// logic against a stringly-typed message.
///
/// Because this hierarchy is `sealed`, a `switch` over it is exhaustive and the
/// analyzer will tell you when a new case appears.
sealed class AnchorError implements Exception {
  const AnchorError(this.message, [this.cause]);

  /// Human-readable explanation, safe to log. Never contains file contents.
  final String message;

  /// The underlying platform error, if any.
  final Object? cause;

  @override
  String toString() =>
      cause == null ? '$runtimeType: $message' : '$runtimeType: $message ($cause)';
}

/// The anchor's target moved or was renamed, but access may be recoverable.
///
/// iOS can often repair a stale bookmark automatically. Prefer refreshing the
/// token over re-prompting the user.
final class AnchorStale extends AnchorError {
  const AnchorStale([super.message = 'The anchor is stale.', super.cause]);
}

/// The user revoked permission (for example in Android's Settings app).
///
/// There is no recovery: you must ask the user to pick the location again.
final class AnchorRevoked extends AnchorError {
  const AnchorRevoked([super.message = 'Access to the anchor was revoked.', super.cause]);
}

/// The target exists but is not reachable right now.
///
/// An ejected SD card, an unmounted network share, a detached USB drive. This is
/// deliberately distinct from [AnchorRevoked]: retry later, and do **not**
/// re-prompt the user. Conflating the two is why apps nag people to re-pick a
/// folder merely because a drive was unplugged.
final class AnchorUnavailable extends AnchorError {
  const AnchorUnavailable([super.message = 'The anchor is currently unavailable.', super.cause]);
}

/// The OS refused the operation outright.
final class AnchorPermissionDenied extends AnchorError {
  const AnchorPermissionDenied([super.message = 'Permission denied.', super.cause]);
}

/// The platform's limit on persisted grants was reached.
///
/// Android caps persistable URI permissions per app (commonly 128, 512 on newer
/// releases). Call `FileAnchor.releaseUnused()` to reap orphaned grants.
final class AnchorQuotaExceeded extends AnchorError {
  const AnchorQuotaExceeded([super.message = 'Persisted grant limit reached.', super.cause]);
}

/// No entry with that name exists inside the anchor.
final class AnchorEntryNotFound extends AnchorError {
  const AnchorEntryNotFound([super.message = 'Entry not found.', super.cause]);
}

/// The operation is not supported on this platform or for this anchor.
///
/// Check `Anchor.capabilities` before calling optional operations instead of
/// catching this.
final class AnchorUnsupported extends AnchorError {
  const AnchorUnsupported([super.message = 'Operation not supported here.', super.cause]);
}

/// The token string was not produced by this package, or its version is unknown.
final class AnchorTokenMalformed extends AnchorError {
  const AnchorTokenMalformed([super.message = 'Malformed anchor token.', super.cause]);
}

/// A read or write failed for a reason none of the above describes.
final class AnchorIoFailure extends AnchorError {
  const AnchorIoFailure([super.message = 'I/O failure.', super.cause]);
}
