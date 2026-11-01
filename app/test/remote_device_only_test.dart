import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_satellite/managers/remote/remote_manager.dart';

/// The commands the remote API and websocket refuse: the doorbell capture
/// reads other apps' notifications, so only the kiosk's own screen may
/// start it, while the signature commands stay reachable remotely.
void main() {
  test('the capture is device only, the signature commands are not', () {
    expect(
      RemoteManager.deviceOnlyCommands,
      containsAll(['doorbellStartCapture', 'doorbellStopCapture']),
    );
    expect(
      RemoteManager.deviceOnlyCommands,
      isNot(contains('doorbellSignatures')),
    );
  });
}
