import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/remote/remote_manager.dart';

/// The commands the remote API and websocket refuse: the doorbell capture
/// reads other apps' notifications and the click capture opens the
/// doorbell app and reads its screen, so only the kiosk's own screen may
/// start them, while the signature commands stay reachable remotely.
void main() {
  test('the capture is device only, the signature commands are not', () {
    expect(
      RemoteManager.deviceOnlyCommands,
      containsAll(['doorbellStartCapture', 'doorbellStopCapture']),
    );
    expect(
      RemoteManager.deviceOnlyCommands,
      containsAll(['doorbellStartClickCapture', 'doorbellStopClickCapture']),
    );
    expect(
      RemoteManager.deviceOnlyCommands,
      isNot(contains('doorbellSignatures')),
    );
  });
}
