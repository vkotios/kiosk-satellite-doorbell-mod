import 'dart:convert';

import 'doorbell_signature.dart';

/// What a doorbell last did: a Test or a real ring, when, how it ended
/// and anything worth adding about that. Stored per doorbell id in the
/// internal.doorbell_activity setting and shown as the status text of
/// both Doorbell UIs.
class DoorbellActivity {
  const DoorbellActivity({
    required this.at,
    required this.kind,
    required this.result,
    this.detail = '',
  });

  /// When it happened.
  final DateTime at;

  /// What ran: 'test' (the Test button) or 'ring' (a real ring).
  final String kind;

  /// How it ended. A sensor & tap doorbell ends in 'clicked',
  /// 'not_found', 'wrong_app', 'service_off', 'launch_failed' or
  /// 'timeout'; a notification doorbell's tap in 'opened' or
  /// 'not_opened'.
  final String result;

  /// Extra context, e.g. the error a failed open returned.
  final String detail;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'kind': kind,
        'result': result,
        'detail': detail,
      };

  /// One stored activity, or null when [json] is not a map with a
  /// parseable 'at' and a non-empty 'result': an activity without a
  /// time or an outcome says nothing.
  static DoorbellActivity? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse('${json['at'] ?? ''}');
    if (at == null) return null;
    final result = '${json['result'] ?? ''}'.trim();
    if (result.isEmpty) return null;
    return DoorbellActivity(
      at: at,
      kind: '${json['kind'] ?? ''}'.trim(),
      result: result,
      detail: '${json['detail'] ?? ''}'.trim(),
    );
  }
}

/// Decode internal.doorbell_activity, dropping anything malformed
/// rather than failing: the setting can arrive over the API. A string
/// that is not a JSON map gives an empty map, and so does an entry that
/// is not a map or holds no activity (see [DoorbellActivity.fromJson]).
Map<String, DoorbellActivity> decodeDoorbellActivity(String json) {
  try {
    final raw = jsonDecode(json);
    if (raw is! Map) return {};
    final activity = <String, DoorbellActivity>{};
    for (final entry in raw.entries) {
      final id = '${entry.key}'.trim();
      final one = DoorbellActivity.fromJson(entry.value);
      if (id.isEmpty || one == null) continue;
      activity[id] = one;
    }
    return activity;
  } catch (_) {
    return {};
  }
}

/// Encode internal.doorbell_activity back to the JSON map it is
/// stored as.
String encodeDoorbellActivity(Map<String, DoorbellActivity> activity) =>
    jsonEncode({
      for (final entry in activity.entries) entry.key: entry.value.toJson(),
    });

/// The local HH:mm an activity happened at, the form the status texts
/// show their times in.
String _hhmm(DateTime at) {
  final local = at.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Why a sensor & tap doorbell's click did not open it, per result; an
/// unknown result says itself.
String _clickReason(DoorbellSignature signature, String result) {
  switch (result) {
    case 'not_found':
      return 'could not find the card "${signature.clickLabel}"';
    case 'wrong_app':
      return 'the doorbell app did not come to the front';
    case 'service_off':
      return 'Doorbell click access is off';
    case 'launch_failed':
      return 'could not open the app';
    case 'timeout':
      return 'the click service did not answer';
    default:
      return result;
  }
}

/// What the Doorbell UIs say about [signature] given its last activity
/// [a], null when it never did anything. A sensor & tap doorbell that
/// was never tested asks for a Test, one whose last click landed is
/// ready and one whose did not says why; a notification doorbell waits
/// for its first ring and then says whether it opened.
String doorbellStatusText(DoorbellSignature signature, DoorbellActivity? a) {
  if (signature.isSensor) {
    if (a == null) return 'Not tested yet. Press Test.';
    final when = _hhmm(a.at);
    if (a.result == 'clicked') {
      return a.kind == 'ring'
          ? 'Ready. Last ring opened $when.'
          : 'Ready. Last tested OK $when.';
    }
    final reason = _clickReason(signature, a.result);
    if (a.result == 'not_found' ||
        a.result == 'wrong_app' ||
        a.result == 'service_off' ||
        a.result == 'launch_failed' ||
        a.result == 'timeout') {
      return 'Not working: $reason. $when.';
    }
    return 'Not working: $reason.';
  }
  if (a == null) return 'Waiting for the first ring.';
  final when = _hhmm(a.at);
  if (a.result == 'opened') return 'Working. Last ring opened $when.';
  if (a.result == 'not_opened') return 'Last ring at $when did not open.';
  return 'Not working: ${a.result}.';
}

/// The state behind [doorbellStatusText]: 'untested', 'ready' or
/// 'failing' for a sensor & tap doorbell, 'waiting', 'ready' or
/// 'failing' for a notification doorbell.
String doorbellState(DoorbellSignature signature, DoorbellActivity? a) {
  if (signature.isSensor) {
    if (a == null) return 'untested';
    return a.result == 'clicked' ? 'ready' : 'failing';
  }
  if (a == null) return 'waiting';
  return a.result == 'opened' ? 'ready' : 'failing';
}
