import 'dart:convert';

/// One doorbell camera the kiosk answers a ring from: a notification
/// (the Android package and the channel prefix a ring arrives on), a
/// Home Assistant entity, or both; how a ring opens; and the label
/// the UI shows.
class DoorbellSignature {
  const DoorbellSignature({
    required this.id,
    required this.label,
    required this.package,
    this.channelPrefix = '',
    this.entity = '',
    this.open = 'tap',
    this.clickLabel = '',
  });

  /// Unique and non-empty, e.g. 'eufy'.
  final String id;

  /// What the UI shows, e.g. 'Eufy Security'.
  final String label;

  /// The Android package whose notifications are the rings.
  final String package;

  /// A ring's notification channel id starts with this.
  final String channelPrefix;

  /// The Home Assistant entity that rings, e.g.
  /// 'binary_sensor.front_door_ringing'.
  final String entity;

  /// How a ring is opened: 'tap' fires the ring notification's own tap
  /// action, 'click' launches the app and clicks the [clickLabel] card.
  final String open;

  /// The card a 'click' ring opens, e.g. 'Front door'.
  final String clickLabel;

  /// Whether a ring notification can ring this doorbell.
  bool get rungByNotification => channelPrefix.isNotEmpty;

  /// Whether a Home Assistant entity can ring this doorbell.
  bool get rungByEntity => entity.isNotEmpty;

  /// Whether a ring opens by clicking the [clickLabel] card.
  bool get opensByClick => open == 'click';

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'package': package,
        'channelPrefix': channelPrefix,
        if (entity.isNotEmpty) 'entity': entity,
        if (open == 'click') 'open': open,
        if (clickLabel.isNotEmpty) 'clickLabel': clickLabel,
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
/// failing: the setting can arrive over the API. Every string is
/// trimmed, an entry that is not a map or whose id or package is empty
/// is dropped, as is one nothing can ring (neither channelPrefix nor
/// entity), one a Home Assistant ring could not open (an entity without
/// a clickLabel), and one that opens by a click without a clickLabel.
/// A missing or empty label falls back to the package, 'open' is
/// 'click' only when stored as exactly that, and the first of two
/// entries sharing an id wins.
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
      final entity = '${item['entity'] ?? ''}'.trim();
      final clickLabel = '${item['clickLabel'] ?? ''}'.trim();
      final open =
          '${item['open'] ?? ''}'.trim() == 'click' ? 'click' : 'tap';
      if (id.isEmpty || package.isEmpty) continue;
      if (channelPrefix.isEmpty && entity.isEmpty) continue;
      if (entity.isNotEmpty && clickLabel.isEmpty) continue;
      if (open == 'click' && clickLabel.isEmpty) continue;
      if (!seen.add(id)) continue;
      var label = '${item['label'] ?? ''}'.trim();
      if (label.isEmpty) label = package;
      signatures.add(
        DoorbellSignature(
          id: id,
          label: label,
          package: package,
          channelPrefix: channelPrefix,
          entity: entity,
          open: open,
          clickLabel: clickLabel,
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
