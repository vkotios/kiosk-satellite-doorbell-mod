import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../core/command_registry.dart';
import 'toast.dart';

/// The Test dialog: opens one saved sensor & tap doorbell the way a
/// ring would and shows the outcome. The command runs once at open,
/// waits for the native answer (up to a minute) and stores the
/// doorbell's last activity, so the list's status line changes with
/// it. When the card was not found the dialog can offer the card names
/// the app did show: tapping one saves it as the doorbell's card and
/// tests again, in the same dialog. Returns true when the last result
/// was clicked.
Future<bool> showDoorbellTestDialog(
  BuildContext context,
  AppContainer container, {
  required String id,
  required String label,
}) async {
  // Whether the command is running now: the dialog shows the wait and
  // takes no outside tap while it does.
  var running = true;

  // Whether the open-time run was already started: the builder runs
  // again on every rebuild, the test must not.
  var started = false;

  // The outcome of the last run, null until one ended. A command that
  // could not start is an outcome too, told as [error].
  Map? outcome;
  var error = '';

  // The saved card name, for the not_found reason line.
  var savedCard = '';

  // The card names the app showed on a miss, empty unless the test
  // reports them.
  var cards = const <String>[];

  // The dialog's answer: true when the last result was clicked.
  var lastClicked = false;

  // One command at a time: the test, the card pick's update and the
  // signature read that finds the saved card name.
  var busy = false;

  // The saved card name for the not_found reason line: read from the
  // manager's own list, the same source the status text is built from.
  Future<String> savedClickCard() async {
    final result = await container.commands.execute(
      'doorbellSignatures',
      const {},
    );
    if (!result.ok || result.data is! List) return '';
    for (final entry in result.data as List) {
      if (entry is Map && '${entry['id'] ?? ''}' == id) {
        return '${entry['clickLabel'] ?? ''}';
      }
    }
    return '';
  }

  // Run the test once more: the wait, then the outcome. The context
  // and setState are dead once the dialog has closed, so every step
  // after an await checks mounted first.
  Future<void> runTest(BuildContext dialogContext, StateSetter setState) async {
    if (busy) return;
    busy = true;
    setState(() {
      running = true;
      outcome = null;
      error = '';
    });
    final CommandResult result;
    try {
      result = await container.commands.execute('doorbellTestOpen', {
        'id': id,
      });
    } finally {
      busy = false;
    }
    if (!dialogContext.mounted) return;
    if (!result.ok) {
      setState(() {
        running = false;
        error = result.error ?? '';
        lastClicked = false;
      });
      return;
    }
    final data = result.data;
    final map = data is Map ? data : const {};
    var card = '';
    if ('${map['result'] ?? ''}' == 'not_found') {
      card = await savedClickCard();
    }
    if (!dialogContext.mounted) return;
    final shown = map['cards'];
    setState(() {
      running = false;
      outcome = map;
      savedCard = card;
      cards = [
        for (final name in shown is List ? shown : const [])
          if (name is String && name.trim().isNotEmpty) name.trim(),
      ];
      lastClicked = '${map['result'] ?? ''}' == 'clicked';
    });
  }

  // Save a shown card name as the doorbell's card, then test again in
  // the same dialog.
  Future<void> pickCard(
    BuildContext dialogContext,
    StateSetter setState,
    String card,
  ) async {
    if (busy) return;
    busy = true;
    setState(() {});
    final CommandResult result;
    try {
      result = await container.commands.execute('doorbellUpdateSignature', {
        'id': id,
        'clickLabel': card,
      });
    } finally {
      busy = false;
    }
    if (!dialogContext.mounted) return;
    if (!result.ok) {
      _toastFailure(dialogContext, result.error);
      setState(() {});
      return;
    }
    await runTest(dialogContext, setState);
  }

  // The plain reason line under the manager's status text.
  String reason() {
    switch ('${outcome?['result'] ?? ''}') {
      case 'not_found':
        return savedCard.isEmpty
            ? 'The saved card was not found on the app\'s screen.'
            : 'The card "$savedCard" was not found on the app\'s screen.';
      case 'wrong_app':
        return 'The doorbell app did not come to the front.';
      case 'service_off':
        return 'Doorbell click access is off.';
      case 'launch_failed':
        return 'The app could not be opened.';
      case 'timeout':
        return 'The click service did not answer.';
      default:
        return '';
    }
  }

  await showDialog<void>(
    context: context,
    // The test runs at open: a tap outside must not close the dialog
    // over it.
    barrierDismissible: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        // The test runs once at open, after this first build: the run
        // rebuilds the dialog as running, and a setState during the
        // build would be an error.
        if (!started) {
          started = true;
          unawaited(
            Future<void>.delayed(Duration.zero, () async {
              if (!dialogContext.mounted) return;
              await runTest(dialogContext, setState);
            }),
          );
        }
        final theme = Theme.of(dialogContext);
        final small = TextStyle(
          fontSize: 13,
          color: theme.colorScheme.onSurfaceVariant,
        );
        final Widget content;
        if (running) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: const [
              LinearProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Opening the doorbell app and trying to tap the camera. '
                'This can take up to a minute. Do not touch the tablet.',
              ),
            ],
          );
        } else if (error.isNotEmpty) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.error,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('The test could not start: $error')),
                ],
              ),
            ],
          );
        } else if (outcome != null && !lastClicked) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: theme.colorScheme.error,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${outcome?['text'] ?? ''}')),
                ],
              ),
              if (reason().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(reason(), style: small),
                ),
              if (cards.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text('Cards the app showed:', style: small),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final card in cards)
                        ActionChip(
                          label: Text(card),
                          onPressed: busy
                              ? null
                              : () => unawaited(
                                    pickCard(dialogContext, setState, card),
                                  ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          );
        } else {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    color: theme.colorScheme.primary,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text('The tap worked. $label is ready.')),
                ],
              ),
            ],
          );
        }
        // Back must not close the dialog while the native test still runs.
        return PopScope(
          canPop: !running,
          child: AlertDialog(
            title: Text('Test $label'),
            content: SizedBox(width: 420, child: content),
            actions: [
              TextButton(
                onPressed: running ? null : () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              if (!running)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => unawaited(runTest(dialogContext, setState)),
                  child: const Text('Test again'),
                ),
            ],
          ),
        );
      },
    ),
  );
  return lastClicked;
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
