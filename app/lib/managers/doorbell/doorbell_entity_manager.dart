import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/command_registry.dart';
import '../../core/events.dart';
import '../../core/manager.dart';
import '../home_assistant/home_assistant_manager.dart';
import '../settings/definitions.dart' as defs;
import '../settings/settings_manager.dart';
import 'doorbell_manager.dart';

/// A doorbell rung by a Home Assistant entity: the saved doorbells whose
/// entity turns on ring through DoorbellManager.ringFromEntity, which
/// wakes the screen, opens the doorbell app by click and tells Home
/// Assistant. The entities are watched over a subscription of this app's
/// own, open only while the sensor & tap section's switch is on and a
/// saved doorbell has an entity, so Home Assistant sends those entities
/// and nothing else.
///
/// A state rings the way the motion manager's entity moves: only a turn
/// on rings. The first state after the subscription opens never does
/// (the sensor was already on), and an unavailable or unknown state
/// stores no reading, so the next on does not ring either: a doorbell
/// that went on while nobody watched is treated as already on,
/// conservatively, rather than ringing for a visitor who may have left.
class DoorbellEntityManager extends Manager {
  DoorbellEntityManager(
    super.bus,
    super.commands,
    super.log,
    this._settings,
    this._ha,
    this._doorbell,
  );

  final SettingsManager _settings;
  final HomeAssistantManager _ha;
  final DoorbellManager _doorbell;

  @override
  String get name => 'doorbell-entity';

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  GlanceSubscription? _live;
  Set<String>? _liveEntities;
  Timer? _retry;
  bool _opening = false;

  /// Bumped on every close, so a subscription that finishes connecting
  /// after its owner moved on closes itself instead of taking over.
  int _generation = 0;

  /// Each watched entity's state: true on, false off, null before it
  /// reports, while it reads unavailable or unknown, and while nothing
  /// keeps it current.
  final Map<String, bool?> _state = {};

  /// Whether the last state an entity sent was neither on nor off, so
  /// the warning is logged once per run of bad states, not on every
  /// update.
  bool _warnedState = false;

  /// The entities to watch: the distinct entities of the saved doorbells
  /// a Home Assistant entity can ring, and only while the sensor &
  /// tap section's switch is on.
  Set<String> get _entities {
    if (!_settings.get(defs.doorbellSensorEnabled)) return {};
    return {
      for (final signature in _doorbell.doorbells)
        if (signature.rungByEntity) signature.entity,
    };
  }

  @override
  Future<void> init() async {
    _subscriptions.add(
      bus.on<SettingChanged>().listen((e) {
        // Another server or token: the open socket is the old one's.
        if (e.key == defs.haUrl.key || e.key == defs.haToken.key) _close();
        if (e.key == defs.doorbellSensorEnabled.key ||
            e.key == defs.doorbellSignatures.key ||
            e.key == defs.haUrl.key ||
            e.key == defs.haToken.key) {
          unawaited(_sync());
        }
      }),
    );

    commands.register(
      Command(
        name: 'getDoorbellEntities',
        description:
            'The Home Assistant entities that ring doorbells, and whether '
            'each reads on (null before it reports)',
        handler: (_) async => CommandResult.ok({
          'entities': {
            for (final entity in _entities) entity: _state[entity],
          },
        }),
      ),
    );

    // Not awaited: Home Assistant may take a while to answer.
    unawaited(_sync());
  }

  /// Open the entities' subscription when the doorbells want it, close
  /// it when not.
  Future<void> _sync() async {
    final entities = _entities;
    if (entities.isEmpty) {
      _close();
      return;
    }
    if (_liveEntities != null && setEquals(_liveEntities, entities)) {
      // Opening already, or open and alive.
      final current = _live;
      if (current == null ? _opening : !current.isClosed) return;
    }
    await _open(entities);
  }

  Future<void> _open(Set<String> entities) async {
    _close();
    final generation = _generation;
    _liveEntities = entities;
    _opening = true;
    final live = await _ha.subscribeEntities(entities.toList(), _onState);
    if (generation != _generation) {
      // Closed or reopened for other entities while this one connected.
      await live?.close();
      return;
    }
    _opening = false;
    if (live == null) {
      // Home Assistant not set up yet, unreachable or restarting: try
      // again shortly.
      _retryIn(const Duration(seconds: 20));
      return;
    }
    live.onClosed = () {
      if (_live != live) return;
      log.debug(name, 'subscription dropped; reopening');
      _live = null;
      // Nothing keeps the states current now: a sensor that went on
      // while the socket was down must not ring for it.
      _state.clear();
      _retryIn(const Duration(seconds: 5));
    };
    _live = live;
    log.debug(name, 'watching ${entities.join(', ')}');
  }

  void _retryIn(Duration delay) {
    _retry?.cancel();
    _retry = Timer(delay, () {
      _retry = null;
      _liveEntities = null;
      unawaited(_sync());
    });
  }

  void _close() {
    _generation++;
    _opening = false;
    _retry?.cancel();
    _retry = null;
    final live = _live;
    _live = null;
    _liveEntities = null;
    if (live != null) unawaited(live.close());
    _state.clear();
  }

  void _onState(String entityId, Map<String, Object?> state) =>
      applyStateMap(entityId, state);

  /// One update from the subscription: an attribute-only update carries
  /// no 'state' key, so it is not a reading and the stored state stands.
  @visibleForTesting
  void applyStateMap(String entityId, Map<String, Object?> state) {
    if (!state.containsKey('state')) return;
    applyEntityState(entityId, state['state']);
  }

  /// One state from the subscription: `on` rings the doorbells whose
  /// entity this is, but only a turn on does; anything else (unavailable,
  /// unknown) is no reading.
  @visibleForTesting
  void applyEntityState(String entityId, Object? state) {
    if (!_entities.contains(entityId)) return;
    final detected = switch ('$state') {
      'on' => true,
      'off' => false,
      _ => null,
    };
    if (detected == null) {
      if (!_warnedState) {
        _warnedState = true;
        log.warn(name, '$entityId reads "$state", not on or off');
      }
    } else {
      _warnedState = false;
    }
    // The first state after the subscription opens (previous null) never
    // rings: the sensor was already on. An unavailable or unknown state
    // stores null too, so the next on does not ring either: a doorbell
    // that went on while nobody watched is treated as already on,
    // conservatively, rather than ringing for a visitor who may have
    // left.
    final arrived = detected == true && _state[entityId] == false;
    _state[entityId] = detected;
    if (!arrived) return;
    log.info(name, 'ring from $entityId');
    for (final doorbell in _doorbell.doorbells) {
      if (doorbell.entity == entityId) {
        unawaited(_doorbell.ringFromEntity(doorbell.id));
      }
    }
  }

  @override
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _retry?.cancel();
    _retry = null;
    final live = _live;
    _live = null;
    await live?.close();
  }
}
