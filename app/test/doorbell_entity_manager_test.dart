import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_entity_manager.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_manager.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_signature.dart';
import 'package:kiosk_satellite/managers/home_assistant/home_assistant_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A doorbell rung by its Home Assistant entity: the watcher turns a
/// state into a ring, and only a turn on does. Home Assistant is left
/// unconfigured, so no socket opens; the entity's states are fed in as
/// the subscription would deliver them, and the doorbell manager is a
/// fake that records the rings.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const entity = 'binary_sensor.front_door_ringing';
  const other = 'binary_sensor.back_door_ringing';

  late EventBus bus;
  late CommandRegistry commands;
  late SettingsManager settings;
  late Logger log;
  late _FakeDoorbell doorbell;

  Future<void> build(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    bus = EventBus();
    log = Logger();
    commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    doorbell = _FakeDoorbell(bus, commands, log, settings);
  }

  DoorbellEntityManager manager() => DoorbellEntityManager(
    bus,
    commands,
    log,
    settings,
    HomeAssistantManager(bus, commands, log, settings),
    doorbell,
  );

  /// A saved doorbell the given entity rings.
  DoorbellSignature signature(String id, String entity) => DoorbellSignature(
    id: id,
    label: id,
    package: 'com.example.$id',
    entity: entity,
    clickLabel: 'Front door',
  );

  group('the entity watcher', () {
    late DoorbellEntityManager watcher;

    Future<void> start(List<DoorbellSignature> saved) async {
      await build({'ks.doorbell.sensor_enabled': true});
      doorbell.saved = saved;
      watcher = manager();
      await watcher.init();
      await pumpEventQueue();
    }

    tearDown(() => watcher.dispose());

    test('off then on rings the doorbell whose entity matches', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState(entity, 'off');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, ['front']);
    });

    test('an attribute-only update does not erase the stored state', () async {
      await start([signature('front', entity)]);
      watcher.applyStateMap(entity, const {'state': 'off'});
      watcher.applyStateMap(
        entity,
        const {'attributes': {'friendly_name': 'Front door'}},
      );
      watcher.applyStateMap(entity, const {'state': 'on'});
      await pumpEventQueue();
      expect(doorbell.rung, ['front']);
    });

    test('the first state on does not ring', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
    });

    test('on then on does not ring again', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, ['front']);
    });

    test('on then off then on rings again', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, ['front', 'front']);
    });

    test('unavailable then on does not ring', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'unavailable');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
    });

    test('a state for another entity does nothing', () async {
      await start([signature('front', entity)]);
      watcher.applyEntityState('binary_sensor.kitchen_motion', 'off');
      watcher.applyEntityState('binary_sensor.kitchen_motion', 'on');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
      expect(
        (await commands.execute('getDoorbellEntities', const {})).data,
        {'entities': {entity: null}},
      );
    });

    test('two doorbells with different entities ring only their own',
        () async {
      await start([signature('front', entity), signature('back', other)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      watcher.applyEntityState(other, 'off');
      watcher.applyEntityState(other, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, ['front', 'back']);
    });

    test('two doorbells sharing one entity both ring', () async {
      await start([signature('front', entity), signature('porch', entity)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, ['front', 'porch']);
    });

    test('a doorbell without an entity never rings', () async {
      await start([
        const DoorbellSignature(
          id: 'tap',
          label: 'Tap',
          package: 'com.example.tap',
          channelPrefix: 'com.example.tap.ring',
        ),
      ]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
    });

    test('watches nothing while the sensor switch is off', () async {
      await build({'ks.doorbell.enabled': true});
      doorbell.saved = [signature('front', entity)];
      watcher = manager();
      await watcher.init();
      await pumpEventQueue();
      expect(
        (await commands.execute('getDoorbellEntities', const {})).data,
        {'entities': {}},
      );
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(doorbell.rung, isEmpty);
    });

    test('getDoorbellEntities reports the states', () async {
      await start([signature('front', entity), signature('back', other)]);
      watcher.applyEntityState(entity, 'off');
      watcher.applyEntityState(other, 'unavailable');
      await pumpEventQueue();
      expect(
        (await commands.execute('getDoorbellEntities', const {})).data,
        {'entities': {entity: false, other: null}},
      );
      watcher.applyEntityState(entity, 'on');
      await pumpEventQueue();
      expect(
        (await commands.execute('getDoorbellEntities', const {})).data,
        {'entities': {entity: true, other: null}},
      );
    });
  });
}

/// The doorbell manager the watcher rings: the saved doorbells are
/// installed by the test, and ringFromEntity only records the ids, so no
/// channel is touched and no app opens.
class _FakeDoorbell extends DoorbellManager {
  _FakeDoorbell(super.bus, super.commands, super.log, super.settings);

  /// The saved doorbells, installed by the test.
  var saved = const <DoorbellSignature>[];

  /// The ids ringFromEntity was called with, in order.
  final List<String> rung = [];

  @override
  List<DoorbellSignature> get doorbells => saved;

  @override
  Future<void> ringFromEntity(String id) async => rung.add(id);
}
