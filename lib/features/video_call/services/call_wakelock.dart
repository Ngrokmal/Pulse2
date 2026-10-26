import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while a call is connected, so the screen timeout does
/// not send the app to the background (which can stop the camera and
/// microphone). It only sets Android's "keep screen on" window flag; it needs
/// no permission and cannot keep a call alive when the user locks the phone
/// or switches apps.
///
/// Failures are never fatal: the call continues with the normal timeout.
class CallWakelock {
  bool _enabled = false;

  bool get isEnabled => _enabled;

  /// Turns the flag on or off. Repeated calls with the same value do nothing.
  Future<void> set(bool enabled) async {
    if (enabled == _enabled) return;
    _enabled = enabled;
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint(
        'Changing the keep-screen-on flag failed: '
        '${error.runtimeType}',
      );
    }
  }
}
