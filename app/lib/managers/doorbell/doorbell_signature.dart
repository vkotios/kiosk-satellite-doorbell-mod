import 'dart:convert';

/// One doorbell camera the kiosk answers a ring from, in exactly one
/// of the two Doorbell sections: a notification doorbell (the Android
/// package and the channel prefix a ring arrives on, opened by the
/// notification's own tap action) or a sensor & tap doorbell (a Home
/// Assistant entity, opened by launching the app and clicking the
/// taught [clickLabel] card); plus the label the UI shows.
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

  /// Whether this is a sensor & tap doorbell: a Home Assistant entity
  /// rings it, and a ring opens by clicking its [clickLabel] card.
  bool get isSensor => entity.isNotEmpty;

  /// Whether this is a notification doorbell: no entity, a ring
  /// arrives as its app's notification on [channelPrefix], and a ring
  /// opens by the notification's own tap action.
  bool get isNotification => !isSensor && channelPrefix.isNotEmpty;

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

/// A Home Assistant entity id: [raw] trimmed and lower-cased, or null
/// when that is not `domain.object_id`, both parts letters, digits and
/// underscores.
String? normalizeDoorbellEntity(String raw) {
  final entity = raw.trim().toLowerCase();
  return RegExp(r'^[a-z0-9_]+\.[a-z0-9_]+$').hasMatch(entity)
      ? entity
      : null;
}

/// Decode doorbell.signatures, dropping anything malformed rather than
/// failing: the setting can arrive over the API. Every string is
/// trimmed, an entity that is not an entity id (see
/// [normalizeDoorbellEntity]) is treated as having none, and an entry
/// that is not a map or whose id or package is empty is dropped, as is
/// one nothing can ring (neither channelPrefix nor entity) and one a
/// Home Assistant ring could not open (an entity without a clickLabel).
/// A missing or empty label falls back to the package. An entry with
/// an entity is a sensor & tap doorbell: it opens by the click,
/// whatever was saved, and keeps a stored channelPrefix unused. An
/// entry without an entity is a notification doorbell: it opens by
/// the tap and carries no clickLabel, whatever was saved. The first
/// of two entries sharing an id wins.
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
      final entity = normalizeDoorbellEntity('${item['entity'] ?? ''}') ?? '';
      final clickLabel = '${item['clickLabel'] ?? ''}'.trim();
      if (id.isEmpty || package.isEmpty) continue;
      if (channelPrefix.isEmpty && entity.isEmpty) continue;
      if (entity.isNotEmpty && clickLabel.isEmpty) continue;
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
          // A sensor & tap doorbell always opens by click, whatever
          // was saved; a notification doorbell always by the tap.
          open: entity.isNotEmpty ? 'click' : 'tap',
          // A notification doorbell has no card to click: a stored
          // clickLabel is dropped.
          clickLabel: entity.isNotEmpty ? clickLabel : '',
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
