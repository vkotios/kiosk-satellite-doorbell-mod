import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import '../managers/doorbell/doorbell_manager.dart' show DoorbellClickCapture;
import '../managers/settings/definitions.dart' show doorbellSensorEnabled;
import 'doorbell_test_dialog.dart';
import 'entity_picker.dart';
import 'kit.dart';
import 'toast.dart';

/// The Eufy Security package, the app this wizard was built against.
const _eufyPackage = 'com.oceanwing.battery.cam';

/// The five steps' titles, shown bold under the 'Step N of 5' line.
const _stepTitles = {
  1: 'Choose the doorbell app',
  2: 'Allow Kiosk Satellite to tap',
  3: 'Show me the camera',
  4: 'Name it and choose its sensor',
  5: 'Save and test',
};

/// The "Add sensor & tap doorbell" wizard: choose the doorbell's app,
/// allow Kiosk Satellite to tap, teach the camera by tapping its card
/// in the app, name the doorbell and pick the Home Assistant sensor
/// that rings it, then save it and run the real test. The Ready screen
/// shows only after the test's tap worked; a failed test leaves the
/// doorbell saved, with the manager's status and the choice to test
/// or teach again. Returns true when a doorbell was saved.
Future<bool> showDoorbellClickDialog(
  BuildContext context,
  AppContainer container,
) async {
  // The wizard's step, 1 to 5, while the screen is the wizard's.
  var step = 1;

  // The screen the dialog shows: the wizard's steps, or the Ready or
  // the not-working screen the test's answer leads to.
  var screen = 'steps';

  // The manager's status line for the doorbell this run saved, shown
  // on the not-working screen; the plain fallback until it is read.
  var failText = 'the test failed';

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

  // The start command is still opening the app: the waiting text
  // must not say nothing was tapped while it runs.
  var starting = false;

  // The doorbell was saved: what the dialog returns. Its id feeds the
  // test dialog, and tells a later pass to update, not add.
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

  // The package the caught card was caught under: a catch from
  // another package must not survive a package change.
  var taughtPackage = '';

  // The caught click the name field was filled from, and the
  // label it filled it with: a new catch refills a name the user
  // did not change by hand.
  DoorbellClickCapture? nameFilledFor;
  var nameFilledValue = '';

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
    setState(() {
      started = true;
      starting = true;
    });
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellStartClickCapture',
      {'package': packageController.text.trim()},
    );
    if (!dialogContext.mounted) return;
    setState(() => starting = false);
    if (result == null || result.ok) return;
    setState(() => started = false);
    _toastFailure(dialogContext, result.error);
  }

  // Stop the running click capture: the waiting screen's Cancel
  // comes here, and so do the buttons that leave step 3.
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

  // Go back one step: a click capture step 3 still runs is ended
  // first, so none is left running behind the dialog.
  Future<void> goBack(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    if (step == 3 && container.doorbell.clickCapturing.value) {
      await stopCapture(dialogContext, setState);
      if (!dialogContext.mounted) return;
    }
    setState(() {
      step = step - 1;
      // Entering step 2 again checks the access anew.
      if (step == 2) accessAsked = false;
    });
  }

  // Leave step 3 forward: a click capture still running is ended
  // first, so none runs on the later steps.
  Future<void> leaveStep3(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    if (container.doorbell.clickCapturing.value) {
      await stopCapture(dialogContext, setState);
      if (!dialogContext.mounted) return;
    }
    setState(() => step = 4);
  }

  // The manager's status line for the doorbell this run saved, for
  // the not-working screen; the plain fallback when it cannot be
  // read.
  Future<String> savedStatusText(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await runCommand(
      dialogContext,
      setState,
      'doorbellSignatures',
      const {},
    );
    if (result == null || !result.ok || result.data is! List) {
      return 'the test failed';
    }
    for (final entry in result.data as List) {
      if (entry is Map && '${entry['id'] ?? ''}' == savedId) {
        final text = '${entry['statusText'] ?? ''}';
        if (text.isNotEmpty) return text;
      }
    }
    return 'the test failed';
  }

  // Run the real test for the doorbell this run saved, in the test
  // dialog: it opens the app, tries the tap and shows the outcome
  // itself. The Ready screen shows only when it says the tap worked;
  // otherwise the not-working screen shows the manager's status line.
  Future<void> runTest(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final passed = await showDoorbellTestDialog(
      dialogContext,
      container,
      id: savedId,
      label: nameController.text.trim(),
    );
    if (!dialogContext.mounted) return;
    if (passed) {
      setState(() => screen = 'done');
      return;
    }
    final status = await savedStatusText(dialogContext, setState);
    if (!dialogContext.mounted) return;
    setState(() {
      failText = status;
      screen = 'failed';
    });
  }

  // Save the doorbell and run the real test. The first pass adds the
  // doorbell and remembers its id; a later pass (after a failed test
  // and a re-teach) updates the one this run already saved, so a
  // doorbell is never saved twice.
  Future<void> saveAndTest(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final name = nameController.text.trim();
    final card = labelController.text.trim();
    final CommandResult? result;
    if (savedId.isEmpty) {
      result = await runCommand(
        dialogContext,
        setState,
        'doorbellAddSignature',
        {
          'label': name,
          'package': packageController.text.trim(),
          'channelPrefix': '',
          'entity': entity,
          'open': 'click',
          'clickLabel': card,
        },
      );
    } else {
      result = await runCommand(
        dialogContext,
        setState,
        'doorbellUpdateSignature',
        {'id': savedId, 'label': name, 'entity': entity, 'clickLabel': card},
      );
    }
    if (result == null) return;
    if (result.ok) {
      // The doorbell is saved the moment the command says so, even
      // when a Cancel closed the dialog meanwhile: the dialog still
      // reports it saved.
      saved = true;
      final data = result.data;
      final id = data is Map ? '${data['id'] ?? ''}' : '';
      if (id.isNotEmpty) savedId = id;
    }
    if (!dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      return;
    }
    await runTest(dialogContext, setState);
  }

  // The dialog's setState and whether the dialog is already
  // closed: the capture listener rebuilds the dialog through
  // them.
  StateSetter? dialogSetState;
  var closed = false;

  // The caught card fills the label field from here: writing the
  // controller inside the step's builder would mark the label
  // field dirty during the build. The package the catch belongs
  // to is noted, and the dialog wakes to show the catch.
  void onCaught() {
    final caught = container.doorbell.clickCaptured.value;
    if (caught == null) return;
    if (identical(namedFor, caught)) return;
    namedFor = caught;
    taughtPackage = packageController.text.trim();
    labelController.text = caught.label;
    if (closed) return;
    dialogSetState?.call(() {});
  }

  container.doorbell.clickCaptured.addListener(onCaught);

  await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        dialogSetState = setState;
        // Entering step 2 checks the click access, every time the
        // step is entered. The check is a command too, so it goes
        // through the wrapper, whose setState must not run inside
        // this build.
        if (screen == 'steps' && step == 2 && !accessAsked) {
          accessAsked = true;
          unawaited(
            Future<void>.delayed(Duration.zero, () async {
              if (!context.mounted) return;
              await checkAccess(context, setState);
            }),
          );
        }
        // A catch from another package must not survive: coming
        // back to step 3 after the package changed forgets it,
        // the label typed for it and the name filled from it.
        if (screen == 'steps' &&
            step == 3 &&
            packageController.text.trim() != taughtPackage) {
          taughtPackage = packageController.text.trim();
          container.doorbell.clickCaptured.value = null;
          labelController.text = '';
          namedFor = null;
          namedFromLabel = false;
          nameFilledFor = null;
        }
        // The name starts as the card label, filled when the step
        // shows after a new catch, and only when the user did not
        // change it by hand.
        if (screen == 'steps' && step == 4) {
          final caught = container.doorbell.clickCaptured.value;
          final caughtAgain = caught != null &&
              !identical(nameFilledFor, caught);
          if (!namedFromLabel || caughtAgain) {
            namedFromLabel = true;
            nameFilledFor = caught;
            final label = labelController.text.trim();
            if (nameController.text.trim().isEmpty ||
                nameController.text.trim() == nameFilledValue) {
              nameController.text = label;
              nameFilledValue = label;
            }
          }
        }
        final sensorEnabled = container.settings.get(doorbellSensorEnabled);
        final small = TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );
        final List<Widget> rows;
        if (screen == 'done') {
          rows = [
            Text(
              '${nameController.text.trim()} is ready. The tap worked. '
              'When the sensor $entity turns on, this doorbell opens '
              '${packageController.text.trim()} and taps '
              '"${labelController.text.trim()}".',
            ),
          ];
        } else if (screen == 'failed') {
          final status = failText.endsWith('.') ? failText : '$failText.';
          rows = [
            Text(
              '${nameController.text.trim()} is saved, but the test did '
              'not work: $status',
            ),
          ];
        } else if (step == 1) {
          rows = [
            const Text(
              'Which app shows your doorbell camera? Kiosk Satellite '
              'will open this app when the doorbell rings.',
            ),
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
            if (!sensorEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Turn on "Doorbell video launch by Home Assistant '
                  'sensor & tap" first.',
                  style: small,
                ),
              ),
          ];
        } else if (step == 2) {
          final Widget status;
          if (!accessKnown) {
            status = const Text('Checking the click access.');
          } else if (accessOn) {
            status = const Text(
              'Doorbell click access is ON. You can continue.',
            );
          } else {
            status = const Text('Doorbell click access is OFF.');
          }
          rows = [
            const Text(
              'To open the right camera, Kiosk Satellite taps the '
              'camera\'s card in the doorbell app for you. Android '
              'needs you to allow this once.',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: status,
            ),
            if (accessKnown && !accessOn)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Press Open Accessibility settings, find Kiosk '
                  'Satellite in the list, turn it on, then come back '
                  'and press Check again.',
                  style: small,
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
          // The button that starts a capture, relabelled by where
          // it is used: the first teach and the one after a catch.
          Widget startButton(String label) => Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
              onPressed: busy
                  ? null
                  : () => unawaited(startCapture(context, setState)),
              child: Text(label),
            ),
          );
          rows = [
            const Text('1. Press Open the app below.'),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '2. In ${packageController.text.trim()}, tap the camera '
                'that this doorbell should open.',
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '3. I bring you back here as soon as I have seen your '
                'tap.',
              ),
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
                  if (caught != null) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'I saw this card: "${caught.label}". Is this the '
                          'camera? If not, press Teach again.',
                        ),
                        startButton('Teach again'),
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: TextField(
                            controller: labelController,
                            decoration: const InputDecoration(
                              labelText:
                                  'Card name (change it only if it is wrong)',
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    );
                  }
                  if (capturing) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Waiting for your tap in the doorbell app. This '
                          'stops in 90 seconds.',
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
                  if (starting) {
                    return const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('Opening the app...'),
                    );
                  }
                  if (started) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'I did not see a tap. Press Open the app to try '
                          'again.',
                        ),
                        startButton('Open the app'),
                      ],
                    );
                  }
                  return startButton('Open the app');
                },
              ),
            ),
          ];
        } else if (step == 4) {
          rows = [
            const Text(
              'Give this doorbell a name, and choose the Home Assistant '
              'sensor that turns on while it rings.',
            ),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: LabeledField(
                label: 'Ringing sensor',
                helper:
                    'Pick the binary_sensor that is on while this '
                    'doorbell rings (usually named something like '
                    '"..._ringing" or "..._doorbell").',
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
            'App': packageController.text.trim(),
            'Card': labelController.text.trim(),
            'Sensor': entity,
          };
          rows = [
            for (final entry in summary.entries)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${entry.key}: ${entry.value}'),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Press Save and test. I save the doorbell, open the app '
                'and try the tap. It takes up to 30 seconds. Do not '
                'touch the tablet while it runs.',
              ),
            ),
          ];
        }
        return AlertDialog(
          title: Text(
            screen == 'done'
                ? 'Ready'
                : screen == 'failed'
                ? 'Saved, but not working yet'
                : 'Add sensor & tap doorbell',
          ),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (screen == 'steps') ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('Step $step of 5', style: small),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _stepTitles[step] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                ...rows,
              ],
            ),
          ),
          actions: [
            if (screen == 'done')
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Finish'),
              ),
            if (screen == 'failed') ...[
              TextButton(
                onPressed: busy
                    ? null
                    : () => unawaited(runTest(context, setState)),
                child: const Text('Test again'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        screen = 'steps';
                        step = 3;
                      }),
                child: const Text('Teach the card again'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Finish anyway'),
              ),
            ],
            if (screen == 'steps') ...[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(saved ? 'Finish anyway' : 'Cancel'),
              ),
              // The app of a doorbell this run already saved cannot
              // be changed, so Back stops one step short of step 1.
              if (step > 1 && (step > 2 || !saved))
                TextButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(goBack(context, setState)),
                  child: const Text('Back'),
                ),
              if (step == 1)
                TextButton(
                  onPressed:
                      busy ||
                          !sensorEnabled ||
                          packageController.text.trim().isEmpty
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
                      : () => unawaited(leaveStep3(context, setState)),
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
              else
                TextButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(saveAndTest(context, setState)),
                  child: const Text('Save and test'),
                ),
            ],
          ],
        );
      },
    ),
  );
  // The dialog closed: the capture listener goes with it, and no
  // late catch may write the label or rebuild it.
  closed = true;
  container.doorbell.clickCaptured.removeListener(onCaught);
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
