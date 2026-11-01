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

/// The doorbell feature: the saved doorbells and the rings it answers.
///
/// The manager keeps the list of saved doorbells (signatures) and pushes
/// it to the native listener, which recognises a ring notification from
/// one of them and reports it here. A ring is answered by opening the
/// notification's own tap action through openNotificationAction, with the
/// doorbell's own return time, and the Home Assistant event
/// kiosk_satellite_doorbell is published after it. The manager also runs
/// the capture the signature picker uses: the capturing and captured
/// notifiers and the start and stop commands. Commands list, add and
/// remove the saved doorbells.
class DoorbellManager extends Manager {
  DoorbellManager(super.bus, super.commands, super.log, this._settings);

  final SettingsManager _settings;

  /// Whether a notification capture is running; the capture UI listens.
  final capturing = ValueNotifier<bool>(false);

  /// The notification the running capture caught, null until one does.
  final captured = ValueNotifier<DoorbellCapture?>(null);

  /// True from the start of [dispose]: the notifiers are closed there, so
  /// nothing may be assigned to them afterwards.
  bool _disposed = false;

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
          _setCaptured(null);
          _setCapturing(true);
          try {
            await _channel.invokeMethod('startCapture', {'seconds': 60});
          } catch (e) {
            _setCapturing(false);
            return CommandResult.fail('could not start capture: $e');
          }
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellStopCapture',
        description: 'Stop the running doorbell notification capture.',
        handler: (_) async {
          await _stopCapture();
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
          _setCaptured(
            DoorbellCapture(
              package: '${args['package'] ?? ''}',
              channelId: '${args['channelId'] ?? ''}',
              channelPrefix: '${args['channelPrefix'] ?? ''}',
              title: '${args['title'] ?? ''}',
              appLabel: '${args['appLabel'] ?? ''}',
            ),
          );
        } else if (call.method == 'captureEnded') {
          log.info(name, "capture ended: ${args['reason'] ?? ''}");
          _setCapturing(false);
        }
      }
      return null;
    });
    _settingSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.doorbellEnabled.key ||
          e.key == defs.doorbellSignatures.key) {
        // Turning the setting off ends a running capture.
        if (e.key == defs.doorbellEnabled.key &&
            e.value != true &&
            capturing.value) {
          unawaited(_stopCapture());
          _setCaptured(null);
        }
        unawaited(_pushConfiguration());
      }
    });
    await _pushConfiguration();
  }

  /// Assign [capturing] unless [dispose] has already closed the notifier.
  void _setCapturing(bool value) {
    if (_disposed) return;
    capturing.value = value;
  }

  /// Assign [captured] unless [dispose] has already closed the notifier.
  void _setCaptured(DoorbellCapture? value) {
    if (_disposed) return;
    captured.value = value;
  }

  /// Stop a running capture: tell the native side and clear the flag
  /// whether or not that worked, since the capture is over either way.
  /// The stop command and the setting-off listener both come here.
  Future<void> _stopCapture() async {
    try {
      await _channel.invokeMethod('stopCapture', <String, Object?>{});
    } catch (e) {
      log.warn(name, 'could not stop the doorbell capture: $e');
    }
    _setCapturing(false);
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
    } catch (e) {
      log.warn(name, 'could not push the doorbell configuration: $e');
    }
  }

  /// The saved doorbell signatures, decoded fresh so changes apply live.
  /// A growable copy: the decoder returns an unmodifiable list when the
  /// setting holds garbage, and the add and remove commands mutate it.
  List<DoorbellSignature> get _signatures => List<DoorbellSignature>.of(
    decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures)),
  );

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

    // Tell Home Assistant a doorbell rang, naming the saved signature the
    // ring came from when there is one, so an automation can say which.
    void publish(bool opened) {
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
        'opened': opened,
      }));
    }

    if (_settings.get(defs.lockdownEnabled)) {
      log.info(name, "ring '$title' not opened: lockdown holds");
      publish(false);
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
    publish(result.ok);
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _settingSub?.cancel();
    _channel.setMethodCallHandler(null);
    capturing.dispose();
    captured.dispose();
  }
}
