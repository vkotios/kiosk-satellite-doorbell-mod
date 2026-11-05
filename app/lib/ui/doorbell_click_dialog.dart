import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../managers/doorbell/doorbell_manager.dart' show DoorbellClickCapture;
import '../managers/settings/definitions.dart' show doorbellEnabled;
import 'entity_picker.dart';
import 'kit.dart';
import 'toast.dart';

/// The Eufy Security package, the app this wizard was built against.
const _eufyPackage = 'com.oceanwing.battery.cam';

/// The "Add a camera doorbell" wizard: pick the doorbell's app, turn
/// on the Doorbell click access, teach the camera by tapping its card
/// in the app, pick the Home Assistant sensor that rings it, then
/// save and test the open. Returns true when a doorbell was saved.
Future<bool> showDoorbellClickDialog(
  BuildContext context,
  AppContainer container,
) async {
  // The wizard's step, 1 to 5.
  var step = 1;

  // One command at a time: while one runs, the buttons that start
  // commands are disabled, so a double tap cannot run two.
  var busy = false;

  // The command in flight now, so the close can wait for it.
  Future<CommandResult>? running;

  // Step 2's click access check: whether it was asked for this entry
  // into the step, whether an answer arrived, and what it was.
  var accessAsked = false;
  var accessKnown = false;
  var accessOn = false;

  // A click capture was started in this dialog: it tells a capture
  // that timed out from one that never started here.
  var started = false;

  // The doorbell was saved: what the dialog returns. Its id feeds the
  // Test open button.
  var saved = false;
  var savedId = '';

  // The Android package of the doorbell app.
  final packageController = TextEditingController();

  // The card the click capture caught, which the user may correct.
  final labelController = TextEditingController();

  // The name the doorbell is saved under.
  final nameController = TextEditingController();

  // The Home Assistant entity that rings this doorbell.
  var entity = '';

  // The caught click the label field was filled from.
  DoorbellClickCapture? namedFor;

  // The name field was filled from the card label once.
  var namedFromLabel = false;

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

  // Ask whether the Doorbell click access service runs: step 2 opens
  // with this, and its Check again button repeats it.
  Future<void> checkAccess(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellClickAccess',
      const {},
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      setState(() => accessKnown = true);
      return;
    }
    final data = result.data;
    setState(() {
      accessKnown = true;
      accessOn = data is Map && data['running'] == true;
    });
  }

  // Open Android's Accessibility settings, where the Doorbell click
  // access service is turned on.
  Future<void> openClickSettings(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellOpenClickSettings',
      const {},
    );
    if (result == null || result.ok || !dialogContext.mounted) return;
    _toastFailure(dialogContext, result.error);
  }

  // Open the doorbell app and wait for the user to tap its camera:
  // the step listens on the manager's notifiers from here.
  Future<void> startCapture(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    setState(() => started = true);
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellStartClickCapture',
      {'package': packageController.text.trim()},
    );
    if (result == null || result.ok) return;
    if (!dialogContext.mounted) return;
    setState(() => started = false);
    _toastFailure(dialogContext, result.error);
  }

  // Stop the running click capture: the waiting screen's Cancel comes
  // here.
  Future<void> stopCapture(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    await runCommand(
      dialogContext,
      setState,
      'doorbellStopClickCapture',
      const {},
    );
    if (dialogContext.mounted) setState(() => started = false);
  }

  // Save the doorbell: the name, the app, the card to click and the
  // sensor that rings it.
  Future<void> save(BuildContext dialogContext, StateSetter setState) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellAddSignature',
      {
        'label': nameController.text.trim(),
        'package': packageController.text.trim(),
        'channelPrefix': '',
        'entity': entity,
        'open': 'click',
        'clickLabel': labelController.text.trim(),
      },
    );
    if (result == null || !dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
    final data = result.data;
    setState(() {
      saved = true;
      savedId = data is Map ? '${data['id'] ?? ''}' : '';
    });
  }

  // Open the saved doorbell the way a ring would, to check that the
  // click finds the camera.
  Future<void> testOpen(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellTestOpen',
      {'id': savedId},
    );
    if (result == null || result.ok || !dialogContext.mounted) return;
    _toastFailure(dialogContext, result.error);
  }

  await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        // Entering step 2 checks the click access, every time the
        // step is entered. The check is a command too, so it goes
        // through the wrapper, whose setState must not run inside
        // this build.
        if (step == 2 && !accessAsked) {
          accessAsked = true;
          unawaited(
            Future<void>.delayed(Duration.zero, () async {
              if (!context.mounted) return;
              await checkAccess(context, setState);
            }),
          );
        }
        // The name starts as the card label, filled once when the
        // step first shows, and only when nothing was typed yet.
        if (step == 4 && !namedFromLabel) {
          namedFromLabel = true;
          if (nameController.text.trim().isEmpty) {
            nameController.text = labelController.text.trim();
          }
        }
        final enabled = container.settings.get(doorbellEnabled);
        final small = TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        final List<Widget> rows;
        if (step == 1) {
          rows = [
            const Text('Which app is this doorbell in?'),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton(
                onPressed: busy
                    ? null
                    : () => setState(
                        () => packageController.text = _eufyPackage,
                      ),
                child: const Text('Eufy Security'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextField(
                controller: packageController,
                decoration: const InputDecoration(
                  labelText: 'Android package',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (!enabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Turn on "Open the doorbell app on a ring" first.',
                  style: small,
                ),
              ),
          ];
        } else if (step == 2) {
          final Widget status;
          if (!accessKnown) {
            status = const Text('Checking the click access.');
          } else if (accessOn) {
            status = const Text('Doorbell click access is on.');
          } else {
            status = const Text(
              "Doorbell click access is off. Turn it on in Android's "
              'Accessibility settings (find Kiosk Satellite there), then '
              'come back and check again.',
            );
          }
          rows = [
            status,
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => unawaited(checkAccess(context, setState)),
                    child: const Text('Check again'),
                  ),
                  if (accessKnown && !accessOn)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => unawaited(
                              openClickSettings(context, setState),
                            ),
                      child: const Text('Open Accessibility settings'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'It reads the screen of your doorbell app only while it '
                'taps a camera, and does nothing in any other app.',
                style: small,
              ),
            ),
          ];
        } else if (step == 3) {
          final startButton = Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
              onPressed: busy
                  ? null
                  : () => unawaited(startCapture(context, setState)),
              child: const Text('Open the app and wait'),
            ),
          );
          rows = [
            const Text(
              'Open your doorbell app and tap the camera of this doorbell.',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  container.doorbell.clickCapturing,
                  container.doorbell.clickCaptured,
                ]),
                builder: (context, _) {
                  final capturing = container.doorbell.clickCapturing.value;
                  final caught = container.doorbell.clickCaptured.value;
                  // The caught card fills the label once per caught
                  // click.
                  if (caught != null && !identical(namedFor, caught)) {
                    namedFor = caught;
                    labelController.text = caught.label;
                  }
                  if (caught == null) namedFor = null;
                  if (caught != null) {
                    return Text('Caught: ${caught.label}');
                  }
                  if (capturing) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Waiting up to 90 seconds for your tap.',
                        ),
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: TextButton(
                            onPressed: busy
                                ? null
                                : () => unawaited(
                                    stopCapture(context, setState),
                                  ),
                            child: const Text('Cancel capture'),
                          ),
                        ),
                      ],
                    );
                  }
                  if (started) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Nothing was tapped in time.'),
                        startButton,
                      ],
                    );
                  }
                  return startButton;
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: labelController,
                decoration: const InputDecoration(labelText: 'Card label'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ];
        } else if (step == 4) {
          rows = [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => setState(() {}),
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
                    context,
                    container.commands,
                    domains: const ['binary_sensor'],
                  ),
                  value: entity,
                  onTap: () async {
                    final picked = await showEntityPicker(
                      context,
                      container,
                      title: 'Ringing sensor',
                      selected: entity,
                      domains: const ['binary_sensor'],
                    );
                    final id = picked?.id;
                    if (id == null) return;
                    if (!context.mounted) return;
                    setState(() => entity = id);
                  },
                ),
              ),
            ),
          ];
        } else {
          // What the last step shows before saving: the choices the
          // earlier steps made.
          final summary = <String, String>{
            'Name': nameController.text.trim(),
            'App package': packageController.text.trim(),
            'Card label': labelController.text.trim(),
            'Ringing sensor': entity,
          };
          rows = [
            for (final entry in summary.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${entry.key}: ${entry.value}'),
              ),
            if (saved)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Saved.'),
              ),
          ];
        }
        return AlertDialog(
          title: const Text('Add a camera doorbell'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Step $step of 5', style: small),
                ),
                ...rows,
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            if (step > 1 && step < 5)
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        step = step - 1;
                        // Entering step 2 again checks the access anew.
                        if (step == 2) accessAsked = false;
                      }),
                child: const Text('Back'),
              ),
            if (step == 1)
              TextButton(
                onPressed:
                    busy || !enabled || packageController.text.trim().isEmpty
                        ? null
                        : () => setState(() {
                            step = 2;
                            accessAsked = false;
                          }),
                child: const Text('Next'),
              )
            else if (step == 2)
              TextButton(
                onPressed: busy || !accessOn
                    ? null
                    : () => setState(() => step = 3),
                child: const Text('Next'),
              )
            else if (step == 3)
              TextButton(
                onPressed: busy || labelController.text.trim().isEmpty
                    ? null
                    : () => setState(() => step = 4),
                child: const Text('Next'),
              )
            else if (step == 4)
              TextButton(
                onPressed:
                    busy ||
                        nameController.text.trim().isEmpty ||
                        entity.isEmpty
                    ? null
                    : () => setState(() => step = 5),
                child: const Text('Next'),
              )
            else if (!saved)
              TextButton(
                onPressed: busy
                    ? null
                    : () => unawaited(save(context, setState)),
                child: const Text('Save'),
              )
            else ...[
              TextButton(
                onPressed: busy
                    ? null
                    : () => unawaited(testOpen(context, setState)),
                child: const Text('Test open'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Done'),
              ),
            ],
          ],
        );
      },
    ),
  );
  // The dialog is closing but still on screen, so the text
  // controllers are left to the garbage collector: they hold no
  // resource, and disposing them under a mounted TextField is an
  // error. A click capture still running is ended, whatever it
  // caught is forgotten, and a command still in flight is awaited
  // first, so it finishes before the caller rebuilds.
  final pending = running;
  if (pending != null) {
    try {
      await pending;
    } catch (_) {}
  }
  busy = false;
  if (container.doorbell.clickCapturing.value) {
    await runCommand(null, null, 'doorbellStopClickCapture', const {});
  }
  container.doorbell.clickCaptured.value = null;
  return saved;
}

/// A doorbell command that did not go through, told the way the
/// doorbell page tells its own failures.
void _toastFailure(BuildContext context, String? error) {
  showToast(
    context,
    title: 'Could not add the doorbell',
    message: error,
    kind: ToastKind.error,
  );
}
