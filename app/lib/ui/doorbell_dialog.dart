import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../managers/doorbell/doorbell_signature.dart';
import '../managers/doorbell/doorbell_manager.dart' show DoorbellCapture;
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

  // The list from the manager; a failed read keeps the list on screen,
  // and entries that are not maps are skipped.
  Future<void> reload(BuildContext dialogContext, StateSetter setState) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellSignatures',
      const {},
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
    setState(() {
      signatures = result.ok && result.data is List
          ? (result.data as List).whereType<Map>().toList()
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
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
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
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
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
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
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
                // caught notification.
                if (caught != null && !identical(namedFor, caught)) {
                  namedFor = caught;
                  nameController.text = caught.appLabel;
                }
                if (caught == null) namedFor = null;
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
                          title: Text(
                            '${signature['label'] ?? signature['id'] ?? ''}',
                          ),
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
  // The dialog is closing but still on screen, so the name
  // controller is left to the garbage collector: it holds no
  // resource, and disposing it under a mounted TextField is an
  // error. Whatever a running capture caught is forgotten and
  // the capture ends. A command still in flight is awaited
  // first, so it finishes (and its setting is saved) before the
  // settings page rebuilds its Doorbells row.
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
