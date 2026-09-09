# fly-app

Flutter app (Android + iOS) for the [fly-controller](https://github.com/rodrigomedeirosbrazil/fly-controller)
electric paramotor controller.

Phase 1 is a read-only flight instrument: it connects to the controller over BLE and
renders the telemetry stream the controller already broadcasts for XCTrack. Later phases
add settings, log download and firmware update over BLE, eventually replacing the
controller's WiFi config portal.

Distribution is sideload only for now — Android APK direct, iOS built locally in Xcode.
