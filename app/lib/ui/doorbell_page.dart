import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/events.dart';
import '../core/lifecycle.dart';
import '../managers/sendspin/session_player.dart' show SessionPlayer;
import '../managers/settings/definitions.dart';
import 'doorbell_click_dialog.dart';
import 'doorbell_dialog.dart';
import 'doorbell_test_dialog.dart';
import 'entity_picker.dart';
import 'kit.dart';
import 'settings_screen.dart' show SettingTile;
import 'settings_search.dart';
import 'toast.dart';

/// The notifications section's one-line explanation, under its switch
/// and under its Add button while that is off.
const _notificationExplanation =
    'When your doorbell app shows its ring notification, open that '
    'camera over the kiosk. Needs Notification access.';

/// The sensor & tap section's one-line explanation, the same way.
const _sensorExplanation =
    'When a Home Assistant sensor says the doorbell is ringing, open '
    'the doorbell app and tap the camera\'s card. Needs Doorbell click '
    'access.';

/// The Doorbell page: two independent sections, each with its own
/// switch, grant, settings, its saved doorbells and its Add button. A
/// doorbell belongs to exactly one section: a notification doorbell
/// rings as its app's notification and opens by tapping it, a sensor &
/// tap doorbell rings when its Home Assistant sensor turns on and opens
/// by launching the app and tapping the taught card. Either, both or
/// neither section can be on; a switch off means that section's ring
/// path is fully inactive, so its grant, settings, list and Add button
/// are not shown at all.
List<Widget> doorbellSections(AppContainer container, VoidCallback onChanged) {
  return [
    SectionHeading('Notifications'),
    SettingsCard(
      children: [
        SettingTile(
          container: container,
          def: doorbellEnabled,
          onChanged: onChanged,
        ),
        const HintRow(_notificationExplanation),
        if (container.settings.get(doorbellEnabled)) ...[
          SearchLandingTarget(
            id: 'x:doorbell_permissions',
            child: _DoorbellPermissionsTile(container: container),
          ),
          SettingTile(
            container: container,
            def: doorbellReturnSeconds,
            onChanged: onChanged,
          ),
          DoorbellList(container: container, kind: 'notification'),
        ],
      ],
    ),
    SectionHeading('Home Assistant sensor & tap'),
    SettingsCard(
      children: [
        SettingTile(
          container: container,
          def: doorbellSensorEnabled,
          onChanged: onChanged,
        ),
        const HintRow(_sensorExplanation),
        if (container.settings.get(doorbellSensorEnabled)) ...[
          _DoorbellClickAccessTile(container: container),
          SettingTile(
            container: container,
            def: doorbellClickDelaySeconds,
            onChanged: onChanged,
          ),
          SettingTile(
            container: container,
            def: doorbellSensorReturnSeconds,
            onChanged: onChanged,
          ),
          DoorbellList(container: container, kind: 'sensor'),
        ],
      ],
    ),
  ];
}

/// One section's saved doorbells: a status line each, the sensor &
/// tap rows' Test and Edit, the Remove of both kinds, and the
/// section's Add button below. The list is the manager's, read and
/// changed through its commands so the native listener stays in step;
/// it reloads after every action and whenever the saved doorbells or
/// their last activity change on the bus.
class DoorbellList extends StatefulWidget {
  const DoorbellList({super.key, required this.container, required this.kind});

  final AppContainer container;

  /// Which section's doorbells this lists: 'notification' or 'sensor'.
  final String kind;

  @override
  State<DoorbellList> createState() => _DoorbellListState();
}

class _DoorbellListState extends State<DoorbellList> {
  final _entries = <Map>[];
  var _loaded = false;
  var _busy = false;
  StreamSubscription<SettingChanged>? _sub;

  AppContainer get container => widget.container;

  @override
  void initState() {
    super.initState();
    _sub = container.bus.on<SettingChanged>().listen((event) {
      final relevant = event.key == doorbellSignatures.key ||
          event.key == doorbellActivity.key;
      if (relevant && mounted) unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // The saved doorbells of this section, reloaded after every change.
  // A failed read keeps the list on screen; entries that are not maps
  // or not of this section's kind are skipped.
  Future<void> _reload() async {
    final result = await container.commands.execute(
      'doorbellSignatures',
      const {},
    );
    if (!mounted) return;
    if (!result.ok) {
      _toastFailure(context, result.error);
      return;
    }
    final data = result.data;
    setState(() {
      _loaded = true;
      _entries
        ..clear()
        ..addAll(
          data is List
              ? data
                    .whereType<Map>()
                    .where((entry) => '${entry['kind'] ?? ''}' == widget.kind)
              : const <Map>[],
        );
    });
  }

  // One command at a time: while one runs, the buttons that start
  // commands are disabled, so a double tap cannot fire two. A failure
  // is told as a toast; the caller reloads on success.
  Future<bool> _run(String name, Map<String, Object?> params) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      final result = await container.commands.execute(name, params);
      if (!mounted) return false;
      if (!result.ok) {
        _toastFailure(context, result.error);
        return false;
      }
      return true;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The section's Add doorbell: the notification flow or the sensor &
  // tap wizard, then the list reloads whatever the flow did.
  Future<void> _add() async {
    if (widget.kind == 'sensor') {
      await showDoorbellClickDialog(context, container);
    } else {
      await showDoorbellNotificationDialog(context, container);
    }
    await _reload();
  }

  // Open one saved doorbell the way a ring would, in the test dialog.
  // The test stores the doorbell's last activity; the reload shows the
  // new status line.
  Future<void> _test(Map entry) async {
    await showDoorbellTestDialog(
      context,
      container,
      id: '${entry['id'] ?? ''}',
      label: '${entry['label'] ?? entry['id'] ?? ''}',
    );
    await _reload();
  }

  // Forget one saved doorbell, after a confirmation.
  Future<void> _remove(Map entry) async {
    final label = '${entry['label'] ?? entry['id'] ?? ''}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this doorbell?'),
        content: Text('$label will no longer open on a ring.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await _run('doorbellRemoveSignature', {
      'id': '${entry['id'] ?? ''}',
    });
    if (removed) await _reload();
  }

  // Change a sensor & tap doorbell's name and ringing sensor. The
  // camera card it taps is not edited here: it is taught again.
  Future<void> _edit(Map entry) async {
    final id = '${entry['id'] ?? ''}';
    final nameController = TextEditingController(
      text: '${entry['label'] ?? ''}',
    );
    var entity = '${entry['entity'] ?? ''}';
    var busy = false;
    var saved = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Edit doorbell'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onChanged: (_) => setDialogState(() {}),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: LabeledField(
                    label: 'Ringing sensor',
                    helper:
                        'The Home Assistant sensor that is on while this '
                        'doorbell rings.',
                    child: PickFieldBox(
                      spec: entitySpec(
                        dialogContext,
                        container.commands,
                        domains: const ['binary_sensor'],
                      ),
                      value: entity,
                      onTap: () async {
                        final picked = await showEntityPicker(
                          dialogContext,
                          container,
                          title: 'Ringing sensor',
                          selected: entity,
                          domains: const ['binary_sensor'],
                        );
                        final pickedId = picked?.id;
                        if (pickedId == null || !dialogContext.mounted) return;
                        setDialogState(() => entity = pickedId);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: busy || nameController.text.trim().isEmpty
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      final result = await container.commands.execute(
                        'doorbellUpdateSignature',
                        {
                          'id': id,
                          'label': nameController.text.trim(),
                          'entity': entity,
                        },
                      );
                      if (!dialogContext.mounted) return;
                      if (!result.ok) {
                        setDialogState(() => busy = false);
                        _toastFailure(dialogContext, result.error);
                        return;
                      }
                      saved = true;
                      Navigator.pop(dialogContext);
                    },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // The name controller is left to the garbage collector, like the
    // add flow's: disposing it under a mounted TextField is an error.
    if (saved) await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = TextStyle(
      fontSize: 13,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_loaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          )
        else if (_entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No doorbell added yet.', style: small),
          )
        else
          for (final entry in _entries) _row(context, entry, small),
        _addRow(context, small),
      ],
    );
  }

  // One saved doorbell's row: the label, the manager's status line,
  // the state's icon, and what can be done with it.
  Widget _row(BuildContext context, Map entry, TextStyle small) {
    final theme = Theme.of(context);
    final state = '${entry['state'] ?? ''}';
    final icon = state == 'ready'
        ? Icons.check_circle_outline
        : state == 'failing'
        ? Icons.error_outline
        : Icons.schedule_outlined;
    final color = state == 'ready'
        ? theme.colorScheme.primary
        : state == 'failing'
        ? theme.colorScheme.error
        : null;
    final sensor = widget.kind == 'sensor';
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text('${entry['label'] ?? entry['id'] ?? ''}'),
      subtitle: Text('${entry['statusText'] ?? ''}', style: small),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (sensor) ...[
            IconButton(
              tooltip: 'Test',
              icon: const Icon(Icons.play_arrow_outlined),
              onPressed: _busy ? null : () => unawaited(_test(entry)),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _busy ? null : () => unawaited(_edit(entry)),
            ),
          ],
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline),
            onPressed: _busy ? null : () => unawaited(_remove(entry)),
          ),
        ],
      ),
    );
  }

  // The section's Add button. It only exists while its section's
  // switch is on, so the disabled state and the explanation under it
  // are safety.
  Widget _addRow(BuildContext context, TextStyle small) {
    final on = widget.kind == 'sensor'
        ? container.settings.get(doorbellSensorEnabled)
        : container.settings.get(doorbellEnabled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextButton.icon(
            onPressed: on && !_busy ? () => unawaited(_add()) : null,
            icon: const Icon(Icons.add),
            label: const Text('Add doorbell'),
          ),
        ),
        if (!on)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              widget.kind == 'sensor'
                  ? _sensorExplanation
                  : _notificationExplanation,
              style: small,
            ),
          ),
      ],
    );
  }
}

/// The notifications section's grant: the Notification access Android
/// shows a ring to no one without, in the Media Session tile's shape.
class _DoorbellPermissionsTile extends StatefulWidget {
  const _DoorbellPermissionsTile({required this.container});

  final AppContainer container;

  @override
  State<_DoorbellPermissionsTile> createState() =>
      _DoorbellPermissionsTileState();
}

class _DoorbellPermissionsTileState extends State<_DoorbellPermissionsTile>
    with WidgetsBindingObserver {
  bool? _granted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  final _returned = ReturnWatch();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The grant is given on an OS screen that reports nothing back.
    if (_returned.returned(state)) _refresh();
  }

  Future<void> _refresh() async {
    final granted = await SessionPlayer.hasAccess();
    if (!mounted) return;
    setState(() => _granted = granted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final granted = _granted;
    return SettingsRow(
      leading: Icon(
        granted == true
            ? Icons.check_circle_outline
            : Icons.notifications_off_outlined,
        color: granted == true ? null : theme.colorScheme.error,
      ),
      title: const Text('Notification access'),
      subtitle: Text(
        granted == true
            ? 'Kiosk Satellite sees a ring from the doorbell apps you '
                'saved. It reads notifications from those apps only, and '
                'for a short time while you capture a new doorbell.'
            : 'Without this Android never shows Kiosk Satellite a ring, '
                'so no doorbell can open.',
      ),
      trailing: granted == true
          ? null
          : TextButton(
              onPressed: () async {
                await widget.container.commands.execute(
                  'requestOsPermissions',
                  {
                    'which': ['notificationAccess'],
                  },
                );
                await _refresh();
              },
              child: const Text('Grant'),
            ),
    );
  }
}

/// The sensor & tap section's grant: the Accessibility service a
/// doorbell that opens by a tap on its card needs, in the
/// permissions tile's shape.
class _DoorbellClickAccessTile extends StatefulWidget {
  const _DoorbellClickAccessTile({required this.container});

  final AppContainer container;

  @override
  State<_DoorbellClickAccessTile> createState() =>
      _DoorbellClickAccessTileState();
}

class _DoorbellClickAccessTileState extends State<_DoorbellClickAccessTile>
    with WidgetsBindingObserver {
  bool? _running;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  final _returned = ReturnWatch();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The service is turned on on an OS screen that reports nothing
    // back.
    if (_returned.returned(state)) _refresh();
  }

  Future<void> _refresh() async {
    final result = await widget.container.commands.execute(
      'doorbellClickAccess',
      const {},
    );
    if (!mounted) return;
    if (!result.ok) {
      setState(() => _running = null);
      return;
    }
    final data = result.data;
    setState(() => _running = data is Map && data['running'] == true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _running;
    return SettingsRow(
      leading: Icon(
        running == true ? Icons.check_circle_outline : Icons.touch_app_outlined,
        color: running == true ? null : theme.colorScheme.error,
      ),
      title: const Text('Doorbell click access'),
      subtitle: Text(
        running == true
            ? 'Kiosk Satellite can tap your doorbell camera. It reads '
                'the doorbell app\'s screen only while it taps, and does '
                'nothing in any other app.'
            : 'Without this Kiosk Satellite cannot tap the camera, so a '
                'doorbell that rings by a Home Assistant sensor cannot '
                'open. Turn it on in Android Accessibility settings '
                '(find Kiosk Satellite there).',
      ),
      trailing: running == true
          ? null
          : TextButton(
              onPressed: () async {
                await widget.container.commands.execute(
                  'doorbellOpenClickSettings',
                  const {},
                );
                await _refresh();
              },
              child: const Text('Open'),
            ),
    );
  }
}

/// A doorbell command that did not go through, told the way the
/// launcher's app picker tells its own failure.
void _toastFailure(BuildContext context, String? error) {
  showToast(
    context,
    title: 'Could not update the doorbells',
    message: error,
    kind: ToastKind.error,
  );
}
