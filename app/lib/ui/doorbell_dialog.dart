import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../managers/doorbell/doorbell_signature.dart';
import '../managers/doorbell/doorbell_manager.dart' show DoorbellCapture;
import '../managers/settings/definitions.dart' show doorbellEnabled;
import 'toast.dart';

/// The notifications section's Add doorbell flow: one dialog, three
/// screens. Choose the Eufy Security preset or learn from a real ring;
/// a learned ring is named and saved; the saved screen says the first
/// ring will tell whether it works. Returns true when a doorbell was
/// saved. The notifications switch must be on: the Add button only
/// exists while its section is.
Future<bool> showDoorbellNotificationDialog(
  BuildContext context,
  AppContainer container,
) async {
  // Whether a doorbell was saved: the dialog's answer.
  var saved = false;

  // The name the saved screen names.
  var savedName = '';

  // Which screen is up: choose, learn or saved.
  var step = 'choose';

  // One command at a time: while one runs, the buttons that start
  // commands are disabled, so a double tap cannot add a doorbell twice.
  var busy = false;

  // The command in flight now, so the close can wait for it.
  Future<CommandResult>? running;

  // A capture was started in this dialog: it tells a capture that
  // timed out from one that never started here.
  var started = false;

  // The name the caught notification is saved under.
  final nameController = TextEditingController();

  // The caught notification the name field was filled from.
  DoorbellCapture? namedFor;

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
    Future<CommandResult>? future;
    try {
      future = container.commands.execute(name, params);
      running = future;
      return await future;
    } finally {
      if (identical(running, future)) running = null;
      busy = false;
      if (dialogContext != null && dialogContext.mounted) {
        setState?.call(() {});
      }
    }
  }

  // Save the Eufy Security app, the doorbell this feature was built
  // against, then the saved screen.
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
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
    saved = true;
    savedName = eufySignature.label;
    setState(() => step = 'saved');
  }

  // Start catching the next doorbell notification: the dialog waits
  // on the manager's notifiers from here.
  Future<void> startCapture(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    setState(() {
      started = true;
      step = 'learn';
    });
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

  // Save the caught notification as one more doorbell, then the
  // saved screen.
  Future<void> save(BuildContext dialogContext, StateSetter setState) async {
    final caught = container.doorbell.captured.value;
    if (caught == null) return;
    final name = nameController.text.trim();
    final label = name.isEmpty ? caught.appLabel : name;
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellAddSignature',
      {
        'label': label,
        'package': caught.package,
        'channelPrefix': caught.channelPrefix,
      },
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
    container.doorbell.captured.value = null;
    saved = true;
    savedName = label;
    setState(() {
      started = false;
      step = 'saved';
    });
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return AlertDialog(
          title: const Text('Add a doorbell'),
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
                // caught notification.
                if (caught != null && !identical(namedFor, caught)) {
                  namedFor = caught;
                  nameController.text = caught.appLabel;
                }
                if (caught == null) namedFor = null;
                // The saved screen: the flow's answer.
                if (step == 'saved') {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Saved.'),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '$savedName is added. The first ring will show '
                          'here as "Working".',
                          style: small,
                        ),
                      ),
                    ],
                  );
                }
                // The caught screen: name the notification and save it.
                if (caught != null) {
                  return ListView(
                    shrinkWrap: true,
                    children: [
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
                                      setState(() {
                                        started = false;
                                        step = 'choose';
                                      });
                                    },
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                // The waiting screen: the capture runs.
                if (capturing) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                              : () => unawaited(stopCapture(context, setState)),
                          child: const Text('Cancel'),
                        ),
                      ),
                    ],
                  );
                }
                // The timed-out screen: nothing arrived in time.
                if (started) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                                  : () => setState(() {
                                      started = false;
                                      step = 'choose';
                                    }),
                              child: const Text('Cancel'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }
                // The choose screen: the preset or the learn flow.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Add the Eufy Security preset, or learn this doorbell '
                      'from a real ring.',
                      style: small,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: busy || !enabled
                                ? null
                                : () => unawaited(addEufy(context, setState)),
                            child: const Text('Eufy Security'),
                          ),
                          TextButton(
                            onPressed: busy || !enabled
                                ? null
                                : () => unawaited(
                                    startCapture(context, setState),
                                  ),
                            child: const Text('Learn from a ring'),
                          ),
                        ],
                      ),
                    ),
                    if (!enabled)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Turn on Doorbell video launch by notifications '
                          'first.',
                          style: small,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          actions: [
            if (step == 'saved')
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              )
            else
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
          ],
        );
      },
    ),
  );
  // The dialog is closing but still on screen, so the name
  // controller is left to the garbage collector: it holds no
  // resource, and disposing it under a mounted TextField is an
  // error. Whatever a running capture caught is forgotten and
  // the capture ends. A command still in flight is awaited
  // first, so it finishes (and its setting is saved) before the
  // caller reloads the list.
  final pending = running;
  if (pending != null) {
    try {
      await pending;
    } catch (_) {}
  }
  busy = false;
  if (container.doorbell.capturing.value) {
    await runCommand(null, null, 'doorbellStopCapture', const {});
  }
  container.doorbell.captured.value = null;
  return saved;
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
