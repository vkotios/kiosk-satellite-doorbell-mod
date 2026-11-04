import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_manager.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart'
    as defs;
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The doorbell manager (WP-DOORBELL): the configuration it pushes to the
/// native listener, the rings it answers, the notification capture the
/// signature picker reads, and the commands over the saved doorbells.
/// The native side is the mocked method channel; the commands a ring runs
/// (screenOn, openNotificationAction) are stubs that record their params.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('kiosk_satellite/doorbell');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late EventBus bus;
  late SettingsManager settings;
  late DoorbellManager doorbell;

  /// Every Dart-to-native call, in order.
  late List<MethodCall> nativeCalls;

  /// Every stubbed command call as (name, params), in order.
  late List<(String, Map<String, Object?>)> stubCalls;
  late List<HaEventRequested> haEvents;

  /// What the mocked native side throws on every call; null to answer null.
  Object? nativeError;
  late bool openFails;

  /// Whether the openAppAndClick stub fails its open.
  late bool clickOpenFails;

  /// Whether the mocked native click service reports itself running.
  late bool clickServiceRunning;

  const eufy = {
    'id': 'eufy',
    'label': 'Eufy Security',
    'package': 'com.oceanwing.battery.cam',
    'channelPrefix': 'com.ocean.battery.cam.ring',
  };
  const savedEufy =
      '[{"id":"eufy","label":"Eufy Security","package":"com.oceanwing.battery.cam",'
      '"channelPrefix":"com.ocean.battery.cam.ring"}]';
  const savedClickEufy =
      '[{"id":"eufy","label":"Eufy Security","package":"com.oceanwing.battery.cam",'
      '"channelPrefix":"com.ocean.battery.cam.ring",'
      '"open":"click","clickLabel":"Front door"}]';
  const savedTapEufyWithClick =
      '[{"id":"eufy","label":"Eufy Security","package":"com.oceanwing.battery.cam",'
      '"channelPrefix":"com.ocean.battery.cam.ring",'
      '"clickLabel":"Front door"}]';
  const savedEntityDoorbell =
      '[{"id":"ring","label":"Ring","package":"com.ring",'
      '"entity":"binary_sensor.front_door_ringing",'
      '"clickLabel":"Front door"}]';

  Future<void> build(
    Map<String, Object> initial, {
    Object? error,
    bool openNotificationFails = false,
    bool openClickFails = false,
  }) async {
    SharedPreferences.setMockInitialValues(initial);
    bus = EventBus();
    final log = Logger();
    final commands = CommandRegistry(log);
    settings = SettingsManager(bus, commands, log);
    await settings.init();
    nativeCalls = [];
    stubCalls = [];
    haEvents = [];
    nativeError = error;
    openFails = openNotificationFails;
    clickOpenFails = openClickFails;
    clickServiceRunning = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      final thrown = nativeError;
      if (thrown != null) throw thrown;
      switch (call.method) {
        case 'clickServiceRunning':
          return clickServiceRunning;
        case 'openClickSettings':
        case 'configureClick':
        case 'startClickCapture':
        case 'stopClickCapture':
          return true;
      }
      return null;
    });
    commands.register(
      Command(
        name: 'screenOn',
        description: 'stub',
        handler: (params) async {
          stubCalls.add(('screenOn', params));
          return const CommandResult.ok();
        },
      ),
    );
    commands.register(
      Command(
        name: 'openNotificationAction',
        description: 'stub',
        handler: (params) async {
          stubCalls.add(('openNotificationAction', params));
          return openFails
              ? const CommandResult.fail('x')
              : const CommandResult.ok();
        },
      ),
    );
    commands.register(
      Command(
        name: 'openAppAndClick',
        description: 'stub',
        handler: (params) async {
          stubCalls.add(('openAppAndClick', params));
          return clickOpenFails
              ? const CommandResult.fail('x')
              : const CommandResult.ok();
        },
      ),
    );
    commands.register(
      Command(
        name: 'bringToFront',
        description: 'stub',
        handler: (params) async {
          stubCalls.add(('bringToFront', params));
          return const CommandResult.ok();
        },
      ),
    );
    bus.on<HaEventRequested>().listen(haEvents.add);
    doorbell = DoorbellManager(bus, commands, log, settings);
    await doorbell.init();
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  List<String> stubNames() => [for (final call in stubCalls) call.$1];

  Map<String, Object?> stubParams(String name) =>
      stubCalls.firstWhere((call) => call.$1 == name).$2;

  /// The arguments of every 'configure' push, in order.
  List<Object?> configurePushes() => [
        for (final call in nativeCalls)
          if (call.method == 'configure') call.arguments,
      ];

  /// The arguments of every 'configureClick' push, in order.
  List<Object?> configureClickPushes() => [
        for (final call in nativeCalls)
          if (call.method == 'configureClick') call.arguments,
      ];

  Future<CommandResult> run(String name, [Map<String, Object?>? params]) =>
      doorbell.commands.execute(name, params ?? const {});

  /// The native side reports something, the way the platform would.
  Future<void> fromNative(String method, Map<String, Object?> args) async {
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (data) {
        if (data != null) {
          const StandardMethodCodec().decodeEnvelope(data);
        }
      },
    );
  }

  Future<void> ring({
    String package = 'com.oceanwing.battery.cam',
    String key = 'key1',
    String title = 'Front door',
    String signatureId = '',
  }) => fromNative('ring', {
        'package': package,
        'key': key,
        'title': title,
        'signatureId': signatureId,
      });

  /// The native side reports a caught notification (whether or not a capture runs).
  Future<void> reportCaptured() => fromNative('captured', const {
        'package': 'com.oufy',
        'channelId': 'channel 1',
        'channelPrefix': 'com.oufy.ring',
        'title': 'Someone at the door',
        'appLabel': 'Oufy',
      });

  group('the configuration push', () {
    test('pushes the saved signatures at init while the setting is on', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      expect(configurePushes(), [
        {
          'signatures': [eufy],
        },
      ]);
    });

    test('pushes an empty list while the setting is off', () async {
      await build({
        'ks.doorbell.enabled': false,
        'ks.doorbell.signatures': savedEufy,
      });
      expect(configurePushes(), [
        {'signatures': []},
      ]);
    });

    test('pushes again when the setting turns off', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await settings.set(defs.doorbellEnabled, false);
      await pumpEventQueue();
      expect(configurePushes(), hasLength(2));
      expect(configurePushes().last, {'signatures': []});
    });

    test('pushes again when the signatures change', () async {
      await build({'ks.doorbell.enabled': true});
      await settings.set(defs.doorbellSignatures, savedEufy);
      await pumpEventQueue();
      expect(configurePushes().last, {
        'signatures': [eufy],
      });
    });

    test('does not push for an unrelated setting change', () async {
      await build({'ks.doorbell.enabled': true});
      await settings.set(defs.doorbellReturnSeconds, 40);
      await pumpEventQueue();
      expect(configurePushes(), hasLength(1));
    });

    test('init survives a missing native side', () async {
      await build(
        {'ks.doorbell.enabled': true},
        error: MissingPluginException(),
      );
      expect(configurePushes(), hasLength(1));
    });

    test('init survives a native PlatformException', () async {
      await build(
        {'ks.doorbell.enabled': true},
        error: PlatformException(code: 'unavailable'),
      );
      expect(configurePushes(), hasLength(1));
    });

    test('init survives a native error that is neither', () async {
      await build(
        {'ks.doorbell.enabled': true},
        error: Exception('the listener is gone'),
      );
      expect(configurePushes(), hasLength(1));
    });

    test('configure carries only the doorbells a notification rings',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures':
            '[{"id":"eufy","label":"Eufy","package":"com.eufy",'
            '"channelPrefix":"pre"},'
            '{"id":"ha","label":"HA","package":"com.ha",'
            '"entity":"binary_sensor.door","clickLabel":"Front door"}]',
      });
      expect(configurePushes().single, {
        'signatures': [
          {
            'id': 'eufy',
            'label': 'Eufy',
            'package': 'com.eufy',
            'channelPrefix': 'pre',
          },
        ],
      });
    });

    test('configureClick carries the distinct click and entity packages',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures':
            '[{"id":"a","label":"A","package":"com.one","channelPrefix":"pre"},'
            '{"id":"b","label":"B","package":"com.two",'
            '"entity":"binary_sensor.b","clickLabel":"B"},'
            '{"id":"c","label":"C","package":"com.two","channelPrefix":"pre2",'
            '"open":"click","clickLabel":"C"}]',
      });
      expect(configureClickPushes().single, {
        'packages': ['com.two'],
      });
    });

    test('configureClick is empty while the setting is off', () async {
      await build({
        'ks.doorbell.enabled': false,
        'ks.doorbell.signatures':
            '[{"id":"b","label":"B","package":"com.two",'
            '"entity":"binary_sensor.b","clickLabel":"B"}]',
      });
      expect(configureClickPushes().single, {
        'packages': [],
      });
    });
  });

  group('the click delay setting', () {
    test('exists with its default and category', () {
      expect(defs.doorbellClickDelaySeconds.key,
          'doorbell.click_delay_seconds');
      expect(defs.doorbellClickDelaySeconds.defaultValue, 8);
      expect(defs.doorbellClickDelaySeconds.category, 'Doorbell');
      expect(defs.allSettings, contains(defs.doorbellClickDelaySeconds));
    });
  });

  group('a ring', () {    test('is ignored while the setting is off', () async {
      await build({
        'ks.doorbell.enabled': false,
        'ks.doorbell.signatures': savedEufy,
      });
      await ring();
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents, isEmpty);
    });

    test('under lockdown opens nothing and tells Home Assistant it did '
        'not open', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.lockdown.enabled': true,
      });
      await ring(title: 'Front door');
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
      expect(haEvents.single.name, 'kiosk_satellite_doorbell');
      expect(haEvents.single.data, {
        'event_type': 'ringing',
        'doorbell': 'Front door',
        'label': 'Front door',
        'opened': false,
        'trigger': 'notification',
        'open': 'tap',
      });
    });

    test('wakes the screen, then opens the notification', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.return_seconds': 40,
      });
      await ring(key: 'key1', title: 'Front door');
      expect(stubNames(), ['screenOn', 'openNotificationAction']);
      expect(stubParams('openNotificationAction'), {
        'key': 'key1',
        'package': 'com.oceanwing.battery.cam',
        'label': 'Front door',
        'returnAfterSeconds': 40,
      });
    });

    test('publishes the HA event with opened true when it opens', () async {
      await build({'ks.doorbell.enabled': true});
      await ring(title: 'Front door');
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
      expect(haEvents.single.name, 'kiosk_satellite_doorbell');
      expect(haEvents.single.data, {
        'event_type': 'ringing',
        'doorbell': 'Front door',
        'label': 'Front door',
        'opened': true,
        'trigger': 'notification',
        'open': 'tap',
      });
    });

    test('publishes opened false when opening fails', () async {
      await build(
        {'ks.doorbell.enabled': true},
        openNotificationFails: true,
      );
      await ring(title: 'Front door');
      await pumpEventQueue();
      expect(haEvents.single.data['opened'], isFalse);
    });

    test('names the saved signature the ring came from', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await ring(title: 'Front door', signatureId: 'eufy');
      await pumpEventQueue();
      expect(haEvents.single.data['doorbell'], 'Front door');
      expect(haEvents.single.data['label'], 'Eufy Security');
    });

    test('falls back to the title for an unknown or empty signatureId',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await ring(title: 'Front door', signatureId: 'someone-else');
      await pumpEventQueue();
      expect(haEvents.single.data['label'], 'Front door');
      await ring(title: 'Back door');
      await pumpEventQueue();
      expect(haEvents.last.data['label'], 'Back door');
    });

    test('a click doorbell opens by click, not by tap', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      expect(stubNames(), ['screenOn', 'openAppAndClick']);
      expect(stubParams('openAppAndClick'), {
        'package': 'com.oceanwing.battery.cam',
        'label': 'Front door',
        'delaySeconds': 8,
        'returnAfterSeconds': 75,
      });
      await pumpEventQueue();
      expect(haEvents.single.data, {
        'event_type': 'ringing',
        'doorbell': 'Someone at the door',
        'label': 'Eufy Security',
        'opened': true,
        'trigger': 'notification',
        'open': 'click',
      });
    });

    test('the click delay and return settings are honoured', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.click_delay_seconds': 3,
        'ks.doorbell.return_seconds': 40,
        'ks.doorbell.signatures': savedClickEufy,
      });
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      expect(stubParams('openAppAndClick'), {
        'package': 'com.oceanwing.battery.cam',
        'label': 'Front door',
        'delaySeconds': 3,
        'returnAfterSeconds': 40,
      });
    });

    test('a failed tap falls back to a click when there is a click label',
        () async {
      await build(
        {
          'ks.doorbell.enabled': true,
          'ks.doorbell.signatures': savedTapEufyWithClick,
        },
        openNotificationFails: true,
      );
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      expect(stubNames(),
          ['screenOn', 'openNotificationAction', 'openAppAndClick']);
      await pumpEventQueue();
      expect(haEvents.single.data['open'], 'click');
      expect(haEvents.single.data['opened'], isTrue);
    });

    test('a failed tap without a click label does not fall back', () async {
      await build(
        {
          'ks.doorbell.enabled': true,
          'ks.doorbell.signatures': savedEufy,
        },
        openNotificationFails: true,
      );
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      expect(stubNames(), ['screenOn', 'openNotificationAction']);
      await pumpEventQueue();
      expect(haEvents.single.data['opened'], isFalse);
      expect(haEvents.single.data['open'], 'tap');
    });

    test('does nothing without a notification key', () async {
      await build({'ks.doorbell.enabled': true});
      await ring(key: '');
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents, isEmpty);
    });
  });

  group('an entity ring', () {
    test('opens by click and publishes the entity event', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEntityDoorbell,
      });
      await doorbell.ringFromEntity('ring');
      expect(stubNames(), ['screenOn', 'openAppAndClick']);
      expect(stubParams('openAppAndClick'), {
        'package': 'com.ring',
        'label': 'Front door',
        'delaySeconds': 8,
        'returnAfterSeconds': 75,
      });
      await pumpEventQueue();
      expect(haEvents.single.data, {
        'event_type': 'ringing',
        'doorbell': 'Ring',
        'label': 'Ring',
        'opened': true,
        'trigger': 'entity',
        'open': 'click',
      });
    });

    test('is ignored while the setting is off and starts no window',
        () async {
      await build({
        'ks.doorbell.enabled': false,
        'ks.doorbell.signatures': savedEntityDoorbell,
      });
      var now = DateTime(2024, 1, 1);
      doorbell.clock = () => now;
      await doorbell.ringFromEntity('ring');
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents, isEmpty);
      await settings.set(defs.doorbellEnabled, true);
      await pumpEventQueue();
      now = now.add(const Duration(seconds: 2));
      await doorbell.ringFromEntity('ring');
      expect(stubNames(), ['screenOn', 'openAppAndClick']);
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
    });

    test('under lockdown opens nothing and publishes opened false',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.lockdown.enabled': true,
        'ks.doorbell.signatures': savedEntityDoorbell,
      });
      await doorbell.ringFromEntity('ring');
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents.single.data['opened'], isFalse);
      expect(haEvents.single.data['trigger'], 'entity');
    });

    test('ignores a second ring within 20 s and accepts a later one',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEntityDoorbell,
      });
      var now = DateTime(2024, 1, 1);
      doorbell.clock = () => now;
      await doorbell.ringFromEntity('ring');
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
      now = now.add(const Duration(seconds: 19));
      await doorbell.ringFromEntity('ring');
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
      now = now.add(const Duration(seconds: 2));
      await doorbell.ringFromEntity('ring');
      await pumpEventQueue();
      expect(haEvents, hasLength(2));
    });

    test('does nothing for an unknown id or a doorbell without an entity',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await doorbell.ringFromEntity('nope');
      await doorbell.ringFromEntity('eufy');
      expect(stubCalls, isEmpty);
      await pumpEventQueue();
      expect(haEvents, isEmpty);
    });
  });

  group('a click result', () {
    test('not_found, wrong_app and service_off publish click_failed',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
      for (final reason in ['not_found', 'wrong_app', 'service_off']) {
        await fromNative('clickResult', {
          'package': 'com.oceanwing.battery.cam',
          'label': 'Front door',
          'result': reason,
        });
        await pumpEventQueue();
        expect(haEvents.last.data, {
          'event_type': 'click_failed',
          'doorbell': 'Eufy Security',
          'label': 'Front door',
          'reason': reason,
        });
      }
      expect(haEvents, hasLength(4));
    });

    test('a clicked result publishes nothing', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      await ring(title: 'Someone at the door', signatureId: 'eufy');
      await pumpEventQueue();
      await fromNative('clickResult', {
        'package': 'com.oceanwing.battery.cam',
        'label': 'Front door',
        'result': 'clicked',
      });
      await pumpEventQueue();
      expect(haEvents, hasLength(1));
    });

    test('a result for a label no ring used names the label', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      await fromNative('clickResult', {
        'package': 'com.oceanwing.battery.cam',
        'label': 'Unknown card',
        'result': 'not_found',
      });
      await pumpEventQueue();
      expect(haEvents.single.data, {
        'event_type': 'click_failed',
        'doorbell': 'Unknown card',
        'label': 'Unknown card',
        'reason': 'not_found',
      });
    });

    test('never throws on missing keys', () async {
      await build({'ks.doorbell.enabled': true});
      await fromNative('clickResult', const {});
      await pumpEventQueue();
      expect(haEvents.single.data, {
        'event_type': 'click_failed',
        'doorbell': '',
        'label': '',
        'reason': '',
      });
    });
  });

  group('doorbellTestOpen', () {
    test('opens by click and returns ok without an event', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      final result = await run('doorbellTestOpen', {'id': 'eufy'});
      expect(result.ok, isTrue);
      expect(stubNames(), ['screenOn', 'openAppAndClick']);
      expect(stubParams('openAppAndClick'), {
        'package': 'com.oceanwing.battery.cam',
        'label': 'Front door',
        'delaySeconds': 8,
        'returnAfterSeconds': 75,
      });
      await pumpEventQueue();
      expect(haEvents, isEmpty);
    });

    test('fails while the setting is off', () async {
      await build({
        'ks.doorbell.enabled': false,
        'ks.doorbell.signatures': savedClickEufy,
      });
      final result = await run('doorbellTestOpen', {'id': 'eufy'});
      expect(result.ok, isFalse);
      expect(result.error, 'the doorbell setting is off');
      expect(stubCalls, isEmpty);
    });

    test('fails for an unknown id', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedClickEufy,
      });
      final result = await run('doorbellTestOpen', {'id': 'nope'});
      expect(result.ok, isFalse);
      expect(result.error, 'no such doorbell');
      expect(stubCalls, isEmpty);
    });

    test('fails without a click label', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      final result = await run('doorbellTestOpen', {'id': 'eufy'});
      expect(result.ok, isFalse);
      expect(result.error, 'this doorbell has no click label');
      expect(stubCalls, isEmpty);
    });
  });

  group('the capture', () {
    test('refuses to start while the setting is off', () async {
      await build({'ks.doorbell.enabled': false});
      final result = await run('doorbellStartCapture');
      expect(result.ok, isFalse);
      expect(result.error, 'the doorbell setting is off');
      expect(
        [for (final call in nativeCalls) call.method],
        isNot(contains('startCapture')),
      );
    });

    test('starts the native capture and clears a stale result', () async {
      await build({'ks.doorbell.enabled': true});
      await reportCaptured();
      expect(doorbell.captured.value, isNotNull);
      final result = await run('doorbellStartCapture');
      expect(result.ok, isTrue);
      expect(
        nativeCalls.firstWhere((call) => call.method == 'startCapture')
            .arguments,
        {'seconds': 60},
      );
      expect(doorbell.capturing.value, isTrue);
      expect(doorbell.captured.value, isNull);
    });

    test('fails and stands down when the native start throws', () async {
      await build(
        {'ks.doorbell.enabled': true},
        error: Exception('no listener'),
      );
      final result = await run('doorbellStartCapture');
      expect(result.ok, isFalse);
      expect(result.error, startsWith('could not start capture:'));
      expect(doorbell.capturing.value, isFalse);
    });

    test('records the notification a native capture reports', () async {
      await build({'ks.doorbell.enabled': true});
      await reportCaptured();
      final capture = doorbell.captured.value;
      expect(capture, isNotNull);
      expect(capture!.package, 'com.oufy');
      expect(capture.channelId, 'channel 1');
      expect(capture.channelPrefix, 'com.oufy.ring');
      expect(capture.title, 'Someone at the door');
      expect(capture.appLabel, 'Oufy');
    });

    test('ends when the native side says so', () async {
      await build({'ks.doorbell.enabled': true});
      await run('doorbellStartCapture');
      expect(doorbell.capturing.value, isTrue);
      await fromNative('captureEnded', {'reason': 'timeout'});
      expect(doorbell.capturing.value, isFalse);
    });

    test('stops on command: native stop, flag down, ok', () async {
      await build({'ks.doorbell.enabled': true});
      await run('doorbellStartCapture');
      final result = await run('doorbellStopCapture');
      expect(result.ok, isTrue);
      expect(
        nativeCalls.firstWhere((call) => call.method == 'stopCapture')
            .arguments,
        equals(<String, Object?>{}),
      );
      expect(doorbell.capturing.value, isFalse);
    });

    test('still stands down when the native stop throws', () async {
      await build({'ks.doorbell.enabled': true});
      await run('doorbellStartCapture');
      nativeError = Exception('no listener');
      final result = await run('doorbellStopCapture');
      expect(result.ok, isTrue);
      expect(doorbell.capturing.value, isFalse);
    });

    test('turning the setting off ends a running capture', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await run('doorbellStartCapture');
      await reportCaptured();
      expect(doorbell.captured.value, isNotNull);
      await settings.set(defs.doorbellEnabled, false);
      await pumpEventQueue();
      expect(
        nativeCalls.firstWhere((call) => call.method == 'stopCapture')
            .arguments,
        equals(<String, Object?>{}),
      );
      expect(doorbell.capturing.value, isFalse);
      expect(doorbell.captured.value, isNull);
    });
  });

  group('the signature commands', () {
    test('doorbellSignatures returns the saved list as maps', () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      final result = await run('doorbellSignatures');
      expect(result.ok, isTrue);
      expect(result.data, [eufy]);
    });

    test('doorbellAddSignature builds the id from the label', () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Eufy Security!',
        'package': 'com.oceanwing.battery.cam',
        'channelPrefix': 'com.ocean.battery.cam.ring',
      });
      expect(result.ok, isTrue);
      expect(result.data, {
        'id': 'eufy-security',
        'label': 'Eufy Security!',
        'package': 'com.oceanwing.battery.cam',
        'channelPrefix': 'com.ocean.battery.cam.ring',
      });
    });

    test('the id keeps no edge dashes and falls back to doorbell', () async {
      await build({});
      final first = await run('doorbellAddSignature', {
        'label': ' -- ',
        'package': 'p',
        'channelPrefix': 'c',
      });
      expect((first.data as Map)['id'], 'doorbell');
      final second = await run('doorbellAddSignature', {
        'label': ' - Front Door - ',
        'package': 'p',
        'channelPrefix': 'c',
      });
      expect((second.data as Map)['id'], 'front-door');
    });

    test('numbers the ids of duplicates', () async {
      await build({'ks.doorbell.signatures': savedEufy});
      final second = await run('doorbellAddSignature', {
        'label': 'Eufy',
        'package': 'p2',
        'channelPrefix': 'c2',
      });
      expect((second.data as Map)['id'], 'eufy-2');
      final third = await run('doorbellAddSignature', {
        'label': 'Eufy',
        'package': 'p3',
        'channelPrefix': 'c3',
      });
      expect((third.data as Map)['id'], 'eufy-3');
    });

    test('doorbellAddSignature requires a label, a package and a '
        'trigger', () async {
      await build({});
      for (final params in [
        {'label': '', 'package': 'p', 'channelPrefix': 'c'},
        {'label': 'l', 'package': '', 'channelPrefix': 'c'},
      ]) {
        final result = await run('doorbellAddSignature', params);
        expect(result.ok, isFalse);
        expect(result.error, 'label and package are required');
      }
      final result = await run('doorbellAddSignature', {
        'label': 'l',
        'package': 'p',
      });
      expect(result.ok, isFalse);
      expect(result.error,
          'a doorbell needs a notification channel or a Home Assistant '
          'entity');
    });

    test('doorbellAddSignature saves a click doorbell with an entity',
        () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Ring',
        'package': 'com.ring',
        'entity': 'binary_sensor.front_door_ringing',
        'open': 'click',
        'clickLabel': 'Front door',
      });
      expect(result.ok, isTrue);
      expect(result.data, {
        'id': 'ring',
        'label': 'Ring',
        'package': 'com.ring',
        'channelPrefix': '',
        'entity': 'binary_sensor.front_door_ringing',
        'open': 'click',
        'clickLabel': 'Front door',
      });
    });

    test('doorbellAddSignature needs a click label for an entity',
        () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Ring',
        'package': 'com.ring',
        'entity': 'binary_sensor.front_door_ringing',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'a Home Assistant ring needs a click label');
    });

    test('doorbellAddSignature needs a click label for a click doorbell',
        () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Ring',
        'package': 'com.ring',
        'channelPrefix': 'pre',
        'open': 'click',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'a click doorbell needs a click label');
    });

    test('doorbellAddSignature with only a channelPrefix keeps the four '
        'old keys', () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Eufy',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
      });
      expect(result.ok, isTrue);
      expect(result.data, {
        'id': 'eufy',
        'label': 'Eufy',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
      });
    });

    test('doorbellAddSignature trims its fields', () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': '  Eufy  ',
        'package': ' com.eufy ',
        'channelPrefix': ' pre ',
      });
      expect(result.data, {
        'id': 'eufy',
        'label': 'Eufy',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
      });
    });

    test('doorbellAddSignature saves the new signature', () async {
      await build({});
      final result = await run('doorbellAddSignature', {
        'label': 'Eufy',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
      });
      expect(result.ok, isTrue);
      expect(
        settings.get(defs.doorbellSignatures),
        '[{"id":"eufy","label":"Eufy","package":"com.eufy",'
        '"channelPrefix":"pre"}]',
      );
    });

    test('doorbellAddSignature works over a garbage setting', () async {
      for (final garbage in ['not json', '{}']) {
        await build({'ks.doorbell.signatures': garbage});
        final result = await run('doorbellAddSignature', {
          'label': 'Eufy',
          'package': 'com.eufy',
          'channelPrefix': 'pre',
        });
        expect(result.ok, isTrue);
        final saved = await run('doorbellSignatures');
        expect(saved.data, [
          {
            'id': 'eufy',
            'label': 'Eufy',
            'package': 'com.eufy',
            'channelPrefix': 'pre',
          },
        ]);
      }
    });

    test('doorbellRemoveSignature removes a saved doorbell', () async {
      await build({
        'ks.doorbell.signatures':
            '[{"id":"a","label":"A","package":"p1","channelPrefix":"c1"},'
            '{"id":"b","label":"B","package":"p2","channelPrefix":"c2"}]',
      });
      final result = await run('doorbellRemoveSignature', {'id': 'a'});
      expect(result.ok, isTrue);
      expect(
        settings.get(defs.doorbellSignatures),
        '[{"id":"b","label":"B","package":"p2","channelPrefix":"c2"}]',
      );
    });

    test('doorbellRemoveSignature fails for an absent doorbell', () async {
      await build({'ks.doorbell.signatures': savedEufy});
      final result = await run('doorbellRemoveSignature', {'id': 'nope'});
      expect(result.ok, isFalse);
      expect(result.error, 'no such doorbell');
    });

    test('doorbellRemoveSignature fails over a garbage setting', () async {
      await build({'ks.doorbell.signatures': 'not json'});
      final result = await run('doorbellRemoveSignature', {'id': 'eufy'});
      expect(result.ok, isFalse);
      expect(result.error, 'no such doorbell');
    });

    test('doorbellUpdateSignature changes only the given keys', () async {
      await build({
        'ks.doorbell.signatures':
            '[{"id":"eufy","label":"Eufy","package":"com.eufy",'
            '"channelPrefix":"pre","entity":"binary_sensor.e",'
            '"open":"click","clickLabel":"Front door"}]',
      });
      final result = await run('doorbellUpdateSignature', {
        'id': 'eufy',
        'label': 'Eufy 2',
        'clickLabel': 'Back door',
      });
      expect(result.ok, isTrue);
      expect(result.data, {
        'id': 'eufy',
        'label': 'Eufy 2',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
        'entity': 'binary_sensor.e',
        'open': 'click',
        'clickLabel': 'Back door',
      });
    });

    test('doorbellUpdateSignature clears a field with an empty string',
        () async {
      await build({
        'ks.doorbell.signatures':
            '[{"id":"eufy","label":"Eufy","package":"com.eufy",'
            '"channelPrefix":"pre","entity":"binary_sensor.e",'
            '"clickLabel":"Front door"}]',
      });
      final result = await run('doorbellUpdateSignature', {
        'id': 'eufy',
        'entity': '',
      });
      expect(result.ok, isTrue);
      expect(result.data, {
        'id': 'eufy',
        'label': 'Eufy',
        'package': 'com.eufy',
        'channelPrefix': 'pre',
        'clickLabel': 'Front door',
      });
    });

    test('doorbellUpdateSignature fails for an absent doorbell',
        () async {
      await build({'ks.doorbell.signatures': savedEufy});
      final result = await run('doorbellUpdateSignature', {'id': 'nope'});
      expect(result.ok, isFalse);
      expect(result.error, 'no such doorbell');
    });

    test('doorbellUpdateSignature saves nothing when the rules break',
        () async {
      await build({'ks.doorbell.signatures': savedEufy});
      final result = await run('doorbellUpdateSignature', {
        'id': 'eufy',
        'channelPrefix': '',
      });
      expect(result.ok, isFalse);
      expect(result.error,
          'a doorbell needs a notification channel or a Home Assistant '
          'entity');
      expect(settings.get(defs.doorbellSignatures), savedEufy);
    });
  });

  group('the click capture', () {
    test('doorbellClickAccess reports the native service', () async {
      await build({'ks.doorbell.enabled': true});
      final on = await run('doorbellClickAccess');
      expect(on.ok, isTrue);
      expect(on.data, {'running': true});
      clickServiceRunning = false;
      final off = await run('doorbellClickAccess');
      expect(off.data, {'running': false});
    });

    test('doorbellClickAccess says false without a native side',
        () async {
      await build(
        {'ks.doorbell.enabled': true},
        error: MissingPluginException(),
      );
      final result = await run('doorbellClickAccess');
      expect(result.ok, isTrue);
      expect(result.data, {'running': false});
    });

    test('doorbellStartClickCapture refuses while the setting is off',
        () async {
      await build({'ks.doorbell.enabled': false});
      final result = await run('doorbellStartClickCapture', {
        'package': 'com.ring',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'the doorbell setting is off');
      expect(
        [for (final call in nativeCalls) call.method],
        isNot(contains('startClickCapture')),
      );
    });

    test('doorbellStartClickCapture refuses without a package',
        () async {
      await build({'ks.doorbell.enabled': true});
      final result = await run('doorbellStartClickCapture', {
        'package': '  ',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'package required');
    });

    test('doorbellStartClickCapture refuses while the service is off',
        () async {
      await build({'ks.doorbell.enabled': true});
      clickServiceRunning = false;
      final result = await run('doorbellStartClickCapture', {
        'package': 'com.ring',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'enable Doorbell click access first');
      expect(
        [for (final call in nativeCalls) call.method],
        isNot(contains('startClickCapture')),
      );
    });

    test('doorbellStartClickCapture starts the native capture', () async {
      await build({'ks.doorbell.enabled': true});
      final result = await run('doorbellStartClickCapture', {
        'package': ' com.ring ',
      });
      expect(result.ok, isTrue);
      expect(
        nativeCalls.firstWhere((call) => call.method == 'startClickCapture')
            .arguments,
        {'package': 'com.ring', 'seconds': 90},
      );
      expect(doorbell.clickCapturing.value, isTrue);
    });

    test('doorbellStartClickCapture fails and stands down when the native '
        'start says no', () async {
      await build({'ks.doorbell.enabled': true});
      messenger.setMockMethodCallHandler(channel, (call) async {
        nativeCalls.add(call);
        if (call.method == 'clickServiceRunning') return true;
        if (call.method == 'startClickCapture') return false;
        return null;
      });
      final result = await run('doorbellStartClickCapture', {
        'package': 'com.ring',
      });
      expect(result.ok, isFalse);
      expect(result.error, 'could not open the app');
      expect(doorbell.clickCapturing.value, isFalse);
    });

    test('doorbellStopClickCapture stops the native capture', () async {
      await build({'ks.doorbell.enabled': true});
      await run('doorbellStartClickCapture', {'package': 'com.ring'});
      final result = await run('doorbellStopClickCapture');
      expect(result.ok, isTrue);
      expect(
        nativeCalls.firstWhere((call) => call.method == 'stopClickCapture')
            .arguments,
        equals(<String, Object?>{}),
      );
      expect(doorbell.clickCapturing.value, isFalse);
    });

    test('a native click capture reports its click and comes back',
        () async {
      await build({'ks.doorbell.enabled': true});
      await fromNative('clickCaptured', {
        'package': 'com.ring',
        'label': 'Front door',
      });
      final capture = doorbell.clickCaptured.value;
      expect(capture, isNotNull);
      expect(capture!.package, 'com.ring');
      expect(capture.label, 'Front door');
      await pumpEventQueue();
      expect(stubNames(), ['bringToFront']);
      expect(stubParams('bringToFront'), equals(<String, Object?>{}));
    });

    test('ends when the native side says so', () async {
      await build({'ks.doorbell.enabled': true});
      await run('doorbellStartClickCapture', {'package': 'com.ring'});
      expect(doorbell.clickCapturing.value, isTrue);
      await fromNative('clickCaptureEnded', {'reason': 'timeout'});
      expect(doorbell.clickCapturing.value, isFalse);
    });

    test('turning the setting off ends a running click capture',
        () async {
      await build({
        'ks.doorbell.enabled': true,
        'ks.doorbell.signatures': savedEufy,
      });
      await run('doorbellStartClickCapture', {'package': 'com.ring'});
      await fromNative('clickCaptured', {
        'package': 'com.ring',
        'label': 'Front door',
      });
      expect(doorbell.clickCaptured.value, isNotNull);
      await settings.set(defs.doorbellEnabled, false);
      await pumpEventQueue();
      expect(
        nativeCalls.firstWhere((call) => call.method == 'stopClickCapture')
            .arguments,
        equals(<String, Object?>{}),
      );
      expect(doorbell.clickCapturing.value, isFalse);
      expect(doorbell.clickCaptured.value, isNull);
    });
  });

  group('dispose', () {    test('a start that fails after dispose does not throw', () async {
      await build({'ks.doorbell.enabled': true});
      final lateStart = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startCapture') {
          await lateStart.future;
          throw PlatformException(code: 'late');
        }
        return null;
      });
      final pending = run('doorbellStartCapture');
      await pumpEventQueue();
      await doorbell.dispose();
      lateStart.complete();
      final result = await pending;
      expect(result.ok, isFalse);
      expect(result.error, startsWith('could not start capture:'));
    });

    test('a late start does not throw', () async {
      await build({'ks.doorbell.enabled': true});
      await doorbell.dispose();
      final result = await run('doorbellStartCapture');
      expect(result.ok, isTrue);
    });
  });
}
