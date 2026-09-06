/// Public re-export of the SDK-internal logger so kernel + features can
/// use the same tagged Logger / LogLevel as the SDK without duplicating
/// the implementation. The full definition lives in
/// `lib/sdk/_internal/logger.dart` (SDK boundary lockdown 2026-05-13);
/// this file is a thin re-export to keep existing
/// `package:ilink/kernel/logging/logger.dart` callers working.
library;

export 'package:ilink/sdk/_internal/logger.dart' show Logger, LogLevel;
