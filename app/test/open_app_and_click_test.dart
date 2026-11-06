import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/core/command_registry.dart';
import 'package:kiosk_satellite/core/event_bus.dart';
import 'package:kiosk_satellite/core/events.dart';
import 'package:kiosk_satellite/core/logging.dart';
import 'package:kiosk_satellite/managers/kiosk/kiosk_manager.dart';
import 'package:kiosk_satellite/managers/settings/settings_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// openAppAndClick, the command a doorbell ring that opens by click runs:
/// it launches the doorbell app over the kiosk and has the native side
/// tap the card whose label matches, unpinned first like launchApp, and
/// the launch is published as sanctioned so the launcher's auto-return
/// owns the way back.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  const lockChannel = MethodChannel('kiosk_satellite/kiosk_lock');
  const doorbellChannel = MethodChannel('kiosk_satellite/doorbell');

  late EventBus bus;
  late CommandRegistry commands;
  late KioskManager kiosk;

  /// Every outgoing call on the lock channel, in order.
  late List<String> lockCalls;

  /// Every launchAndClick call on the doorbell channel, in order.
  late List<MethodCall> clickCalls;

  /// What the mock native side reports: whether the task is pinned right
  /// now, and whether the launch starts.
  late bool pinned;
  late bool launchWorks;

  Future<void> build(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    bus = EventBus();
    final log = Logger();
    commands = CommandRegistry(log);
    final settings = SettingsManager(bus, commands, log);
    await settings.init();

    lockCalls = [];
    clickCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(lockChannel, (
      call,
    ) async {
      lockCalls.add(call.method);
      switch (call.method) {
        case 'unpin':
          final was = pinned;
          pinned = false;
          return was;
        case 'isPinned':
          return pinned;
        case 'hasOverlayPermission':
          return true;
        default:
          return null;
      }
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(doorbellChannel, (
      call,
    ) async {
      if (call.method == 'launchAndClick') {
        clickCalls.add(call);
        return launchWorks;
      }
      return null;
    });

    kiosk = KioskManager(bus, commands, log, settings);
    kiosk.pushFlags = true;
    await kiosk.init();
    // init pushes its own apply; only calls made by the scenario count.
    lockCalls.clear();
  }

  tearDown(() async {
    await kiosk.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(lockChannel, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      doorbellChannel,
      null,
    );
  });

  group('openAppAndClick', () {
    test('launches the app and taps the card, published as sanctioned',
        () async {
      pinned = true;
      launchWorks = true;
      await build({'ks.kiosk.enabled': true, 'ks.kiosk.disable_home': true});
      final launched = <AppLaunched>[];
      bus.on<AppLaunched>().listen(launched.add);

      final result = await commands.execute('openAppAndClick', {
        'package': ' com.example.doorbell ',
        'label': ' Front door ',
        'returnAfterSeconds': 40,
      });
      expect(result.ok, true);
      expect(clickCalls, hasLength(1));
      expect(clickCalls.single.arguments, {
        'package': 'com.example.doorbell',
        'label': 'Front door',
        'delaySeconds': 8,
        'windowSeconds': 15,
        'reportCards': false,
      });
      expect(lockCalls, contains('unpin'));
      expect(lockCalls, isNot(contains('apply')));
      await pumpEventQueue();
      expect(launched, hasLength(1));
      expect(launched.single.package, 'com.example.doorbell');
      expect(launched.single.returnAfterSeconds, 40);
    });

    test('the wait before the tap comes from delaySeconds, clamped to 120',
        () async {
      pinned = false;
      launchWorks = true;
      await build({});
      expect(
        (await commands.execute('openAppAndClick', {
          'package': 'com.example.doorbell',
          'label': 'Front door',
          'delaySeconds': 3,
        })).ok,
        true,
      );
      expect(clickCalls.single.arguments['delaySeconds'], 3);
      expect(
        (await commands.execute('openAppAndClick', {
          'package': 'com.example.doorbell',
          'label': 'Front door',
          'delaySeconds': 500,
        })).ok,
        true,
      );
      expect(clickCalls.last.arguments['delaySeconds'], 120);
    });

    test('reportCards is forwarded and defaults to false', () async {
      pinned = false;
      launchWorks = true;
      await build({});
      expect(
        (await commands.execute('openAppAndClick', {
          'package': 'com.example.doorbell',
          'label': 'Front door',
        })).ok,
        true,
      );
      expect(clickCalls.single.arguments['reportCards'], false);
      expect(
        (await commands.execute('openAppAndClick', {
          'package': 'com.example.doorbell',
          'label': 'Front door',
          'reportCards': true,
        })).ok,
        true,
      );
      expect(clickCalls.last.arguments['reportCards'], true);
    });

    test('rejects a missing package or label without unpinning', () async {
      pinned = true;
      launchWorks = true;
      await build({'ks.kiosk.enabled': true, 'ks.kiosk.disable_home': true});

      expect(
        (await commands.execute('openAppAndClick', const {})).error,
        'package required',
      );
      expect(
        (await commands.execute('openAppAndClick', {
          'package': 'com.example.doorbell',
        })).error,
        'label required',
      );
      expect(lockCalls, isNot(contains('unpin')));
      expect(clickCalls, isEmpty);
    });

    test('a launch that does not start fails and re-arms the pin',
        () async {
      pinned = true;
      launchWorks = false;
      await build({'ks.kiosk.enabled': true, 'ks.kiosk.disable_home': true});
      final result = await commands.execute('openAppAndClick', {
        'package': 'com.example.gone',
        'label': 'Front door',
      });
      expect(result.ok, false);
      expect(
        result.error,
        'com.example.gone is not installed, or Android refused to open it',
      );
      expect(lockCalls.indexOf('unpin'), lessThan(lockCalls.indexOf('apply')));
    });
  });
}
