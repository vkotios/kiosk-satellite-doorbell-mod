import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../managers/doorbell/doorbell_signature.dart';
import '../managers/settings/definitions.dart' show doorbellEnabled;
import 'toast.dart';

/// The Doorbell page: the saved doorbells, each with a Remove, a
/// one-tap Add Eufy Security below the list, and the capture that
/// waits for another doorbell's ring notification and saves it as
/// one more doorbell. The list is the manager's, read and changed
/// through its commands so the native listener stays in step.
Future<void> showDoorbellDialog(
  BuildContext context,
  AppContainer container,
) async {
  // The saved doorbells the list shows, reloaded after every change.
  var signatures = <Map>[];
  var loaded = false;

  // One command at a time: while one runs, the buttons that start
  // commands are disabled, so a double tap cannot add a doorbell twice.
  var busy = false;

  // A capture was started in this dialog: it tells a capture that
  // timed out from one that never started here.
  var started = false;

  // The name the caught notification is saved under.
  final nameController = TextEditingController();

  // Whether the caught screen has filled the name field for the
  // notification it is showing.
  var named = false;

  // Every command the dialog runs goes through here, one at a time.
  // It returns null when a command already runs. The context and
  // setState are null once the dialog has closed and there is
  // nothing left to rebuild.
  Future<CommandResult?> runCommand(
    BuildContext? dialogContext,
    StateSetter? setState,
    String name,
    Map<String, Object?> params,
  ) async {
    if (busy) return null;
    busy = true;
    // The buttons rebuild disabled; the guard above already stops a
    // second command even before that.
    if (dialogContext != null && dialogContext.mounted) {
      setState?.call(() {});
    }
    try {
      return await container.commands.execute(name, params);
    } finally {
      busy = false;
      if (dialogContext != null && dialogContext.mounted) {
        setState?.call(() {});
      }
    }
  }

  // The list from the manager: anything but a list of maps counts as
  // empty, the same tolerant read the setting itself gets.
  Future<void> reload(BuildContext dialogContext, StateSetter setState) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellSignatures',
      const {},
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    setState(() {
      signatures = result.ok && result.data is List
          ? (result.data as List).cast<Map>()
          : <Map>[];
    });
  }

  // Forget one saved doorbell, then reload the list to match.
  Future<void> remove(
    BuildContext dialogContext,
    StateSetter setState,
    String id,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellRemoveSignature',
      {'id': id},
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    await reload(dialogContext, setState);
  }

  // Save the Eufy Security app, the doorbell this feature was built
  // against, then reload the list to match.
  Future<void> addEufy(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellAddSignature',
      {
        'label': eufySignature.label,
        'package': eufySignature.package,
        'channelPrefix': eufySignature.channelPrefix,
      },
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    await reload(dialogContext, setState);
  }

  // Start catching the next doorbell notification: the dialog waits
  // on the manager's notifiers from here.
  Future<void> startCapture(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    setState(() => started = true);
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellStartCapture',
      const {},
    );
    if (result == null || result.ok) return;
    if (!dialogContext.mounted) return;
    setState(() => started = false);
    _toastFailure(dialogContext, result.error);
  }

  // Stop the running capture: the waiting screen's Cancel comes here.
  Future<void> stopCapture(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    await runCommand(
      dialogContext,
      setState,
      'doorbellStopCapture',
      const {},
    );
    if (dialogContext.mounted) setState(() => started = false);
  }

  // Save the caught notification as one more doorbell, then back to
  // the list.
  Future<void> save(BuildContext dialogContext, StateSetter setState) async {
    final caught = container.doorbell.captured.value;
    if (caught == null) return;
    final name = nameController.text.trim();
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellAddSignature',
      {
        'label': name.isEmpty ? caught.appLabel : name,
        'package': caught.package,
        'channelPrefix': caught.channelPrefix,
      },
    );
    if (result == null) return;
    if (!dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    container.doorbell.captured.value = null;
    setState(() => started = false);
    await reload(dialogContext, setState);
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        // The list loads once, when the dialog first builds. The
        // load is a command too, so it goes through the wrapper,
        // whose setState must not run inside this build.
        if (!loaded) {
          loaded = true;
          unawaited(
            Future<void>.delayed(Duration.zero, () async {
              if (!context.mounted) return;
              await reload(context, setState);
            }),
          );
        }
        final hasEufy = signatures.any(
          (signature) => signature['package'] == eufySignature.package,
        );
        return AlertDialog(
          title: const Text('Doorbells'),
          content: SizedBox(
            width: 420,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                container.doorbell.capturing,
                container.doorbell.captured,
              ]),
              builder: (context, _) {
                final caught = container.doorbell.captured.value;
                final capturing = container.doorbell.capturing.value;
                final enabled = container.settings.get(doorbellEnabled);
                final small = TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                );
                // The caught screen fills the name once per
                // notification, not on every rebuild.
                if (caught != null && !named) {
                  named = true;
                  nameController.text = caught.appLabel;
                }
                if (caught == null) named = false;
                return ListView(
                  shrinkWrap: true,
                  children: [
                    if (caught != null) ...[
                      Text('Caught a notification from ${caught.appLabel}.'),
                      if (caught.title.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('Title: ${caught.title}', style: small),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Channel: ${caught.channelPrefix}',
                          style: small,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: TextField(
                          controller: nameController,
                          decoration: const InputDecoration(
                            labelText: 'Name this doorbell',
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => unawaited(save(context, setState)),
                              child: const Text('Save'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      container.doorbell.captured.value = null;
                                      unawaited(
                                        startCapture(context, setState),
                                      );
                                    },
                              child: const Text('Try again'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      container.doorbell.captured.value = null;
                                      setState(() => started = false);
                                    },
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ] else if (capturing) ...[
                      const Text('Press your doorbell now.'),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Waiting up to 60 seconds for its notification. '
                          'Kiosk Satellite reads notifications from other '
                          'apps only while this waits, and keeps only what '
                          'you save.',
                          style: small,
                        ),
                      ),
                      const LinearProgressIndicator(),
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => unawaited(
                                    stopCapture(context, setState),
                                  ),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ] else if (started) ...[
                      const Text('No notification arrived in time.'),
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => unawaited(
                                        startCapture(context, setState),
                                      ),
                              child: const Text('Try again'),
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => setState(() => started = false),
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      if (signatures.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text('No doorbell saved yet.'),
                        ),
                      for (final signature in signatures)
                        ListTile(
                          title: Text('${signature['label']}'),
                          trailing: IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: busy
                                ? null
                                : () => unawaited(
                                      remove(
                                        context,
                                        setState,
                                        '${signature['id']}',
                                      ),
                                    ),
                          ),
                        ),
                      if (!hasEufy)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => unawaited(addEufy(context, setState)),
                          child: const Text('Add Eufy Security'),
                        ),
                      TextButton(
                        onPressed: busy || !enabled
                            ? null
                            : () => unawaited(startCapture(context, setState)),
                        child: const Text('Capture a doorbell'),
                      ),
                      if (!enabled)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Turn on "Open the doorbell app on a ring" first.',
                            style: small,
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
  // However the dialog closed, a capture that still runs ends here,
  // and whatever it caught is forgotten. The buttons are gone, so
  // the one-at-a-time guard no longer applies and cannot be left
  // holding the stop back.
  busy = false;
  if (container.doorbell.capturing.value) {
    await runCommand(null, null, 'doorbellStopCapture', const {});
  }
  container.doorbell.captured.value = null;
  nameController.dispose();
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
