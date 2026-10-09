import 'dart:io';

import 'api.dart';

/// Best-effort backend bring-up used at app start and on manual Retry.
///
/// Order: already healthy → spawn `localsearch-backend` from PATH and wait
/// for /health → give up and let the caller show the manual banner.
/// Never throws.
class BackendStart {
  static Future<bool> ensureRunning(
    SearchApi api, {
    Duration wait = const Duration(seconds: 60),
  }) async {
    if (await api.healthy()) return true;
    try {
      // Awaited: Process.start completes at spawn (not exit), so this
      // catches "no such binary" here instead of leaking an async error.
      await Process.start(
        'localsearch-backend',
        [],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      return false; // nothing installed to spawn with
    }
    final end = DateTime.now().add(wait);
    while (DateTime.now().isBefore(end)) {
      await Future.delayed(const Duration(seconds: 2));
      if (await api.healthy()) return true;
    }
    return false;
  }
}
