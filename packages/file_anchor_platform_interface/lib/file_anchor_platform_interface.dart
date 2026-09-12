/// The common platform interface for the `file_anchor` plugin.
///
/// App authors should depend on `file_anchor` instead. This package exists so
/// that platform implementations share one contract.
library;

export 'src/anchor_token.dart';
export 'src/capabilities.dart';
export 'src/channel_errors.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/platform.dart';
