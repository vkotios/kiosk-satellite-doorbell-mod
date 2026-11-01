import 'dart:convert';

/// One doorbell app the kiosk answers a ring from: the Android package
/// whose notifications are the rings, the prefix of the notification
/// channel a ring arrives on, and the label the UI shows.
class DoorbellSignature {
  const DoorbellSignature({
    required this.id,
    required this.label,
    required this.package,
    required this.channelPrefix,
  });

  /// Unique and non-empty, e.g. 'eufy'.
  final String id;

  /// What the UI shows, e.g. 'Eufy Security'.
  final String label;

  /// The Android package whose notifications are the rings.
  final String package;

  /// A ring's notification channel id starts with this.
  final String channelPrefix;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'package': package,
        'channelPrefix': channelPrefix,
      };
}

/// The Eufy Security app, the doorbell this feature was built against.
const eufySignature = DoorbellSignature(
  id: 'eufy',
  label: 'Eufy Security',
  package: 'com.oceanwing.battery.cam',
  channelPrefix: 'com.ocean.battery.cam.ring',
);

/// Decode doorbell.signatures, dropping anything malformed rather than
/// failing: the setting can arrive over the API. Every string is trimmed,
/// an entry that is not a map or whose id, package or channelPrefix is
/// empty is dropped, a missing or empty label falls back to the package,
/// and the first of two entries sharing an id wins.
List<DoorbellSignature> decodeDoorbellSignatures(String json) {
  try {
    final raw = jsonDecode(json);
    if (raw is! List) return const [];
    final signatures = <DoorbellSignature>[];
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final id = '${item['id'] ?? ''}'.trim();
      final package = '${item['package'] ?? ''}'.trim();
      final channelPrefix = '${item['channelPrefix'] ?? ''}'.trim();
      if (id.isEmpty || package.isEmpty || channelPrefix.isEmpty) continue;
      if (!seen.add(id)) continue;
      var label = '${item['label'] ?? ''}'.trim();
      if (label.isEmpty) label = package;
      signatures.add(
        DoorbellSignature(
          id: id,
          label: label,
          package: package,
          channelPrefix: channelPrefix,
        ),
      );
    }
    return signatures;
  } catch (_) {
    return const [];
  }
}

/// Encode doorbell.signatures back to the JSON list it is stored as.
String encodeDoorbellSignatures(List<DoorbellSignature> signatures) =>
    jsonEncode([for (final signature in signatures) signature.toJson()]);
