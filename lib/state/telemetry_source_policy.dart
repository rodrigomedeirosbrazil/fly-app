/// Which characteristic the telemetry is coming from.
///
/// [xctod] is the Nordic UART CSV sentence the controller also broadcasts for
/// XCTrack. It is the documented fallback and must not be deleted: firmware
/// older than the `Fly Control` service simply does not have that service, so
/// its absence *is* the capability handshake.
enum TelemetrySource { xctod, control }

/// Picks a source after service discovery.
///
/// Pure so the decision is testable without a radio — the same reason
/// `ble_permission_policy.dart` exists. `FlyControllerLink` asks and obeys.
TelemetrySource chooseAtDiscovery({
  required bool controlServicePresent,
  required bool infoReadable,
}) {
  if (!controlServicePresent) return TelemetrySource.xctod;
  // A service advertising the right UUID whose INFO will not read is not
  // something to start trusting a binary struct from.
  if (!infoReadable) return TelemetrySource.xctod;
  return TelemetrySource.control;
}

/// Whether an undecodable frame should send the app back to `$XCTOD`.
///
/// The source is provisional only until something reaches the screen. The
/// telemetry struct's `ver` is constant within a connection, so a version this
/// app cannot read fails on the very first frame or never — and falling back
/// then changes nothing a pilot is looking at.
///
/// After the first render the source is fixed. A flip at that point would
/// silently change which fields are populated, and the flight clock would
/// vanish mid-flight. Rejected frames simply age out into staleness, which is
/// already what this app does about silence.
bool shouldFallBackOnFrame({
  required bool decoded,
  required bool anyFrameRendered,
}) =>
    !decoded && !anyFrameRendered;
