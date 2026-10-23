import 'package:flutter_pty2/src/generated/flutter_pty_bindings_generated.dart'
    as native;
import 'package:flutter_pty2/src/pty_capabilities.dart';

PtyCapabilities decodePtyCapabilities(int bits) {
  return PtyCapabilities(
    posixSignals: _hasCapability(
      bits,
      native.PtyCapability.PTY_CAPABILITY_POSIX_SIGNALS,
    ),
    foregroundProcessGroups: _hasCapability(
      bits,
      native.PtyCapability.PTY_CAPABILITY_FOREGROUND_PROCESS_GROUPS,
    ),
    pixelDimensions: _hasCapability(
      bits,
      native.PtyCapability.PTY_CAPABILITY_PIXEL_DIMENSIONS,
    ),
    reliableProcessTreeKill: _hasCapability(
      bits,
      native.PtyCapability.PTY_CAPABILITY_RELIABLE_PROCESS_TREE_KILL,
    ),
    conPty: _hasCapability(
      bits,
      native.PtyCapability.PTY_CAPABILITY_CONPTY,
    ),
  );
}

bool _hasCapability(int bits, int capability) {
  return bits & capability != 0;
}
