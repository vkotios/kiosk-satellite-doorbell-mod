import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'doorbell_signature.dart';
import 'doorbell_status.dart';

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

/// The doorbell feature: the saved doorbells and the rings it answers,
/// in two independent sections.
///
/// The manager keeps the list of saved doorbells (signatures) and
/// pushes each section's share to the native listener: the
/// notification doorbells while doorbell.enabled is on, so it
/// recognises a ring notification from one of them and reports it
/// here, and the sensor & tap doorbells' packages while
/// doorbell.sensor_enabled is on, so its click service runs for them.
/// A notification ring is answered by opening the notification's own
/// tap action through openNotificationAction with the notification
/// section's return setting; a Home Assistant entity rings a doorbell
/// through ringFromEntity, which launches the doorbell's app and
/// clicks its card through openAppAndClick with the sensor section's
/// return setting. The Home Assistant event kiosk_satellite_doorbell
/// is published after each. The manager also runs the captures the add
/// flows use: the capturing and captured notifiers and the start and
/// stop commands, and remembers each doorbell's last activity for the
/// status text both Doorbell UIs show. Commands list, add, update,
/// remove and test open the saved doorbells.
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

  /// The clock the dedupe window and the activity times read; the
  /// tests set it.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// When each doorbell last opened, to ignore a ring of the same one
  /// within the dedupe window.
  final Map<String, DateTime> _opened = {};

  /// The doorbell id each package and click label last opened, so a
  /// click result can find the doorbell it belongs to.
  final Map<String, String> _clickRings = {};

  /// The last activity of each saved doorbell id, loaded from the
  /// doorbellActivity setting at init and written back on every save.
  Map<String, DoorbellActivity> _activity = {};

  /// The future of the last open by click: a click result the native
  /// side pushes from inside the launch call awaits it, so its
  /// click_failed event lands after the ringing event of that open.
  Future<void>? _opening;

  /// The window a ring of a doorbell is ignored over after it opened:
  /// never shorter than the old 20 seconds, and always long enough to
  /// cover the click wait: the delay, the 15 second search window and
  /// a margin.
  int get _dedupeSeconds {
    final delay = _settings.get(defs.doorbellClickDelaySeconds).toInt();
    final clickWait = delay + 15 + 5;
    return clickWait > 20 ? clickWait : 20;
  }

  /// Whether [id] opened less than [_dedupeSeconds] ago.
  bool _recentlyOpened(String id) {
    final last = _opened[id];
    return last != null &&
        clock().difference(last).inSeconds < _dedupeSeconds;
  }

  /// Record that [id] opened now, starting its dedupe window.
  void _recordOpened(String id) {
    _opened[id] = clock();
  }

  static const _channel = MethodChannel('kiosk_satellite/doorbell');

  @override
  String get name => 'doorbell';

  @override
  Future<void> init() async {
    _activity =
        decodeDoorbellActivity(_settings.get(defs.doorbellActivity));
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
            'The saved doorbells: [{id, label, package, channelPrefix, '
            'kind, statusText, state}], with the optional keys entity, '
            'open and clickLabel; kind is notification or sensor.',
        handler: (_) async => CommandResult.ok([
          for (final signature in _signatures)
            {
              ...signature.toJson(),
              'kind': signature.isSensor ? 'sensor' : 'notification',
              'statusText': doorbellStatusText(
                signature,
                _activity[signature.id],
              ),
              'state': doorbellState(signature, _activity[signature.id]),
            },
        ]),
      ),
    );

    commands.register(
      Command(
        name: 'doorbellAddSignature',
        description: 'Save a doorbell to answer rings from: '
            '{label, package, channelPrefix, entity, open, clickLabel}; '
            'an entity makes it a sensor & tap doorbell, a channel '
            'prefix a notification doorbell.',
        params: const {
          'label': 'What the UI shows, e.g. Eufy Security',
          'package': 'The Android package the rings come from',
          'channelPrefix': 'What a ring notification channel id starts with',
          'entity': 'The Home Assistant entity that rings',
          'open': 'Ignored: a sensor & tap doorbell opens by the click, '
              'a notification doorbell by the tap',
          'clickLabel': 'The card a sensor & tap doorbell opens',
        },
        handler: (p) async {
          final label = '${p['label'] ?? ''}'.trim();
          final package = '${p['package'] ?? ''}'.trim();
          final channelPrefix = '${p['channelPrefix'] ?? ''}'.trim();
          final rawEntity = '${p['entity'] ?? ''}'.trim();
          final entity = normalizeDoorbellEntity(rawEntity) ?? '';
          if (rawEntity.isNotEmpty && entity.isEmpty) {
            return const CommandResult.fail(_badEntity);
          }
          final clickLabel = '${p['clickLabel'] ?? ''}'.trim();
          final signatures = _signatures;
          // The entity decides the section: a sensor & tap doorbell
          // opens by the click and keeps no notification channel, a
          // notification doorbell opens by the tap and keeps no card.
          final signature = DoorbellSignature(
            id: _uniqueId(label, signatures),
            label: label,
            package: package,
            channelPrefix: entity.isEmpty ? channelPrefix : '',
            entity: entity,
            open: entity.isEmpty ? 'tap' : 'click',
            clickLabel: entity.isEmpty ? '' : clickLabel,
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
          // A removed doorbell has no status left to show.
          if (_activity.remove(id) != null) {
            await _settings.set(
              defs.doorbellActivity,
              encodeDoorbellActivity(_activity),
            );
          }
          return const CommandResult.ok();
        },
      ),
    );

    commands.register(
      Command(
        name: 'doorbellUpdateSignature',
        description: 'Change a saved doorbell: {id, and any of label, '
            'channelPrefix, entity, open, clickLabel}; a key left out '
            'keeps its value, and the entity decides the section.',
        params: const {
          'id': 'The signature id from doorbellSignatures',
          'label': 'What the UI shows, e.g. Eufy Security',
          'channelPrefix': 'What a ring notification channel id starts with',
          'entity': 'The Home Assistant entity that rings',
          'open': 'Ignored: a sensor & tap doorbell opens by the click, '
              'a notification doorbell by the tap',
          'clickLabel': 'The card a sensor & tap doorbell opens',
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
          var entity = saved.entity;
          if (p.containsKey('entity')) {
            final rawEntity = '${p['entity'] ?? ''}'.trim();
            entity = normalizeDoorbellEntity(rawEntity) ?? '';
            if (rawEntity.isNotEmpty && entity.isEmpty) {
              return const CommandResult.fail(_badEntity);
            }
          }
          // The entity decides the section: a sensor & tap doorbell
          // opens by the click and keeps no notification channel, a
          // notification doorbell opens by the tap and keeps no card.
          final merged = DoorbellSignature(
            id: saved.id,
            label: field('label', saved.label),
            package: saved.package,
            channelPrefix:
                entity.isEmpty ? field('channelPrefix', saved.channelPrefix) : '',
            entity: entity,
            open: entity.isEmpty ? 'tap' : 'click',
            clickLabel:
                entity.isEmpty ? '' : field('clickLabel', saved.clickLabel),
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
          if (!_settings.get(defs.doorbellSensorEnabled)) {
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

    commands.register(
      Command(
        name: 'doorbellTestOpen',
        description: 'Open a saved doorbell the way a click ring would: '
            '{id}.',
        params: const {'id': 'The signature id from doorbellSignatures'},
        handler: (p) async {
          if (!_settings.get(defs.doorbellSensorEnabled)) {
            return const CommandResult.fail('the doorbell setting is off');
          }
          final id = '${p['id'] ?? ''}'.trim();
          DoorbellSignature? saved;
          for (final signature in _signatures) {
            if (signature.id == id) saved = signature;
          }
          if (saved == null) {
            return const CommandResult.fail('no such doorbell');
          }
          if (saved.clickLabel.isEmpty) {
            return const CommandResult.fail(
              'this doorbell has no click label',
            );
          }
          if (clickCapturing.value) {
            return const CommandResult.fail(
              'a camera is being taught, try again when it ends',
            );
          }
          await commands.execute('screenOn', const {});
          return _openByClick(saved);
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
        } else if (call.method == 'clickResult') {
          final package = '${args['package'] ?? ''}';
          final label = '${args['label'] ?? ''}';
          final result = '${args['result'] ?? ''}';
          log.info(name, "click '$label': $result");
          // The click is matched by package and label: two doorbells
          // can share a click label.
          final key = package.isEmpty ? label : '$package\n$label';
          final id = _clickRings[key];
          String? doorbell;
          if (id != null) {
            for (final signature in _signatures) {
              if (signature.id == id) doorbell = signature.label;
            }
            await _saveActivity(id, 'ring', result, '');
          }
          if (result != 'clicked') {
            // A result the native side pushes from inside the launch
            // call would land before the ringing event of that open:
            // wait for the open, then a turn, so the ringing publish
            // runs first.
            final opening = _opening;
            if (opening != null) {
              try {
                await opening;
              } catch (e) {
                log.warn(name, 'could not wait for the open: $e');
              }
              await Future<void>.delayed(Duration.zero);
            }
            bus.publish(HaEventRequested('kiosk_satellite_doorbell', {
              'event_type': 'click_failed',
              'doorbell': doorbell ?? label,
              'label': label,
              'reason': result,
            }));
          }
        } else if (call.method == 'clickCaptureEnded') {
          final reason = '${args['reason'] ?? ''}';
          log.info(name, "click capture ended: $reason");
          _setClickCapturing(false);
          // The kiosk went to the background for the teach; a caught
          // card already brings it back, and so does any other end.
          if (reason != 'caught') {
            unawaited(commands.execute('bringToFront', const {}));
          }
        }
      }
      return null;
    });
    _settingSub = bus.on<SettingChanged>().listen((e) {
      if (e.key == defs.doorbellEnabled.key ||
          e.key == defs.doorbellSensorEnabled.key ||
          e.key == defs.doorbellSignatures.key) {
        // Turning a section's switch off ends that section's running
        // capture.
        if (e.key == defs.doorbellEnabled.key && e.value != true) {
          if (capturing.value) {
            unawaited(_stopCapture());
            _setCaptured(null);
          }
        }
        if (e.key == defs.doorbellSensorEnabled.key && e.value != true) {
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
  /// either way, and bring the kiosk back from the doorbell app the
  /// teach opened. The stop command and the setting-off listener both
  /// come here.
  Future<void> _stopClickCapture() async {
    try {
      await _channel.invokeMethod('stopClickCapture', <String, Object?>{});
    } catch (e) {
      log.warn(name, 'could not stop the click capture: $e');
    }
    _setClickCapturing(false);
    // The kiosk went to the background for the teach; come back now
    // it ended.
    unawaited(commands.execute('bringToFront', const {}));
  }

  /// Tell the native listener which doorbells to answer, per section:
  /// the notification doorbells while the notification switch is on,
  /// then the packages of the sensor & tap doorbells while the sensor
  /// switch is on. An empty list makes that side ignore every ring.
  Future<void> _pushConfiguration() async {
    final signatures =
        decodeDoorbellSignatures(_settings.get(defs.doorbellSignatures));
    try {
      await _channel.invokeMethod('configure', {
        'signatures': [
          if (_settings.get(defs.doorbellEnabled))
            for (final signature in signatures)
              if (signature.isNotification) signature.toJson(),
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
          if (_settings.get(defs.doorbellSensorEnabled))
            for (final signature in signatures)
              if (signature.isSensor) signature.package,
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

  /// The entity watcher calls this when a doorbell's Home Assistant
  /// entity turns on: wake the screen, open the doorbell by click and
  /// tell Home Assistant. A second ring of the same doorbell within
  /// the dedupe window is ignored, and so is one while the sensor &
  /// tap section's switch is off or a camera is being taught.
  Future<void> ringFromEntity(String id) async {
    DoorbellSignature? saved;
    for (final signature in _signatures) {
      if (signature.id == id && signature.rungByEntity) saved = signature;
    }
    if (saved == null) return;
    if (!_settings.get(defs.doorbellSensorEnabled)) {
      log.info(
        name,
        "ring from '${saved.entity}' ignored: the doorbell setting is off",
      );
      return;
    }
    if (clickCapturing.value) {
      log.info(
        name,
        "ring from '${saved.entity}' ignored while a camera is being taught",
      );
      return;
    }
    if (_recentlyOpened(saved.id)) {
      log.info(
        name,
        "ring from '${saved.entity}' ignored: it opened within "
        "$_dedupeSeconds s",
      );
      return;
    }
    _recordOpened(saved.id);
    if (_settings.get(defs.lockdownEnabled)) {
      log.info(
        name,
        "ring from '${saved.entity}' not opened: lockdown holds",
      );
      bus.publish(HaEventRequested('kiosk_satellite_doorbell', {
        'event_type': 'ringing',
        'doorbell': saved.label,
        'label': saved.label,
        'opened': false,
        'trigger': 'entity',
        'open': 'click',
      }));
      return;
    }
    await commands.execute('screenOn', const {});
    final result = await _openByClick(saved);
    bus.publish(HaEventRequested('kiosk_satellite_doorbell', {
      'event_type': 'ringing',
      'doorbell': saved.label,
      'label': saved.label,
      'opened': result.ok,
      'trigger': 'entity',
      'open': 'click',
    }));
  }

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

  static const _badEntity =
      'the entity must look like binary_sensor.front_door';

  /// Why [signature] cannot be saved, null when it can: a doorbell
  /// needs a label and a package, and then what its section needs: a
  /// notification doorbell a notification channel, a sensor & tap
  /// doorbell a card label (its entity is what makes it one).
  String? _problem(DoorbellSignature signature) {
    if (signature.label.isEmpty || signature.package.isEmpty) {
      return 'label and package are required';
    }
    if (signature.isSensor) {
      if (signature.clickLabel.isEmpty) {
        return 'a sensor doorbell needs a card label';
      }
    } else if (signature.channelPrefix.isEmpty) {
      return 'a notification doorbell needs a notification channel';
    }
    return null;
  }

  /// Record a doorbell's last activity and write it to the setting:
  /// the map keeps at most 50 doorbells with the most recent last,
  /// and ids that are no longer saved are dropped.
  Future<void> _saveActivity(
    String id,
    String kind,
    String result,
    String detail,
  ) async {
    _activity.remove(id);
    _activity[id] = DoorbellActivity(
      at: clock(),
      kind: kind,
      result: result,
      detail: detail,
    );
    final ids = {for (final signature in _signatures) signature.id};
    _activity.removeWhere((savedId, _) => !ids.contains(savedId));
    while (_activity.length > 50) {
      _activity.remove(_activity.keys.first);
    }
    await _settings.set(
      defs.doorbellActivity,
      encodeDoorbellActivity(_activity),
    );
  }

  /// Open [s] the way a sensor & tap ring does: launch its app and
  /// click its card, remembering the click so a later click result can
  /// find the doorbell it belongs to. The kiosk comes back after the
  /// sensor section's return setting, but never before the click could
  /// land: the delay plus the 15 second search window plus a margin.
  /// The run also completes [_opening], which a click result pushed
  /// from inside the launch call awaits, so the click_failed event
  /// lands after the ringing one. A launch that did not start records
  /// the doorbell's last activity as a launch failure: no click
  /// result will arrive for it.
  Future<CommandResult> _openByClick(DoorbellSignature s) async {
    final opening = Completer<void>();
    _opening = opening.future;
    try {
      final delay = _settings.get(defs.doorbellClickDelaySeconds).toInt();
      var returnAfter =
          _settings.get(defs.doorbellSensorReturnSeconds).toInt();
      final clickWait = delay + 15 + 10;
      if (returnAfter < clickWait) returnAfter = clickWait;
      _clickRings['${s.package}\n${s.clickLabel}'] = s.id;
      log.info(
        name,
        "doorbell '${s.label}': opening by click, tap after ${delay}s",
      );
      final result = await commands.execute('openAppAndClick', {
        'package': s.package,
        'label': s.clickLabel,
        'delaySeconds': delay,
        'returnAfterSeconds': returnAfter,
      });
      if (!result.ok) {
        log.warn(
          name,
          "doorbell '${s.label}' not opened by click: ${result.error}",
        );
        await _saveActivity(
          s.id,
          'ring',
          'launch_failed',
          result.error ?? '',
        );
      }
      return result;
    } finally {
      opening.complete();
    }
  }

  /// The native listener reports a ring notification here. Only the
  /// notification section answers: a ring while its switch is off, a
  /// ring while a camera is being taught and a ring of a sensor &
  /// tap doorbell are ignored. The ring opens the notification's own
  /// tap action with the notification section's return setting, and
  /// the doorbell's last activity records whether that opened.
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
    if (clickCapturing.value) {
      log.info(
        name,
        "ring '$title' ignored while a camera is being taught",
      );
      return;
    }

    // Tell Home Assistant a doorbell rang, naming the saved signature the
    // ring came from when there is one, so an automation can say which.
    // The open key says how the ring was opened: the saved doorbell's
    // way when nothing was opened for this ring.
    void publish(bool opened, [String? open]) {
      var label = title;
      var savedOpen = 'tap';
      for (final signature in decodeDoorbellSignatures(
        _settings.get(defs.doorbellSignatures),
      )) {
        if (signature.id == signatureId) {
          label = signature.label;
          savedOpen = signature.open;
        }
      }
      bus.publish(HaEventRequested('kiosk_satellite_doorbell', {
        'event_type': 'ringing',
        'doorbell': title,
        'label': label,
        'opened': opened,
        'trigger': 'notification',
        'open': open ?? savedOpen,
      }));
    }

    DoorbellSignature? saved;
    for (final signature in _signatures) {
      if (signature.id == signatureId) saved = signature;
    }
    // A sensor & tap doorbell rings from its entity, not from a
    // notification: the native side is never told its channel, and a
    // ring that slips through anyway is not answered.
    if (saved != null && saved.isSensor) {
      log.info(
        name,
        "ring '$title' ignored: '${saved.label}' rings from its entity",
      );
      return;
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
    if (saved != null) {
      await _saveActivity(
        saved.id,
        'ring',
        result.ok ? 'opened' : 'not_opened',
        result.ok ? '' : (result.error ?? ''),
      );
    }
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
