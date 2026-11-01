import 'dart:async';

import 'package:flutter/material.dart';

import '../app_container.dart';
import '../managers/doorbell/doorbell_signature.dart';
import 'toast.dart';

/// The Doorbell page's saved doorbells: each with a Remove, and a
/// one-tap Add Eufy Security below the list. The list is the manager's,
/// read and changed through its commands so the native listener stays
/// in step. Capturing another doorbell is added by the next slice.
Future<void> showDoorbellDialog(
  BuildContext context,
  AppContainer container,
) async {
  // The saved doorbells the list shows, reloaded after every change.
  var signatures = <Map>[];
  var loaded = false;

  // The list from the manager: anything but a list of maps counts as
  // empty, the same tolerant read the setting itself gets.
  Future<void> reload(BuildContext dialogContext, StateSetter setState) async {
    final result = await container.commands.execute(
      'doorbellSignatures',
      const {},
    );
    if (!dialogContext.mounted) return;
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
    final result = await container.commands.execute(
      'doorbellRemoveSignature',
      {'id': id},
    );
    if (!dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    await reload(dialogContext, setState);
  }

  // Save the Eufy Security app, the doorbell this feature was built
  // against, then reload the list to match.
  Future<void> addEufy(
    BuildContext dialogContext,
    StateSetter setState,
  ) async {
    final result = await container.commands.execute(
      'doorbellAddSignature',
      {
        'label': eufySignature.label,
        'package': eufySignature.package,
        'channelPrefix': eufySignature.channelPrefix,
      },
    );
    if (!dialogContext.mounted) return;
    if (!result.ok) _toastFailure(dialogContext, result.error);
    await reload(dialogContext, setState);
  }

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        // The list loads once, when the dialog first builds.
        if (!loaded) {
          loaded = true;
          unawaited(reload(context, setState));
        }
        final hasEufy = signatures.any(
          (signature) => signature['package'] == eufySignature.package,
        );
        return AlertDialog(
          title: const Text('Doorbells'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
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
                      onPressed: () => unawaited(
                        remove(context, setState, '${signature['id']}'),
                      ),
                    ),
                  ),
                if (!hasEufy)
                  TextButton(
                    onPressed: () => unawaited(addEufy(context, setState)),
                    child: const Text('Add Eufy Security'),
                  ),
              ],
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
