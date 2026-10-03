import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../protocol/log_protocol.dart';
import '../../state/config_editor.dart';
import '../../state/log_browser.dart';
import '../../state/log_download.dart';
import 'settings_card.dart';

/// The controller's flight logs: list, export, delete.
///
/// The portal's logs page, over BLE. Reads need no PIN; the first delete of
/// a connection asks for it through the same editor every save uses.
/// Everything is refused while armed — that is when the Logger is writing —
/// and the screen shows the gate instead of waiting for `ErrState`.
class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    required this.browser,
    required this.editor,
    required this.armed,
    required this.download,
    required this.share,
  });

  final LogBrowser browser;
  final ConfigEditor editor;
  final bool armed;

  /// A fresh transfer per file, built with this connection's MTU.
  final LogDownload Function() download;

  /// The platform seam: hands the bytes to the share sheet.
  final Future<void> Function(String name, Uint8List bytes) share;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String? _downloading;
  int _received = 0;
  int _total = 0;
  LogDownload? _current;

  /// Owned by the screen, not the dialog — `CLAUDE.md` records the crash a
  /// dialog-owned controller caused.
  final TextEditingController _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.browser.addListener(_onBrowser);
    widget.browser.refresh();
  }

  void _onBrowser() => setState(() {});

  @override
  void didUpdateWidget(LogsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.browser != widget.browser) {
      oldWidget.browser.removeListener(_onBrowser);
      widget.browser.addListener(_onBrowser);
    }
    // Disarming lifts the gate; a list refused while armed is worth asking
    // for again without making the pilot find the refresh button.
    if (oldWidget.armed && !widget.armed) widget.browser.refresh();
  }

  @override
  void dispose() {
    _current?.cancel();
    widget.browser.removeListener(_onBrowser);
    _pinController.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _download(LogFileEntry file) async {
    final d = widget.download();
    _current = d;
    setState(() {
      _downloading = file.name;
      _received = 0;
      _total = file.size;
    });

    final outcome = await d.fetch(file.name, onProgress: (r, t) {
      if (!mounted) return;
      setState(() {
        _received = r;
        _total = t;
      });
    });
    _current = null;
    if (!mounted) return;
    setState(() => _downloading = null);

    switch (outcome) {
      case LogDownloaded(:final bytes):
        try {
          await widget.share(file.name, bytes);
        } catch (e) {
          if (mounted) _snack('Não foi possível compartilhar: $e');
        }
      case LogDownloadRefusedArmed():
        _snack('Recusado: a aeronave está armada');
      case LogDownloadUnsupported():
        _snack('Este firmware não permite baixar registros pelo app');
      case LogDownloadNotFound():
        _snack('O registro não existe mais no controlador');
        widget.browser.refresh();
      case LogDownloadCancelled():
        break;
      case LogDownloadFailed(:final reason):
        _snack(switch (reason) {
          LogDownloadFailure.noAnswer =>
            'O controlador parou de responder. Tente de novo.',
          LogDownloadFailure.linkLost => 'A conexão caiu durante o download',
          LogDownloadFailure.fileChanged =>
            'O registro mudou durante o download. Tente de novo.',
          LogDownloadFailure.malformed =>
            'O controlador enviou uma resposta inesperada',
          LogDownloadFailure.busy => 'O controlador está ocupado',
        });
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  void _askPin(Future<void> Function(String pin) onPin) {
    _pinController.clear();
    showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('PIN'),
        content: TextField(
          controller: _pinController,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Digite o PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, _pinController.text),
            child: const Text('OK'),
          ),
        ],
      ),
    ).then((pin) async {
      if (pin == null || !mounted) return;
      await onPin(pin);
    });
  }

  Future<void> _confirmDelete(LogFileEntry file) async {
    if (!await _confirm(
      'Apagar registro',
      '${logDisplayName(file.name)} será apagado do controlador.',
      'Apagar',
    )) {
      return;
    }
    await _delete(file.name);
  }

  Future<void> _delete(String name, {String? pin}) async {
    final outcome = await widget.editor.deleteLog(name, pin: pin);
    await _afterDelete(outcome, 'Registro apagado',
        (pin) => _delete(name, pin: pin));
  }

  Future<void> _confirmDeleteAll() async {
    if (!await _confirm(
      'Apagar todos os registros',
      'Todos os registros de voo serão apagados do controlador.',
      'Apagar todos',
    )) {
      return;
    }
    await _deleteAll();
  }

  Future<void> _deleteAll({String? pin}) async {
    final outcome = await widget.editor.deleteAllLogs(pin: pin);
    await _afterDelete(outcome, 'Registros apagados',
        (pin) => _deleteAll(pin: pin));
  }

  Future<void> _afterDelete(
    SaveOutcome outcome,
    String done,
    Future<void> Function(String pin) retryWithPin,
  ) async {
    if (!mounted) return;
    switch (outcome) {
      case SaveOk():
        _snack(done);
        await widget.browser.refresh();
      case SaveNeedsPin(:final sessionLost):
        if (sessionLost) {
          _snack('O controlador encerrou a sessão. Digite o PIN de novo.');
        }
        _askPin(retryWithPin);
      case SaveWrongPin():
        _snack('PIN incorreto');
      case SaveRefusedArmed():
        _snack('Recusado: a aeronave está armada');
      case SaveRejectedByController():
        _snack('O controlador recusou o pedido');
      case SaveUnsupported():
        _snack('Este firmware não apaga registros pelo app');
      case SaveBusy():
        _snack('O controlador está ocupado');
      case SaveFailed(:final cause):
        _snack(cause == SaveFailure.linkLost
            ? 'A conexão caiu antes de apagar'
            : 'O controlador não respondeu. Tente de novo.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.browser.state;
    final busy = widget.armed || _downloading != null;
    final files = state is LogListLoaded ? state.files : const <LogFileEntry>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registros de voo'),
        actions: [
          IconButton(
            key: const Key('logs-refresh'),
            tooltip: 'Atualizar',
            icon: const Icon(Icons.refresh),
            onPressed: busy || state is LogListLoading
                ? null
                : widget.browser.refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              children: [
                if (widget.armed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Indisponível com a aeronave armada',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ..._body(context, state),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: OutlinedButton(
              key: const Key('logs-delete-all'),
              onPressed: busy || files.isEmpty ? null : _confirmDeleteAll,
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              child: const Text('Apagar todos os registros'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context, LogListState state) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);

    switch (state) {
      case LogListLoading():
        return const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
        ];
      case LogListUnsupported():
        return [
          Text(
            'Este firmware não permite baixar registros pelo app. '
            'Atualize o firmware.',
            style: muted,
          ),
        ];
      case LogListRefusedArmed():
        return const [];
      case LogListFailed(:final reason):
        return [
          Text(
            switch (reason) {
              LogListFailure.noAnswer =>
                'O controlador não respondeu à lista.',
              LogListFailure.linkLost => 'A conexão caiu.',
              LogListFailure.malformed =>
                'O controlador enviou uma lista inesperada.',
              LogListFailure.busy => 'O controlador está ocupado.',
            },
            style: muted,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: widget.armed ? null : widget.browser.refresh,
            child: const Text('Tentar de novo'),
          ),
        ];
      case LogListLoaded(:final files, :final usedBytes, :final totalBytes):
        return [
          SettingsCard(
            title: 'ARMAZENAMENTO',
            children: [
              Text(
                '${formatLogSize(usedBytes)} de ${formatLogSize(totalBytes)}',
                style: settingsIdentifier(context),
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: totalBytes > 0 ? usedBytes / totalBytes : 0,
                  minHeight: 8,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ],
          ),
          if (files.isEmpty)
            Text('Nenhum registro no controlador.', style: muted)
          else
            for (final f in files) _tile(context, f),
        ];
    }
  }

  Widget _tile(BuildContext context, LogFileEntry f) {
    final theme = Theme.of(context);
    final downloadingThis = _downloading == f.name;
    final idle = !widget.armed && _downloading == null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  logDisplayName(f.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  downloadingThis
                      ? '${formatLogSize(_received)} de ${formatLogSize(_total)}'
                      : '${formatLogSize(f.size)} · ${f.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (downloadingThis) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _total > 0 ? _received / _total : null,
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: Key('log-download-${f.name}'),
            tooltip: 'Baixar e compartilhar',
            icon: const Icon(Icons.ios_share),
            onPressed: idle ? () => _download(f) : null,
          ),
          IconButton(
            key: Key('log-delete-${f.name}'),
            tooltip: 'Apagar',
            icon: const Icon(Icons.delete_outline),
            color: theme.colorScheme.error,
            onPressed: idle ? () => _confirmDelete(f) : null,
          ),
        ],
      ),
    );
  }
}
