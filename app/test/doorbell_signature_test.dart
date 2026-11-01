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
        '[{"package":"com.a","channelPrefix":"com.a.ring"},'
        '{"id":"a","channelPrefix":"com.a.ring"},'
        '{"id":"a","package":"com.a"},'
        '"not a map",'
        '{"id":"a","package":"com.a","channelPrefix":"com.a.ring"}]',
      );
      expect(decoded, hasLength(1));
      expect(decoded.single.id, 'a');
    });

    test('returns an empty list for non-list JSON and invalid JSON', () {
      expect(decodeDoorbellSignatures('{"id":"a"}'), isEmpty);
      expect(decodeDoorbellSignatures('not json'), isEmpty);
      expect(decodeDoorbellSignatures(''), isEmpty);
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
