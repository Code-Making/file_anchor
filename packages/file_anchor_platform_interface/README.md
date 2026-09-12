# file_anchor_platform_interface

The common platform interface for [`file_anchor`](../file_anchor). App authors
should depend on `file_anchor` instead.

Holds the pieces every implementation shares: `AnchorToken`, the sealed
`AnchorError` hierarchy, `AnchorCapabilities`, the entry models, and the
`FileAnchorPlatform` contract itself.

Platform methods default to throwing `UnimplementedError` rather than being
abstract, so adding an operation is not a breaking change for existing
implementations.

`channel_errors.dart` is the Dart side of a contract with native code: each
`AnchorErrorCode` string maps onto one case of `AnchorError`. The Kotlin and
Swift implementations declare the same strings. Change one side only and a typed
error silently degrades to a generic I/O failure.
