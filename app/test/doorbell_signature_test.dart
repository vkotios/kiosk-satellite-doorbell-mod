import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/doorbell/doorbell_signature.dart';
import 'package:kiosk_satellite/managers/settings/definitions.dart' as defs;

/// The doorbell signature model: the tolerant decode of
/// doorbell.signatures, the built-in Eufy signature, and the Doorbell
/// settings the signatures feed.
void main() {
  group('decodeDoorbellSignatures', () {
    test('round trips a valid list through encode and decode', () {
      const signatures = [
        DoorbellSignature(
          id: 'eufy',
          label: 'Eufy Security',
          package: 'com.oceanwing.battery.cam',
          channelPrefix: 'com.ocean.battery.cam.ring',
        ),
        DoorbellSignature(
          id: 'ring',
          label: 'Ring',
          package: 'com.ring.cam',
          channelPrefix: 'com.ring.cam.ring',
        ),
      ];
      final decoded =
          decodeDoorbellSignatures(encodeDoorbellSignatures(signatures));
      expect(decoded, hasLength(2));
      expect(decoded[0].toJson(), signatures[0].toJson());
      expect(decoded[1].toJson(), signatures[1].toJson());
    });

    test('a missing or empty label becomes the package', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","channelPrefix":"com.a.ring"},'
        '{"id":"b","label":" ","package":"com.b","channelPrefix":"com.b.ring"}]',
      );
      expect(decoded, hasLength(2));
      expect(decoded[0].label, 'com.a');
      expect(decoded[1].label, 'com.b');
    });

    test('trims whitespace off every string', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":" eufy ","label":" Eufy Security ",'
        '"package":" com.oceanwing.battery.cam ",'
        '"channelPrefix":" com.ocean.battery.cam.ring "}]',
      );
      expect(decoded.single.id, 'eufy');
      expect(decoded.single.label, 'Eufy Security');
      expect(decoded.single.package, 'com.oceanwing.battery.cam');
      expect(decoded.single.channelPrefix, 'com.ocean.battery.cam.ring');
    });

    test('drops entries missing id, package or channelPrefix', () {
      final decoded = decodeDoorbellSignatures(
        '[{"package":"com.b","channelPrefix":"com.b.ring"},'
        '{"id":"c","channelPrefix":"com.c.ring"},'
        '{"id":"d","package":"com.d"},'
        '"not a map",'
        '{"id":"   ","package":"com.e","channelPrefix":"com.e.ring"},'
        '{"id":"f","package":"   ","channelPrefix":"com.f.ring"},'
        '{"id":"g","package":"com.g","channelPrefix":"   "},'
        '{"id":"a","package":"com.a","channelPrefix":"com.a.ring"}]',
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.id, 'a');
      expect(decoded.single.package, 'com.a');
      expect(decoded.single.channelPrefix, 'com.a.ring');
    });

    test('returns an empty list for non-list JSON and invalid JSON', () {
      expect(decodeDoorbellSignatures('{"id":"a"}'), isEmpty);
      expect(decodeDoorbellSignatures('not json'), isEmpty);
      expect(decodeDoorbellSignatures(''), isEmpty);
    });

    test('decodes an old four-key entry to the tap defaults and encodes '
        'it back to the same four keys', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"eufy","label":"Eufy Security",'
        '"package":"com.oceanwing.battery.cam",'
        '"channelPrefix":"com.ocean.battery.cam.ring"}]',
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.entity, '');
      expect(decoded.single.open, 'tap');
      expect(decoded.single.clickLabel, '');
      expect(decoded.single.toJson(), {
        'id': 'eufy',
        'label': 'Eufy Security',
        'package': 'com.oceanwing.battery.cam',
        'channelPrefix': 'com.ocean.battery.cam.ring',
      });
      expect(
        encodeDoorbellSignatures(decoded),
        '[{"id":"eufy","label":"Eufy Security",'
        '"package":"com.oceanwing.battery.cam",'
        '"channelPrefix":"com.ocean.battery.cam.ring"}]',
      );
    });

    test('drops a doorbell nothing can ring or open', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","entity":"binary_sensor.a"},'
        '{"id":"c","package":"com.c"},'
        '{"package":"com.d","channelPrefix":"com.d.ring"},'
        '{"id":"e","channelPrefix":"com.e.ring"}]',
      );
      expect(decoded, isEmpty);
    });

    test('keeps a notification doorbell that opens by a click without a '
        'clickLabel, opening by the tap instead', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","channelPrefix":"com.a.ring",'
        '"open":"click"}]',
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.open, 'tap');
      expect(decoded.single.clickLabel, '');
    });

    test('drops a click doorbell without a clickLabel and a channel', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","entity":"binary_sensor.a",'
        '"open":"click"}]',
      );
      expect(decoded, isEmpty);
    });

    test('normalizes the entity id', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","entity":"Binary_Sensor.X",'
        '"clickLabel":"A"}]',
      );
      expect(decoded.single.entity, 'binary_sensor.x');
    });

    test('an entity doorbell opens by click whatever was saved', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","entity":"binary_sensor.a",'
        '"open":"tap","clickLabel":"A"}]',
      );
      expect(decoded.single.open, 'click');
    });

    test('keeps both triggers together and a click-open doorbell', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","label":"A","package":"com.a",'
        '"channelPrefix":"com.a.ring","entity":"binary_sensor.a",'
        '"clickLabel":"A"},'
        '{"id":"b","label":"B","package":"com.b",'
        '"channelPrefix":"com.b.ring","open":"click","clickLabel":"B"}]',
      );
      expect(decoded, hasLength(2));
      expect(decoded[0].rungByNotification, isTrue);
      expect(decoded[0].rungByEntity, isTrue);
      expect(decoded[0].opensByClick, isTrue);
      expect(decoded[1].rungByNotification, isTrue);
      expect(decoded[1].rungByEntity, isFalse);
      expect(decoded[1].opensByClick, isTrue);
    });

    test("decodes every stored 'open' but 'click' as 'tap'", () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","channelPrefix":"com.a.ring",'
        '"open":"CLICK"},'
        '{"id":"b","package":"com.b","channelPrefix":"com.b.ring",'
        '"open":"tab"},'
        '{"id":"c","package":"com.c","channelPrefix":"com.c.ring",'
        '"open":""}]',
      );
      expect(decoded, hasLength(3));
      expect(decoded[0].open, 'tap');
      expect(decoded[1].open, 'tap');
      expect(decoded[2].open, 'tap');
    });

    test('trims entity and clickLabel too', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"a","package":"com.a","channelPrefix":"com.a.ring",'
        '"entity":" binary_sensor.a ","open":" click ",'
        '"clickLabel":" A "}]',
      );
      expect(decoded.single.entity, 'binary_sensor.a');
      expect(decoded.single.open, 'click');
      expect(decoded.single.clickLabel, 'A');
    });

    test('keeps the first of two entries sharing an id', () {
      final decoded = decodeDoorbellSignatures(
        '[{"id":"eufy","label":"First","package":"com.first",'
        '"channelPrefix":"com.first.ring"},'
        '{"id":"eufy","label":"Second","package":"com.second",'
        '"channelPrefix":"com.second.ring"}]',
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.label, 'First');
      expect(decoded.single.package, 'com.first');
    });
  });

  group('normalizeDoorbellEntity', () {
    test('trims and lower-cases a valid entity id', () {
      expect(
        normalizeDoorbellEntity('  Binary_Sensor.Front_Door '),
        'binary_sensor.front_door',
      );
    });

    test('returns null for anything that is not an entity id', () {
      expect(normalizeDoorbellEntity('nodot'), isNull);
      expect(normalizeDoorbellEntity('a.b c'), isNull);
      expect(normalizeDoorbellEntity(''), isNull);
    });
  });

  group('DoorbellSignature', () {
    test('round trips an entity doorbell with a clickLabel', () {
      const signature = DoorbellSignature(
        id: 'front',
        label: 'Front door',
        package: 'com.front',
        entity: 'binary_sensor.front_door_ringing',
        open: 'click',
        clickLabel: 'Front door',
      );
      expect(signature.toJson(), {
        'id': 'front',
        'label': 'Front door',
        'package': 'com.front',
        'channelPrefix': '',
        'entity': 'binary_sensor.front_door_ringing',
        'open': 'click',
        'clickLabel': 'Front door',
      });
      final decoded =
          decodeDoorbellSignatures(encodeDoorbellSignatures([signature]));
      expect(decoded, hasLength(1));
      expect(decoded.single.toJson(), signature.toJson());
      expect(decoded.single.entity, signature.entity);
      expect(decoded.single.open, signature.open);
      expect(decoded.single.clickLabel, signature.clickLabel);
    });

    test('omits entity, open and clickLabel from toJson for a default '
        'doorbell', () {
      const signature = DoorbellSignature(
        id: 'eufy',
        label: 'Eufy Security',
        package: 'com.oceanwing.battery.cam',
      );
      expect(signature.channelPrefix, '');
      expect(signature.toJson(), {
        'id': 'eufy',
        'label': 'Eufy Security',
        'package': 'com.oceanwing.battery.cam',
        'channelPrefix': '',
      });
      expect(signature.toJson().containsKey('entity'), isFalse);
      expect(signature.toJson().containsKey('open'), isFalse);
      expect(signature.toJson().containsKey('clickLabel'), isFalse);
    });

    test('tells how a doorbell rings and opens', () {
      const notification = DoorbellSignature(
        id: 'a',
        label: 'A',
        package: 'com.a',
        channelPrefix: 'com.a.ring',
      );
      expect(notification.rungByNotification, isTrue);
      expect(notification.rungByEntity, isFalse);
      expect(notification.opensByClick, isFalse);
      const entity = DoorbellSignature(
        id: 'b',
        label: 'B',
        package: 'com.b',
        entity: 'binary_sensor.b',
        open: 'click',
        clickLabel: 'B',
      );
      expect(entity.rungByNotification, isFalse);
      expect(entity.rungByEntity, isTrue);
      expect(entity.opensByClick, isTrue);
    });
  });

  group('eufySignature', () {
    test('holds the Eufy Security values', () {
      expect(eufySignature.id, 'eufy');
      expect(eufySignature.label, 'Eufy Security');
      expect(eufySignature.package, 'com.oceanwing.battery.cam');
      expect(eufySignature.channelPrefix, 'com.ocean.battery.cam.ring');
    });
  });

  group('doorbell settings', () {
    test('carry the Doorbell category and their default values', () {
      expect(defs.doorbellEnabled.defaultValue, isFalse);
      expect(defs.doorbellReturnSeconds.defaultValue, 75);
      expect(defs.doorbellSignatures.defaultValue, '[]');
      expect(defs.doorbellEnabled.category, 'Doorbell');
      expect(defs.doorbellReturnSeconds.category, 'Doorbell');
      expect(defs.doorbellSignatures.category, 'Doorbell');
    });

    test('are all present in allSettings', () {
      expect(defs.allSettings, contains(defs.doorbellEnabled));
      expect(defs.allSettings, contains(defs.doorbellReturnSeconds));
      expect(defs.allSettings, contains(defs.doorbellSignatures));
    });
  });
}
