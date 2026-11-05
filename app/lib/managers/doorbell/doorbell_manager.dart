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

/// One click the native side caught while a click capture ran: the app
/// it came from and the label of the card it found on it.
class DoorbellClickCapture {
  const DoorbellClickCapture({
    required this.package,
    required this.label,
  });

  final String package;
  final String label;
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

  /// Whether a click capture is running; the capture UI listens.
  final clickCapturing = ValueNotifier<bool>(false);

  /// The click the running capture caught, null until one does.
  final clickCaptured = ValueNotifier<DoorbellClickCapture?>(null);

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
            '{label, package, channelPrefix, entity, open, clickLabel}.',
        params: const {
          'label': 'What the UI shows, e.g. Eufy Security',
          'package': 'The Android package the rings come from',
          'channelPrefix': 'What a ring notification channel id starts with',
          'entity': 'The Home Assistant entity that rings',
          'open': "How a ring opens: 'tap' or 'click'",
          'clickLabel': 'The card a click ring opens',
        },
        handler: (p) async {
          final label = '${p['label'] ?? ''}'.trim();
          final package = '${p['package'] ?? ''}'.trim();
          final channelPrefix = '${p['channelPrefix'] ?? ''}'.trim();
          final entity = '${p['entity'] ?? ''}'.trim();
          final open =
              '${p['open'] ?? ''}'.trim() == 'click' ? 'click' : 'tap';
          final clickLabel = '${p['clickLabel'] ?? ''}'.trim();
          final signatures = _signatures;
          final signature = DoorbellSignature(
            id: _uniqueId(label, signatures),
            label: label,
            package: package,
            channelPrefix: channelPrefix,
            entity: entity,
            open: open,
            clickLabel: clickLabel,
          );
          final problem = _problem(signature);
          if (problem != null) return CommandResult.fail(problem);
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

    commands.register(
      Command(
        name: 'doorbellUpdateSignature',
        description: 'Change a saved doorbell: {id, and any of label, '
            'channelPrefix, entity, open, clickLabel}; a key left out '
            'keeps its value.',
        params: const {
          'id': 'The signature id from doorbellSignatures',
          'label': 'What the UI shows, e.g. Eufy Security',
          'channelPrefix': 'What a ring notification channel id starts with',
          'entity': 'The Home Assistant entity that rings',
          'open': "How a ring opens: 'tap' or 'click'",
          'clickLabel': 'The card a click ring opens',
        },
        handler: (p) async {
          final id = '${p['id'] ?? ''}'.trim();
          final signatures = _signatures;
          final index = signatures.indexWhere(
            (signature) => signature.id == id,
          );
          if (index < 0) {
            return const CommandResult.fail('no such doorbell');
          }
          final saved = signatures[index];
          String field(String key, String current) =>
              p.containsKey(key) ? '${p[key] ?? ''}'.trim() : current;
          var open = saved.open;
          if (p.containsKey('open')) {
            open = '${p['open'] ?? ''}'.trim() == 'click' ? 'click' : 'tap';
          }
          final merged = DoorbellSignature(
            id: saved.id,
            label: field('label', saved.label),
            package: saved.package,
            channelPrefix: field('channelPrefix', saved.channelPrefix),
            entity: field('entity', saved.entity),
            open: open,
            clickLabel: field('clickLabel', saved.clickLabel),
          );
          final problem = _problem(merged);
          if (problem != null) return CommandResult.fail(problem);
          signatures[index] = merged;
          await _settings.set(
            defs.doorbellSignatures,
            encodeDoorbellSignatures(signatures),
          );
          return CommandResult.ok(merged.toJson());
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellClickAccess',
        description: 'Whether the Doorbell click access service runs.',
        handler: (_) async =>
            CommandResult.ok({'running': await _clickServiceRunning()}),
      ),
    );

    commands.register(
      Command(
        name: 'doorbellOpenClickSettings',
        description: 'Open the Android settings page for the click '
            'access.',
        handler: (_) async {
          await _channel.invokeMethod('openClickSettings');
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellStartClickCapture',
        description: 'Open the doorbell app and capture the card to '
            'click for 90 seconds: {package}.',
        params: const {
          'package': 'The Android package of the doorbell app',
        },
        handler: (p) async {
          if (!_settings.get(defs.doorbellEnabled)) {
            return const CommandResult.fail('the doorbell setting is off');
          }
          final package = '${p['package'] ?? ''}'.trim();
          if (package.isEmpty) {
            return const CommandResult.fail('package required');
          }
          if (!await _clickServiceRunning()) {
            return const CommandResult.fail(
              'enable Doorbell click access first',
            );
          }
          _setClickCaptured(null);
          _setClickCapturing(true);
          try {
            final started = await _channel.invokeMethod<bool>(
              'startClickCapture',
              {'package': package, 'seconds': 90},
            );
            if (started != true) {
              _setClickCapturing(false);
              return const CommandResult.fail('could not open the app');
            }
          } catch (_) {
            _setClickCapturing(false);
            return const CommandResult.fail('could not open the app');
          }
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellStopClickCapture',
        description: 'Stop the running doorbell click capture.',
        handler: (_) async {
          await _stopClickCapture();
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
        } else if (call.method == 'clickCaptured') {
          _setClickCaptured(
            DoorbellClickCapture(
              package: '${args['package'] ?? ''}',
              label: '${args['label'] ?? ''}',
            ),
          );
          // The kiosk went to the background for the click capture; come
          // back over the doorbell app so the user sees the card.
          unawaited(commands.execute('bringToFront', const {}));
        } else if (call.method == 'clickCaptureEnded') {
          log.info(name, "click capture ended: ${args['reason'] ?? ''}");
          _setClickCapturing(false);
        }
      }
      return null;
    });
    _settingSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.doorbellEnabled.key ||
          e.key == defs.doorbellSignatures.key) {
        // Turning the setting off ends a running capture.
        if (e.key == defs.doorbellEnabled.key && e.value != true) {
          if (capturing.value) {
            unawaited(_stopCapture());
            _setCaptured(null);
          }
          if (clickCapturing.value) {
            unawaited(_stopClickCapture());
            _setClickCaptured(null);
          }
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

  /// Assign [clickCapturing] unless [dispose] has already closed the
  /// notifier.
  void _setClickCapturing(bool value) {
    if (_disposed) return;
    clickCapturing.value = value;
  }

  /// Assign [clickCaptured] unless [dispose] has already closed the
  /// notifier.
  void _setClickCaptured(DoorbellClickCapture? value) {
    if (_disposed) return;
    clickCaptured.value = value;
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

  /// Whether the native click service runs, false when the native
  /// side cannot say so: no plugin, or a platform error.
  Future<bool> _clickServiceRunning() async {
    try {
      return await _channel.invokeMethod<bool>('clickServiceRunning') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Stop a running click capture: tell the native side and clear the
  /// flag whether or not that worked, since the capture is over
  /// either way. The stop command and the setting-off listener both
  /// come here.
  Future<void> _stopClickCapture() async {
    try {
      await _channel.invokeMethod('stopClickCapture', <String, Object?>{});
    } catch (e) {
      log.warn(name, 'could not stop the click capture: $e');
    }
    _setClickCapturing(false);
  }

  /// Tell the native listener which doorbells to answer: the saved
  /// signatures a notification can ring, then the packages of the ones
  /// a click or a Home Assistant entity opens. An empty list while the
  /// setting is off makes it ignore every ring.
  Future<void> _pushConfiguration() async {
    final signatures = _settings.get(defs.doorbellEnabled)
        ? decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures))
        : const <DoorbellSignature>[];
    try {
      await _channel.invokeMethod('configure', {
        'signatures': [
          for (final signature in signatures)
            if (signature.rungByNotification) signature.toJson(),
        ],
      });
    } on MissingPluginException {
      log.warn(name, 'could not push the doorbell configuration');
    } on PlatformException catch (e) {
      log.warn(name, 'could not push the doorbell configuration: $e');
    } catch (e) {
      log.warn(name, 'could not push the doorbell configuration: $e');
    }
    try {
      await _channel.invokeMethod('configureClick', {
        'packages': {
          for (final signature in signatures)
            if (signature.opensByClick || signature.rungByEntity)
              signature.package,
        }.toList(),
      });
    } on MissingPluginException {
      log.warn(name, 'could not push the doorbell click configuration');
    } on PlatformException catch (e) {
      log.warn(name, 'could not push the doorbell click configuration: '
          '$e');
    } catch (e) {
      log.warn(name, 'could not push the doorbell click configuration: '
          '$e');
    }
  }

  /// The saved doorbell signatures, decoded fresh so changes apply live.
  /// A growable copy: the decoder returns an unmodifiable list when the
  /// setting holds garbage, and the add and remove commands mutate it.
  List<DoorbellSignature> get _signatures => List<DoorbellSignature>.of(
    decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures)),
  );

  /// The saved doorbells; the entity watcher reads this to ring them.
  List<DoorbellSignature> get doorbells => _signatures;

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

  /// Why [signature] cannot be saved, null when it can: a doorbell
  /// needs a label and a package, something to ring it (a notification
  /// channel or a Home Assistant entity), and a click label whenever a
  /// Home Assistant entity rings it or a ring opens by a click.
  String? _problem(DoorbellSignature signature) {
    if (signature.label.isEmpty || signature.package.isEmpty) {
      return 'label and package are required';
    }
    if (signature.channelPrefix.isEmpty && signature.entity.isEmpty) {
      return 'a doorbell needs a notification channel or a Home Assistant '
          'entity';
    }
    if (signature.entity.isNotEmpty && signature.clickLabel.isEmpty) {
      return 'a Home Assistant ring needs a click label';
    }
    if (signature.open == 'click' && signature.clickLabel.isEmpty) {
      return 'a click doorbell needs a click label';
    }
    return null;
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
    clickCapturing.dispose();
    clickCaptured.dispose();
  }
}
