import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'doorbell_signature.dart';

/// One notification the native side caught while a capture ran: the app
/// it came from and the channel it arrived on. The signature picker turns
/// it into a saved signature.
class DoorbellCapture {
  const DoorbellCapture({
    required this.package,
    required this.channelId,
    required this.channelPrefix,
    required this.title,
    required this.appLabel,
  });

  final String package;
  final String channelId;
  final String channelPrefix;
  final String title;
  final String appLabel;
}

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

  /// Whether a notification capture is running; the capture UI listens.
  final capturing = ValueNotifier<bool>(false);

  /// The notification the running capture caught, null until one does.
  final captured = ValueNotifier<DoorbellCapture?>(null);

  StreamSubscription<SettingChanged>? _settingSub;

  static const _channel = MethodChannel('kiosk_satellite/doorbell');

  @override
  String get name => 'doorbell';

  @override
  Future<void> init() async {
    commands.register(
      Command(
        name: 'doorbellStartCapture',
        description: 'Catch the next doorbell notification for 60 '
            'seconds; the signature picker reads the result.',
        handler: (_) async {
          if (!_settings.get(defs.doorbellEnabled)) {
            return const CommandResult.fail('the doorbell setting is off');
          }
          captured.value = null;
          try {
            await _channel.invokeMethod('startCapture', {'seconds': 60});
          } catch (e) {
            return CommandResult.fail('could not start capture: $e');
          }
          capturing.value = true;
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellStopCapture',
        description: 'Stop the running doorbell notification capture.',
        handler: (_) async {
          await _channel.invokeMethod('stopCapture');
          capturing.value = false;
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellSignatures',
        description:
            'The saved doorbells: [{id, label, package, channelPrefix}].',
        handler: (_) async => CommandResult.ok(
          [for (final signature in _signatures) signature.toJson()],
        ),
      ),
    );

    commands.register(
      Command(
        name: 'doorbellAddSignature',
        description: 'Save a doorbell to answer rings from: '
            '{label, package, channelPrefix}.',
        params: const {
          'label': 'What the UI shows, e.g. Eufy Security',
          'package': 'The Android package the rings come from',
          'channelPrefix': 'What a ring notification channel id starts with',
        },
        handler: (p) async {
          final label = '${p['label'] ?? ''}'.trim();
          final package = '${p['package'] ?? ''}'.trim();
          final channelPrefix = '${p['channelPrefix'] ?? ''}'.trim();
          if (label.isEmpty || package.isEmpty || channelPrefix.isEmpty) {
            return const CommandResult.fail(
              'label, package and channelPrefix are required',
            );
          }
          final signatures = _signatures;
          final signature = DoorbellSignature(
            id: _uniqueId(label, signatures),
            label: label,
            package: package,
            channelPrefix: channelPrefix,
          );
          signatures.add(signature);
          await _settings.set(
            defs.doorbellSignatures,
            encodeDoorbellSignatures(signatures),
          );
          return CommandResult.ok(signature.toJson());
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellRemoveSignature',
        description: 'Forget a saved doorbell: {id}.',
        params: const {'id': 'The signature id from doorbellSignatures'},
        handler: (p) async {
          final id = '${p['id'] ?? ''}'.trim();
          final signatures = _signatures;
          final before = signatures.length;
          signatures.removeWhere((signature) => signature.id == id);
          if (signatures.length == before) {
            return const CommandResult.fail('no such doorbell');
          }
          await _settings.set(
            defs.doorbellSignatures,
            encodeDoorbellSignatures(signatures),
          );
          return const CommandResult.ok();
        },
      ),
    );

    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      if (args is Map) {
        if (call.method == 'ring') {
          await _onRing(
            package: '${args['package'] ?? ''}',
            key: '${args['key'] ?? ''}',
            title: '${args['title'] ?? ''}',
            signatureId: '${args['signatureId'] ?? ''}',
          );
        } else if (call.method == 'captured') {
          captured.value = DoorbellCapture(
            package: '${args['package'] ?? ''}',
            channelId: '${args['channelId'] ?? ''}',
            channelPrefix: '${args['channelPrefix'] ?? ''}',
            title: '${args['title'] ?? ''}',
            appLabel: '${args['appLabel'] ?? ''}',
          );
        } else if (call.method == 'captureEnded') {
          log.info(name, "capture ended: ${args['reason'] ?? ''}");
          capturing.value = false;
        }
      }
      return null;
    });
    await _pushConfiguration();
    _settingSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.doorbellEnabled.key ||
          e.key == defs.doorbellSignatures.key) {
        unawaited(_pushConfiguration());
      }
    });
  }

  /// Tell the native listener which doorbells to answer: the saved
  /// signatures, or an empty list while the setting is off, which makes
  /// it ignore every ring.
  Future<void> _pushConfiguration() async {
    final signatures = _settings.get(defs.doorbellEnabled)
        ? decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures))
        : const <DoorbellSignature>[];
    try {
      await _channel.invokeMethod('configure', {
        'signatures': [
          for (final signature in signatures) signature.toJson(),
        ],
      });
    } on MissingPluginException {
      log.warn(name, 'could not push the doorbell configuration');
    } on PlatformException catch (e) {
      log.warn(name, 'could not push the doorbell configuration: $e');
    }
  }

  /// The saved doorbell signatures, decoded fresh so changes apply live.
  List<DoorbellSignature> get _signatures =>
      decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures));

  /// The id a new signature gets: the label lowercased with every run of
  /// characters outside a-z0-9 collapsed into one '-', 'doorbell' when
  /// that leaves nothing.
  static String _idFromLabel(String label) {
    final id = label
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return id.isEmpty ? 'doorbell' : id;
  }

  /// [_idFromLabel]'s answer, with '-2', '-3', ... until no saved
  /// signature holds it.
  String _uniqueId(String label, List<DoorbellSignature> existing) {
    final id = _idFromLabel(label);
    final ids = {for (final signature in existing) signature.id};
    if (!ids.contains(id)) return id;
    var n = 2;
    while (ids.contains('$id-$n')) {
      n++;
    }
    return '$id-$n';
  }

  Future<void> _onRing({
    required String package,
    required String key,
    required String title,
    required String signatureId,
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
    // Tell Home Assistant a doorbell rang, naming the saved signature the
    // ring came from when there is one, so an automation can say which.
    var label = title;
    for (final signature in decodeDoorbellSignatures(
      _settings.get(defs.doorbellSignatures),
    )) {
      if (signature.id == signatureId) label = signature.label;
    }
    bus.publish(HaEventRequested('kiosk_satellite_doorbell', {
      'event_type': 'ringing',
      'doorbell': title,
      'label': label,
      'opened': result.ok,
    }));
  }

  @override
  Future<void> dispose() async {
    await _settingSub?.cancel();
    _channel.setMethodCallHandler(null);
    capturing.dispose();
    captured.dispose();
  }
}
