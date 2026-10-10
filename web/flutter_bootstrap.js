{{flutter_js}}
{{flutter_build_config}}

// No serviceWorkerSettings: the offline cache is sw.js, registered from
// index.html. Given settings, Flutter's loader would register its own
// deprecated worker on the same scope, which unregisters itself.
_flutter.loader.load();
