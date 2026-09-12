import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../protocol/dfu_protocol.dart';
import '../../state/dfu_session.dart';
import '../../state/telemetry_repository.dart';
import 'settings_card.dart';

class FirmwareSettingsScreen extends StatefulWidget {
  const FirmwareSettingsScreen({
    super.key,
    required this.repo,
    required this.session,
    required this.armed,
    required this.canUpdateFirmware,
    required this.pickFile,
  });

  final TelemetryRepository repo;
  final DfuSession session;
  final bool armed;
  final bool canUpdateFirmware;
  final Future<Uint8List?> Function() pickFile;

  @override
  State<FirmwareSettingsScreen> createState() => _FirmwareSettingsScreenState();
}

class _FirmwareSettingsScreenState extends State<FirmwareSettingsScreen> {
  Uint8List? _chosenImage;
  ImageInspection? _inspection;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _pinController.dispose();
    super.dispose();
  }

  void _onSessionChanged() => setState(() {});

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
    final commitDisabled = isDisabled ||
        widget.session.state != DfuTransferState.ready;

    final percentage = (widget.session.progress * 100).toStringAsFixed(0);
    final estimateSeconds =
        widget.session.bytesAcknowledged > 0 && widget.session.progress < 1
            ? ((_chosenImage?.length ?? 0) / widget.session.bytesAcknowledged /
                widget.session.progress /
                1024 *
                (1 - widget.session.progress))
                .toInt()
            : 0;

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
                      ],
                    ),
                    SettingsCard(
                      title: 'ARQUIVO',
                      children: [
                        OutlinedButton(
                          key: const Key('pick-firmware'),
                          onPressed:
                              isDisabled ? null : _pickFile,
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
                          'O app não tem como saber se este firmware é do seu controlador. '
                          'Um arquivo errado deixa o controlador sem iniciar, e a recuperação '
                          'é por cabo USB.',
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
                            onPressed: sendDisabled ? null : _send,
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
                              if (estimateSeconds > 0)
                                Text(
                                    'Estimado: ${estimateSeconds}s'),
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
