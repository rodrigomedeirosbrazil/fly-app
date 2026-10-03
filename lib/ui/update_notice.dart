/// The one sentence both the connection screen and the settings index show,
/// so the two never say it differently.
///
/// [canOpen] is true where a release is installable (Android): tapping opens
/// it. On iOS a release carries only an APK, so the sentence says where the
/// update comes from instead.
String updateNoticeText(String tag, {required bool canOpen}) => canOpen
    ? 'Nova versão $tag — toque para baixar'
    : 'Nova versão $tag — reinstale pelo Mac';
