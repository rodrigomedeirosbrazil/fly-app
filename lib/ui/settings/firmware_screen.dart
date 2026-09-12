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
    super.dispose();
  }

  void _onSessionChanged() => setState(() {});

  Future<void> _pickFile() async {
    final image = await widget.pickFile();
    if (image == null || !mounted) return;

    setState(() {
      _chosenImage = image;
      _inspection = inspectImage(image);
    });
  }

  Future<void> _send() async {
    if (_chosenImage == null) return;
    await widget.session.start(_chosenImage!);
  }

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
                if (widget.session.outcome is DfuRejectedImage)
                  'Arquivo inválido',
                if (widget.session.outcome is DfuRefusedArmed)
                  'A aeronave está armada',
                if (widget.session.outcome is DfuUnsupported)
                  'Este firmware não suporta atualização',
                if (widget.session.outcome is DfuFailed)
                  'Falha na transferência',
                if (widget.session.outcome is DfuLost) ...[
                  if ((widget.session.outcome as DfuLost).cause ==
                      DfuFailure.linkLost)
                    'A conexão foi perdida'
                  else
                    'Timeout na comunicação',
                ],
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
