import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../protocol/control_info.dart';
import '../../protocol/dfu_protocol.dart';
import '../../state/dfu_session.dart';
import '../../state/firmware_update_checker.dart';
import '../../state/firmware_update_policy.dart';
import '../../state/telemetry_repository.dart';
import 'settings_card.dart';

class FirmwareSettingsScreen extends StatefulWidget {
  const FirmwareSettingsScreen({
    super.key,
    required this.repo,
    required this.session,
    required this.updates,
    required this.armed,
    required this.canUpdateFirmware,
    required this.pickFile,
  });

  final TelemetryRepository repo;
  final DfuSession session;

  /// The GitHub check for this visit. Owned by the caller, which disposes it
  /// with the screen.
  final FirmwareUpdateChecker updates;
  final bool armed;
  final bool canUpdateFirmware;
  final Future<Uint8List?> Function() pickFile;

  @override
  State<FirmwareSettingsScreen> createState() => _FirmwareSettingsScreenState();
}

class _FirmwareSettingsScreenState extends State<FirmwareSettingsScreen> {
  Uint8List? _chosenImage;
  ImageInspection? _inspection;

  /// The release asset the chosen image was downloaded as, or null when the
  /// pilot picked a file. The warning text depends on it.
  FirmwareAvailable? _downloaded;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onChanged);
    // Check BEFORE listening: check() notifies synchronously when it flips to
    // `checking`, and a listener calling setState inside initState throws.
    // The first build reads `checking` directly; later notifications arrive
    // after an await, outside any build.
    widget.updates.check();
    widget.updates.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.updates.removeListener(_onChanged);
    widget.session.removeListener(_onChanged);
    _pinController.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// What the last pick failed with, or null. A pick that throws and a pick
  /// the pilot cancelled look identical from here unless one of them says so.
  String? _pickError;

  Future<void> _pickFile() async {
    Uint8List? image;
    try {
      image = await widget.pickFile();
    } catch (e) {
      if (mounted) setState(() => _pickError = e.toString());
      return;
    }
    if (image == null || !mounted) return;

    setState(() {
      _pickError = null;
      _chosenImage = image;
      _inspection = inspectImage(image!);
      _downloaded = null;
    });
  }

  /// Downloads, then puts the bytes exactly where a picked file goes, so
  /// inspection, Enviar and Aplicar e reiniciar are the same code either way.
  Future<void> _download() async {
    final offer = widget.updates.availability;
    if (offer is! FirmwareAvailable) return;
    await widget.updates.download();
    final bytes = widget.updates.image;
    if (bytes == null || !mounted) return;
    setState(() {
      _pickError = null;
      _chosenImage = bytes;
      _inspection = inspectImage(bytes);
      _downloaded = offer;
    });
  }

  /// Re-adopts the image already downloaded, after a manual pick replaced it.
  void _useDownloaded(FirmwareAvailable offer) {
    final bytes = widget.updates.image;
    if (bytes == null) return;
    setState(() {
      _pickError = null;
      _chosenImage = bytes;
      _inspection = inspectImage(bytes);
      _downloaded = offer;
    });
  }

  Future<void> _send({String? pin}) async {
    if (_chosenImage == null) return;
    await widget.session.start(_chosenImage!, pin: pin);
    if (!mounted) return;
    // A missing session is answered by asking, not by a line of text. What
    // asked for the PIN is what continues -- the same rule the other screens
    // follow.
    if (widget.session.outcome is DfuNeedsPin) _askPin((p) => _send(pin: p));
  }

  /// Owned by the screen, not by the dialog: disposing it when the dialog
  /// closes destroys it while the TextField still holds it, because
  /// Navigator.pop only starts the teardown.
  final TextEditingController _pinController = TextEditingController();

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

  /// What went wrong, in words the pilot can act on.
  ///
  /// Every branch here was once a single "Falha na transferência". The one
  /// that mattered was a missing PIN, which happens on the *first* transfer of
  /// every connection -- so the only message the pilot ever saw was the one
  /// that said nothing, for the cause that had an obvious fix.
  String? _outcomeMessage(DfuOutcome? outcome) => switch (outcome) {
        null => null,
        DfuReady() => null,
        DfuCommitted() => null,
        DfuAborted() => null,
        // Answered by the prompt, not by a line of text.
        DfuNeedsPin() => null,
        DfuWrongPin() => 'PIN incorreto',
        DfuRejectedImage(:final problem) => switch (problem) {
            ImageProblem.empty => 'O arquivo está vazio',
            ImageProblem.notEsp32 => 'Não é um firmware ESP32 válido',
            ImageProblem.tooLarge =>
              'O arquivo é maior que o espaço disponível no controlador',
          },
        DfuRefusedArmed() => 'Recusado: a aeronave está armada',
        DfuNotReady() =>
          'O controlador recusou iniciar. Uma transferência anterior pode ter '
              'ficado aberta — tente enviar de novo.',
        DfuUnsupported() => 'Este firmware não aceita atualização pelo app',
        DfuCommitRefused() =>
          'O controlador recebeu a imagem inteira mas não conseguiu finalizar '
              'a gravação. O firmware antigo continua rodando — não desligue '
              'o controlador esperando o novo.',
        DfuControllerError() =>
          'O controlador falhou ao gravar na memória e encerrou a '
              'transferência. Desligue e ligue o controlador antes de tentar '
              'de novo.',
        DfuControllerRestarted() =>
          'O controlador reiniciou durante o envio — a transferência foi '
              'perdida. Tente de novo.',
        DfuFailed(:final reason) => switch (reason) {
            DfuFailureReason.noAnswer =>
              'O controlador não respondeu. Tente de novo.',
            DfuFailureReason.stalled =>
              'O controlador respondeu, mas parou de aceitar dados. Veja o '
                  'diagnóstico abaixo.',
            DfuFailureReason.linkLost => 'A conexão caiu durante o envio',
            DfuFailureReason.rejected =>
              'O controlador recusou a imagem — tamanho ou verificação',
            DfuFailureReason.busy =>
              'O controlador está ocupado com outra operação',
            DfuFailureReason.malformed =>
              'O controlador respondeu algo que este app não entendeu',
          },
        DfuLost(:final cause) => cause == DfuFailure.linkLost
            ? 'A conexão foi perdida durante o envio'
            : 'O controlador parou de responder durante o envio',
      };

  Future<void> _commit() async {
    await widget.session.commit();
  }

  Future<void> _abort() async {
    await widget.session.abort();
  }

  @override
  Widget build(BuildContext context) {
    final inspection = _inspection;
    final isDisabled = widget.armed || !widget.canUpdateFirmware;
    final disabledReason = widget.armed
        ? 'Não é possível enviar enquanto a aeronave está armada'
        : !widget.canUpdateFirmware
            ? 'Este firmware não aceita atualização pelo app'
            : null;

    final fileProblem = inspection?.problem;
    final hasValidFile = fileProblem == null && _chosenImage != null;

    final sendDisabled = isDisabled || !hasValidFile;
    final downloading =
        widget.updates.downloadState == FirmwareDownloadState.downloading;
    final sendDisabledNow = sendDisabled || downloading;
    // Downloading is network only, so armed does not block it. A transfer in
    // flight does: the chosen image must not change under it.
    final transferIdle = widget.session.state == DfuTransferState.idle ||
        widget.session.state == DfuTransferState.failed ||
        widget.session.state == DfuTransferState.aborted;
    final commitDisabled = isDisabled ||
        widget.session.state != DfuTransferState.ready;

    final percentage = (widget.session.progress * 100).toStringAsFixed(0);
    final remaining = widget.session.estimatedRemaining;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmware'),
      ),
      body: ListenableBuilder(
        listenable: widget.session,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsCard(
                      title: 'FIRMWARE ATUAL',
                      children: [
                        Text(
                          widget.repo.firmwareVersion ?? 'desconhecido',
                          style: settingsIdentifier(context),
                        ),
                        // The build stamp is what actually answers "is this
                        // the image I flashed?" on this screen. CI stamps
                        // APP_VERSION with the release tag and every local
                        // build reports `dev`, so the version alone cannot
                        // tell two images a week apart apart -- which is the
                        // question a pilot has at the moment they are about
                        // to replace it.
                        if (widget.repo.firmwareBuild != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Build: ${widget.repo.firmwareBuild}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                    SettingsCard(
                      title: 'NO GITHUB',
                      children: _githubCard(
                        context,
                        canDownload: widget.canUpdateFirmware,
                        downloadEnabled: transferIdle,
                      ),
                    ),
                    SettingsCard(
                      title: 'ARQUIVO',
                      children: [
                        OutlinedButton(
                          key: const Key('pick-firmware'),
                          onPressed:
                              isDisabled || downloading ? null : _pickFile,
                          child: const Text('Escolher arquivo .bin'),
                        ),
                        if (_pickError != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            key: const Key('pick-error'),
                            'Não foi possível abrir o arquivo: $_pickError',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (_chosenImage != null) ...[
                          const SizedBox(height: 16),
                          if (_downloaded != null) ...[
                            Text(
                              '${_downloaded!.assetName} · baixado do GitHub',
                              style: settingsIdentifier(context),
                            ),
                            const SizedBox(height: 8),
                          ],
                          if (_inspection?.sizeBytes != null)
                            Text(
                              'Tamanho: ${(_inspection!.sizeBytes / 1024 / 1024).toStringAsFixed(2)} MB',
                              style: settingsIdentifier(context),
                            ),
                          if (_inspection?.crc32 != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'CRC: ${_inspection!.crc32.toRadixString(16).toUpperCase()}',
                              style: settingsIdentifier(context),
                            ),
                          ],
                          if (fileProblem != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _problemMessage(fileProblem),
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                    SettingsCard(
                      title: 'AVISO',
                      children: [
                        Text(
                          _downloaded == null
                              ? 'O app não tem como saber se este firmware é do seu controlador. '
                                    'Um arquivo errado deixa o controlador sem iniciar, e a recuperação '
                                    'é por cabo USB.'
                              // Reduces the risk; does not remove it. The
                              // release itself could be mislabelled, so the
                              // wording says "chosen by", never "verified".
                              : 'Imagem ${_typeLabel(widget.updates.controllerType)} do release '
                                    '${_downloaded!.tag}, escolhida pelo tipo que o controlador '
                                    'informou. Se ainda assim estiver errada, o controlador não '
                                    'inicia e a recuperação é por cabo USB.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                    SettingsCard(
                      title: 'ENVIO',
                      children: [
                        if (widget.session.state == DfuTransferState.idle ||
                            widget.session.state == DfuTransferState.failed ||
                            widget.session.state == DfuTransferState.aborted)
                          FilledButton(
                            key: const Key('send-firmware'),
                            onPressed: sendDisabledNow ? null : _send,
                            child: const Text('Enviar'),
                          ),
                        if (widget.session.isTransferring) ...[
                          LinearProgressIndicator(
                            value: widget.session.progress,
                            minHeight: 8,
                          ),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('$percentage%'),
                              if (remaining != null)
                                Text('Faltam ${_formatRemaining(remaining)}'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _abort,
                            child: const Text('Cancelar'),
                          ),
                        ],
                        if (widget.session.state == DfuTransferState.verifying)
                          Text(
                            'Verificando…',
                            style: TextStyle(
                              fontSize: 13,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (widget.session.state == DfuTransferState.ready)
                          Text(
                            'Pronto para aplicar',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                    // Shown only after a failure, and only when there is
                    // something to read. A transfer crosses two repositories
                    // and a radio; without this the only thing that ever
                    // reached the pilot was one sentence naming the outcome,
                    // and every diagnosis started by asking them to try again
                    // and describe it better.
                    if (widget.session.state == DfuTransferState.failed &&
                        widget.session.trail.isNotEmpty)
                      SettingsCard(
                        title: 'DIAGNÓSTICO',
                        children: [
                          SelectableText(
                            widget.session.trail.join('\n'),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              height: 1.5,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    SettingsCard(
                      title: 'FINALIZAR',
                      children: [
                        FilledButton(
                          key: const Key('commit-firmware'),
                          onPressed: commitDisabled ? null : _commit,
                          style: commitDisabled
                              ? null
                              : ButtonStyle(
                                  backgroundColor: WidgetStatePropertyAll(
                                    Theme.of(context).colorScheme.error,
                                  ),
                                  foregroundColor: WidgetStatePropertyAll(
                                    Theme.of(context)
                                        .colorScheme
                                        .onError,
                                  ),
                                ),
                          child: const Text('Aplicar e reiniciar'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _WarningFooter(
              messages: [
                ?disabledReason,
                ?_outcomeMessage(widget.session.outcome),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _typeLabel(ControllerType type) => switch (type) {
    ControllerType.xag => 'XAG',
    ControllerType.tmotor => 'Tmotor',
    ControllerType.unknown => '?',
  };

  List<Widget> _githubCard(
    BuildContext context, {
    required bool canDownload,
    required bool downloadEnabled,
  }) {
    final u = widget.updates;
    final muted = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final error = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.error,
    );

    if (u.checking || u.availability == null) {
      return [Text('Verificando no GitHub…', style: muted)];
    }

    final retryCheck = OutlinedButton(
      key: const Key('retry-firmware-check'),
      onPressed: u.check,
      child: const Text('Tentar de novo'),
    );

    switch (u.availability!) {
      case FirmwareUpToDate():
        return [Text('Atualizado', style: settingsIdentifier(context))];
      case FirmwareUnknown():
        return [
          Text('Não foi possível verificar', style: muted),
          const SizedBox(height: 12),
          retryCheck,
        ];
      case FirmwareNoAssetForType():
        return [
          Text(
            'Não há imagem para este controlador neste release',
            style: muted,
          ),
        ];
      case final FirmwareAvailable offer:
        final mb = (offer.size / 1024 / 1024)
            .toStringAsFixed(1)
            .replaceAll('.', ',');
        return [
          Text('Disponível ${offer.tag}', style: settingsIdentifier(context)),
          if (offer.installedUnreadable) ...[
            const SizedBox(height: 4),
            Text('A versão instalada não é de um release', style: muted),
          ],
          if (canDownload) ...[
            const SizedBox(height: 12),
            ..._downloadRow(context, offer, mb, muted, error, downloadEnabled),
          ],
        ];
    }
  }

  List<Widget> _downloadRow(
    BuildContext context,
    FirmwareAvailable offer,
    String mb,
    TextStyle muted,
    TextStyle error,
    bool enabled,
  ) {
    final u = widget.updates;
    // Shown disabled rather than hidden while a transfer is in flight: fixed
    // presence, varying state, so nothing under it shifts mid-transfer.
    FilledButton button(String label) => FilledButton(
      key: const Key('download-firmware'),
      onPressed: enabled ? _download : null,
      child: Text(label),
    );
    switch (u.downloadState) {
      case FirmwareDownloadState.idle:
        return [button('Baixar ${offer.tag} ($mb MB)')];
      case FirmwareDownloadState.downloading:
        final total = u.total ?? 0;
        final fraction = total == 0 ? 0.0 : u.received / total;
        return [
          LinearProgressIndicator(value: fraction, minHeight: 8),
          const SizedBox(height: 8),
          Text('${(fraction * 100).toStringAsFixed(0)}%'),
        ];
      case FirmwareDownloadState.downloaded:
        return [
          Text('Baixado', style: muted),
          // A manual pick afterwards supersedes the download; this is the way
          // back, without spending the data again.
          if (_downloaded == null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              key: const Key('use-downloaded-firmware'),
              onPressed: enabled ? () => _useDownloaded(offer) : null,
              child: const Text('Usar a imagem baixada'),
            ),
          ],
        ];
      case FirmwareDownloadState.failed:
        return [
          Text('Falha no download', style: error),
          const SizedBox(height: 12),
          button('Tentar de novo'),
        ];
      case FirmwareDownloadState.incomplete:
        return [
          Text('Download incompleto', style: error),
          const SizedBox(height: 12),
          button('Tentar de novo'),
        ];
    }
  }

  /// The estimate, rounded to something a pilot reads at a glance.
  ///
  /// Seconds below a minute, then whole minutes: a transfer takes about a
  /// minute, so "1 min" and "40 s" are the two shapes that ever appear, and
  /// second-level precision on a number that moves once per window would just
  /// flicker.
  String _formatRemaining(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} s';
    final minutes = (d.inSeconds / 60).ceil();
    return '$minutes min';
  }

  String _problemMessage(ImageProblem problem) {
    return switch (problem) {
      ImageProblem.empty => 'Arquivo vazio',
      ImageProblem.notEsp32 => 'Não é um firmware ESP32 válido',
      ImageProblem.tooLarge => 'Arquivo muito grande para o slot',
    };
  }
}

/// Messages anchored where the thumb is.
class _WarningFooter extends StatelessWidget {
  const _WarningFooter({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredMessages = messages.where((m) => m.isNotEmpty).toList();

    if (filteredMessages.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in filteredMessages)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                m,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
