import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_signature.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_status.dart';

/// The doorbell status model: the activity a doorbell last did, the
/// tolerant decode of internal.doorbell_activity, and the status text
/// and state both Doorbell UIs show for a doorbell.
void main() {
  const sensor = DoorbellSignature(
    id: 'front',
    label: 'Front door',
    package: 'com.front',
    entity: 'binary_sensor.front_door_ringing',
    open: 'click',
    clickLabel: 'Front door',
  );
  const notification = DoorbellSignature(
    id: 'eufy',
    label: 'Eufy Security',
    package: 'com.oceanwing.battery.cam',
    channelPrefix: 'com.ocean.battery.cam.ring',
  );

  DoorbellActivity activity(String result, {String kind = 'ring'}) =>
      DoorbellActivity(
        at: DateTime(2024, 1, 1, 9, 5),
        kind: kind,
        result: result,
      );

  group('DoorbellActivity', () {
    test('toJson writes all four keys', () {
      final json = activity('not_found', kind: 'test').toJson();
      expect(json, {
        'at': '2024-01-01T09:05:00.000',
        'kind': 'test',
        'result': 'not_found',
        'detail': '',
      });
    });

    test('round trips through toJson and fromJson', () {
      final one = DoorbellActivity(
        at: DateTime(2024, 1, 1, 9, 5),
        kind: 'ring',
        result: 'not_opened',
        detail: 'x',
      );
      final back = DoorbellActivity.fromJson(one.toJson());
      expect(back, isNotNull);
      expect(back!.at, one.at);
      expect(back.kind, one.kind);
      expect(back.result, one.result);
      expect(back.detail, one.detail);
    });

    test('fromJson defaults kind and detail and trims its strings', () {
      final back = DoorbellActivity.fromJson({
        'at': '2024-01-01T09:05:00',
        'result': ' opened ',
      });
      expect(back, isNotNull);
      expect(back!.kind, '');
      expect(back.result, 'opened');
      expect(back.detail, '');
    });

    test('fromJson refuses anything without a time or a result', () {
      expect(DoorbellActivity.fromJson(null), isNull);
      expect(DoorbellActivity.fromJson('nope'), isNull);
      expect(DoorbellActivity.fromJson({'result': 'opened'}), isNull);
      expect(DoorbellActivity.fromJson({'at': 'not a time'}), isNull);
      expect(
        DoorbellActivity.fromJson({'at': '2024-01-01T09:05:00'}),
        isNull,
      );
      expect(
        DoorbellActivity.fromJson({'at': '2024-01-01T09:05:00', 'result': ''}),
        isNull,
      );
    });
  });

  group('decodeDoorbellActivity', () {
    test('decodes the stored map', () {
      final decoded = decodeDoorbellActivity(
        '{"front":{"at":"2024-01-01T09:05:00","kind":"ring",'
        '"result":"clicked","detail":""}}',
      );
      expect(decoded.keys, ['front']);
      expect(decoded['front']!.kind, 'ring');
      expect(decoded['front']!.result, 'clicked');
    });

    test('garbage gives an empty map', () {
      expect(decodeDoorbellActivity('not json'), isEmpty);
      expect(decodeDoorbellActivity('[]'), isEmpty);
      expect(decodeDoorbellActivity(''), isEmpty);
    });

    test('drops entries that hold no activity and empty ids', () {
      final decoded = decodeDoorbellActivity(
        '{"front":{"at":"2024-01-01T09:05:00","result":"clicked"},'
        '"bad":"not a map",'
        '"worse":{"result":"opened"},'
        '" ":{"at":"2024-01-01T09:05:00","result":"opened"}}',
      );
      expect(decoded.keys, ['front']);
    });

    test('round trips through encodeDoorbellActivity', () {
      final activity = {
        'front': DoorbellActivity(
          at: DateTime(2024, 1, 1, 9, 5),
          kind: 'ring',
          result: 'clicked',
        ),
        'eufy': DoorbellActivity(
          at: DateTime(2024, 1, 1, 9, 6),
          kind: 'ring',
          result: 'not_opened',
          detail: 'x',
        ),
      };
      final back = decodeDoorbellActivity(encodeDoorbellActivity(activity));
      expect(back.keys, ['front', 'eufy']);
      expect(back['front']!.result, 'clicked');
      expect(back['eufy']!.detail, 'x');
    });
  });

  group('doorbellStatusText', () {
    test('a sensor doorbell that never ran asks for a test', () {
      expect(doorbellStatusText(sensor, null), 'Not tested yet. Press Test.');
    });

    test('a sensor doorbell last tested OK says so', () {
      expect(
        doorbellStatusText(sensor, activity('clicked', kind: 'test')),
        'Ready. Last tested OK 09:05.',
      );
    });

    test('a sensor doorbell whose last ring opened says so', () {
      expect(
        doorbellStatusText(sensor, activity('clicked')),
        'Ready. Last ring opened 09:05.',
      );
    });

    test('a sensor doorbell names the card it could not find', () {
      expect(
        doorbellStatusText(sensor, activity('not_found')),
        'Not working: could not find the card "Front door". 09:05.',
      );
    });

    test('a sensor doorbell says why each known failure happened', () {
      expect(
        doorbellStatusText(sensor, activity('wrong_app')),
        'Not working: the doorbell app did not come to the front. 09:05.',
      );
      expect(
        doorbellStatusText(sensor, activity('service_off')),
        'Not working: Doorbell click access is off. 09:05.',
      );
      expect(
        doorbellStatusText(sensor, activity('launch_failed')),
        'Not working: could not open the app. 09:05.',
      );
    });

    test('a sensor doorbell says an unknown result without a time', () {
      expect(
        doorbellStatusText(sensor, activity('timeout')),
        'Not working: timeout.',
      );
      expect(
        doorbellStatusText(sensor, activity('weird')),
        'Not working: weird.',
      );
    });

    test('a notification doorbell that never rang waits for one', () {
      expect(
        doorbellStatusText(notification, null),
        'Waiting for the first ring.',
      );
    });

    test('a notification doorbell whose last ring opened says so', () {
      expect(
        doorbellStatusText(notification, activity('opened')),
        'Working. Last ring opened 09:05.',
      );
    });

    test('a notification doorbell whose last ring did not open says so', () {
      expect(
        doorbellStatusText(notification, activity('not_opened')),
        'Last ring at 09:05 did not open.',
      );
    });

    test('a notification doorbell says an unknown result without a time',
        () {
      expect(
        doorbellStatusText(notification, activity('weird')),
        'Not working: weird.',
      );
    });

    test('the time is the local HH:mm the activity happened at', () {
      final utc = DateTime.utc(2024, 1, 1, 23, 5);
      final local = utc.toLocal();
      final expected =
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      expect(
        doorbellStatusText(
          notification,
          DoorbellActivity(at: utc, kind: 'ring', result: 'opened'),
        ),
        'Working. Last ring opened $expected.',
      );
    });
  });

  group('doorbellState', () {
    test('a sensor doorbell is untested, ready or failing', () {
      expect(doorbellState(sensor, null), 'untested');
      expect(doorbellState(sensor, activity('clicked')), 'ready');
      expect(doorbellState(sensor, activity('not_found')), 'failing');
      expect(doorbellState(sensor, activity('timeout')), 'failing');
    });

    test('a notification doorbell is waiting, ready or failing', () {
      expect(doorbellState(notification, null), 'waiting');
      expect(doorbellState(notification, activity('opened')), 'ready');
      expect(doorbellState(notification, activity('not_opened')), 'failing');
      expect(doorbellState(notification, activity('weird')), 'failing');
    });
  });
}
