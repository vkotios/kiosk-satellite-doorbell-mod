import 'package:flutter/services.dart';

import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';

/// A doorbell that rings in another app (the Eufy Security app today).
///
/// The native listener (MediaSessionListener, through DoorbellBridge)
/// recognises the app's ring notification and reports it here. When the
/// setting is on, the ring is answered by firing that notification's own
/// tap action, which is what opens the camera that rang: each doorbell's
/// notification carries its own. The launch goes through KioskManager's
/// openNotificationAction, the same steps every other launch over the kiosk
/// takes, with the doorbell's own idle time so the launcher's auto-return
/// brings the kiosk back.
class DoorbellManager extends Manager {
  DoorbellManager(super.bus, super.commands, super.log, this._settings);

  final SettingsManager _settings;

  static const _channel = MethodChannel('kiosk_satellite/doorbell');

  @override
  String get name => 'doorbell';

  @override
  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (call.method == 'ring' && args is Map) {
        await _onRing(
          package: '${args['package'] ?? ''}',
          key: '${args['key'] ?? ''}',
          title: '${args['title'] ?? ''}',
        );
      }
      return null;
    });
  }

  Future<void> _onRing({
    required String package,
    required String key,
    required String title,
  }) async {
    if (key.isEmpty) return;
    if (!_settings.get(defs.doorbellEnabled)) {
      log.info(name, "ring '$title' ignored: the doorbell setting is off");
      return;
    }
    final seconds = _settings.get(defs.doorbellReturnSeconds).toInt();
    log.info(name, "ring '$title': opening it, back after ${seconds}s idle");
    // A dark panel or a screensaver would hide the camera it opens.
    await commands.execute('screenOn', const {});
    final result = await commands.execute('openNotificationAction', {
      'key': key,
      'package': package,
      'label': title,
      'returnAfterSeconds': seconds,
    });
    if (!result.ok) log.warn(name, "ring '$title' not opened: ${result.error}");
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
  }
}
