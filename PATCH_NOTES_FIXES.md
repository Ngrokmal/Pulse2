# Fixes applied

1. Local signaling host startup now recognizes address-in-use and permission-denied errors even when the platform throws a non-SocketException.
2. CallControls now gives each of its five controls an equal share of available width so labels are constrained on narrow screens.

These changes were inspected in source, but Flutter tests/build were not run in this environment.
