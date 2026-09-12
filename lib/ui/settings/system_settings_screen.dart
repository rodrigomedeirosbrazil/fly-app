import 'dart:async';

import 'package:flutter/material.dart';

import '../../protocol/config_groups.dart';
import '../../protocol/mac_address.dart';
import '../../protocol/settings_validation.dart';
import '../../state/config_editor.dart';
import '../../state/remote_pairing_controller.dart';
import '../widgets/status_chip.dart';
import 'settings_card.dart';

class SystemSettingsScreen extends StatefulWidget {
  const SystemSettingsScreen({
    super.key,
    required this.editor,
    required this.pairingController,
    required this.config,
    required this.armed,
    required this.hasRemoteLink,
  });

  final ConfigEditor editor;
  final RemotePairingController pairingController;
  final SystemConfig? config;
  final bool armed;
  final bool hasRemoteLink;

  @override
  State<SystemSettingsScreen> createState() => _SystemSettingsScreenState();
}

class _SystemSettingsScreenState extends State<SystemSettingsScreen> {
  late int _buzzerVolume;
  late int _throttleSource;

  @override
  void initState() {
    super.initState();
    _initializeValues();
    widget.pairingController.addListener(_onPairingChanged);
  }

  void _initializeValues() {
    _buzzerVolume = widget.config?.buzzerVolume ?? 50;
    _throttleSource = widget.config?.throttleSource ?? 0;
  }

  @override
  void didUpdateWidget(SystemSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _initializeValues();
    }
    if (oldWidget.pairingController != widget.pairingController) {
      oldWidget.pairingController.removeListener(_onPairingChanged);
      widget.pairingController.addListener(_onPairingChanged);
    }
  }

  void _onPairingChanged() {
    setState(() {});
  }

  SettingsError _validateSystem() {
    if (widget.config == null) return SettingsError.none;
    return validateSystem(
      buzzerVolume: _buzzerVolume,
      throttleSource: _throttleSource,
    );
  }

  Future<void> _saveSystem() async {
    final config = SystemConfig(
      buzzerVolume: _buzzerVolume,
      throttleSource: _throttleSource,
      remoteMac: widget.config?.remoteMac ?? kUnsetMac,
    );

    await _handleSaveOutcome(
      await widget.editor.saveSystem(config),
    );
  }

  Future<void> _handleSaveOutcome(SaveOutcome outcome) async {
    if (!mounted) return;

    switch (outcome) {
      case SaveOk(:final system):
        _showSnackBar('Gravado');
        if (system != null) {
          setState(() {
            _buzzerVolume = system.buzzerVolume;
            _throttleSource = system.throttleSource;
          });
        }
      case SaveNeedsPin():
        _askPin(_saveWithPin);
      case SaveWrongPin():
        _showSnackBar('PIN incorreto');
      case SaveRefusedArmed():
        _showSnackBar('Recusado: a aeronave está armada');
      case SaveRejectedByController():
        _showSnackBar(
            'O controlador recusou o valor — o app e o firmware discordam sobre a faixa válida');
      case SaveUnsupported():
        _showSnackBar('Este firmware não aceita gravação');
      case SaveBusy():
        _showSnackBar('O controlador está ocupado');
      case SaveFailed(:final cause):
        _showSnackBar(cause == SaveFailure.linkLost
            ? 'A conexão caiu antes de gravar'
            : 'O controlador não respondeu. Tente de novo.');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  final TextEditingController _pinController = TextEditingController();

  /// Asks for the PIN, then runs [onPin].
  ///
  /// This screen has four things that need authentication -- saving, the
  /// buzzer preview, pairing and forgetting -- and the dialog used to end in
  /// a hardcoded `saveSystem`. So dragging the volume slider on a connection
  /// with no session prompted for the PIN and then **wrote the whole
  /// configuration**, which is not what the pilot asked for. What asked for
  /// the PIN is what continues.
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

  /// Built from the fields, not from `widget.config`: the pilot may have
  /// moved something between the first save and entering the PIN.
  Future<void> _saveWithPin(String pin) async {
    final outcome = await widget.editor.saveSystem(
      SystemConfig(
        buzzerVolume: _buzzerVolume,
        throttleSource: _throttleSource,
        remoteMac: widget.config?.remoteMac ?? kUnsetMac,
      ),
      pin: pin,
    );
    await _handleSaveOutcome(outcome);
  }

  Future<void> _previewBuzzer(int volume, {String? pin}) async {
    final outcome = await widget.editor.previewBuzzer(volume, pin: pin);
    if (!mounted) return;

    switch (outcome) {
      case SaveOk():
        // Preview succeeded, no feedback needed
        break;
      case SaveNeedsPin():
        // Replays the preview once authenticated, rather than saving.
        _askPin((pin) => _previewBuzzer(volume, pin: pin));
      case SaveWrongPin():
        _showSnackBar('PIN incorreto');
      case SaveRefusedArmed():
        _showSnackBar('Recusado: a aeronave está armada');
      case SaveRejectedByController():
        _showSnackBar('Volume inválido');
      case SaveUnsupported():
        _showSnackBar('Este firmware não aceita som');
      case SaveBusy():
        _showSnackBar('O controlador está ocupado');
      case SaveFailed(:final cause):
        _showSnackBar(cause == SaveFailure.linkLost
            ? 'A conexão caiu antes de gravar'
            : 'O controlador não respondeu ao som.');
    }
  }

  Future<void> _showPairingDialog({String? pin}) async {
    // Awaited, and the progress dialog opens only on success. Starting and
    // showing a spinner regardless left the pilot watching a wait that was
    // never going to resolve, because REMOTE_PAIR had been refused.
    final outcome = await widget.pairingController.start(pin: pin);
    if (!mounted) return;

    switch (outcome) {
      case SaveOk():
        _showPairingProgressDialog();
      case SaveNeedsPin():
        _askPin((pin) => _showPairingDialog(pin: pin));
      case SaveWrongPin():
        _showSnackBar('PIN incorreto');
      case SaveRefusedArmed():
        _showSnackBar('Recusado: a aeronave está armada');
      case SaveUnsupported():
        _showSnackBar('Este firmware não pareia pelo app');
      case SaveBusy():
        _showSnackBar('O controlador está ocupado');
      case SaveRejectedByController():
        _showSnackBar('O controlador recusou o pedido de pareamento');
      case SaveFailed(:final cause):
        _showSnackBar(cause == SaveFailure.linkLost
            ? 'A conexão caiu antes de gravar'
            : 'O controlador não respondeu.');
    }
  }

  void _showPairingProgressDialog() {
    final dialogContext = <BuildContext>[];

    void handleStateChange() {
      if (!mounted) return;

      if (widget.pairingController.state == PairingState.paired) {
        if (dialogContext.isNotEmpty && Navigator.canPop(dialogContext[0])) {
          Navigator.pop(dialogContext[0]);
        }
        _showSnackBar('Remote pareado');
      } else if (widget.pairingController.state == PairingState.gaveUp) {
        if (dialogContext.isNotEmpty && Navigator.canPop(dialogContext[0])) {
          Navigator.pop(dialogContext[0]);
        }
        _showPairingCancelledDialog();
      }
    }

    widget.pairingController.addListener(handleStateChange);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogContext.add(ctx);
        return AlertDialog(
          title: const Text('Parear remote'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 16),
              const Text('Ligue o remote agora'),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              _PairingTimerWidget(controller: widget.pairingController),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                widget.pairingController.removeListener(handleStateChange);
                widget.pairingController.cancel();
                Navigator.pop(ctx);
                _showPairingCancelledDialog();
              },
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    ).then((_) {
      widget.pairingController.removeListener(handleStateChange);
    });
  }

  void _showPairingCancelledDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: const Text(
          'Não recebemos nenhum remote. O controlador continua aguardando — '
          'o próximo remote ligado por perto será pareado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showForgetDialog() {
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Esquecer remote'),
        content: const Text(
          'Endereço apagado. Um remote já em uso pode continuar funcionando '
          'até o controlador reiniciar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true || !mounted) return;

      final outcome = await widget.editor.forgetRemote(pin: null);

      if (!mounted) return;
      switch (outcome) {
        case SaveOk():
          _showSnackBar('Endereço apagado');
          setState(() {});
        case SaveNeedsPin():
          _askPin(_forgetWithPin);
        case SaveWrongPin():
          _showSnackBar('PIN incorreto');
        case SaveRefusedArmed():
          _showSnackBar('Recusado: a aeronave está armada');
        case SaveRejectedByController():
          _showSnackBar('O controlador recusou a operação');
        case SaveUnsupported():
          _showSnackBar('Este firmware não suporta essa operação');
        case SaveBusy():
          _showSnackBar('O controlador está ocupado');
        case SaveFailed(:final cause):
          _showSnackBar(cause == SaveFailure.linkLost
              ? 'A conexão caiu antes de gravar'
              : 'O controlador não respondeu. Tente de novo.');
      }
    });
  }

  Future<void> _forgetWithPin(String pin) async {
    final outcome = await widget.editor.forgetRemote(pin: pin);
    if (!mounted) return;

    switch (outcome) {
      case SaveOk():
        _showSnackBar('Endereço apagado');
        setState(() {});
      case SaveWrongPin():
        _showSnackBar('PIN incorreto');
      case SaveRefusedArmed():
        _showSnackBar('Recusado: a aeronave está armada');
      case SaveRejectedByController():
        _showSnackBar('O controlador recusou a operação');
      case SaveUnsupported():
        _showSnackBar('Este firmware não suporta essa operação');
      case SaveBusy():
        _showSnackBar('O controlador está ocupado');
      case SaveFailed(:final cause):
        _showSnackBar(cause == SaveFailure.linkLost
            ? 'A conexão caiu antes de gravar'
            : 'O controlador não respondeu. Tente de novo.');
      case SaveNeedsPin():
        // The firmware fails closed: a wrong PIN clears the session it had
        // already earned, so being asked again here means exactly that.
        _askPin(_forgetWithPin);
    }
  }

  @override
  void dispose() {
    widget.pairingController.removeListener(_onPairingChanged);
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final systemError = _validateSystem();
    final systemErrorMessage = messageFor(systemError);
    final remoteMac = widget.config?.remoteMac ?? kUnsetMac;
    final isPaired = formatMac(remoteMac) != null;

    final saveDisabled = widget.config == null ||
        widget.armed ||
        systemError != SettingsError.none;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sistema'),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SettingsCard(
                    title: 'BUZZER',
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Volume',
                            style: settingsSectionLabel(context),
                          ),
                          Text(
                            _buzzerVolume.toString(),
                            key: const Key('buzzer-value'),
                            style: settingsSectionLabel(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Slider(
                        key: const Key('buzzer-volume'),
                        value: _buzzerVolume.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 20,
                        onChangeEnd: widget.armed
                            ? null
                            : (value) {
                          setState(() {
                            _buzzerVolume = value.toInt();
                          });
                          _previewBuzzer(_buzzerVolume);
                        },
                        onChanged: widget.armed
                            ? null
                            : (value) {
                          setState(() {
                            _buzzerVolume = value.toInt();
                          });
                        },
                      ),
                    ],
                  ),
                  SettingsCard(
                    title: 'ACELERADOR',
                    children: [
                      DropdownButton<int>(
                        key: const Key('throttle-source'),
                        value: _throttleSource,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                            value: 0,
                            child: Text('Cabeado'),
                          ),
                          DropdownMenuItem(
                            value: 1,
                            child: Text('Sem fio (ESP-NOW)'),
                          ),
                        ],
                        onChanged: widget.armed
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() {
                                    _throttleSource = value;
                                  });
                                }
                              },
                      ),
                    ],
                  ),
                  if (widget.hasRemoteLink)
                    SettingsCard(
                      title: 'REMOTE',
                      children: [
                        Text('ENDEREÇO', style: settingsSectionLabel(context)),
                        const SizedBox(height: 6),
                        if (isPaired)
                          Text(
                            key: const Key('remote-mac'),
                            formatMac(remoteMac) ?? 'não pareado',
                            style: settingsIdentifier(context),
                          )
                        else
                          StatusChip(
                            key: const Key('remote-mac'),
                            text: 'NÃO PAREADO',
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                key: const Key('pair-remote'),
                                onPressed: widget.armed ? null : _showPairingDialog,
                                child: const Text('Parear remote'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                key: const Key('forget-remote'),
                                onPressed: widget.armed ? null : _showForgetDialog,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Theme.of(context).colorScheme.error,
                                  side: BorderSide(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                                child: const Text('Esquecer remote'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
          _SaveFooter(
            messages: [
              ?systemErrorMessage,
              if (widget.armed)
                'Não é possível gravar enquanto a aeronave está armada',
            ],
            child: FilledButton(
              key: const Key('save-system'),
              onPressed: saveDisabled ? null : _saveSystem,
              child: const Text('Salvar'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one action that writes to the aircraft, anchored where the thumb is,
/// with whatever is stopping it directly above.
///
/// It used to be a small pill in the middle of the page with a screenful of
/// nothing under it, carrying the same weight as the disclosure toggle two
/// lines up.
class _SaveFooter extends StatelessWidget {
  const _SaveFooter({required this.messages, required this.child});

  final List<String> messages;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          for (final m in messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                m,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// Shows seconds remaining during pairing.
class _PairingTimerWidget extends StatefulWidget {
  const _PairingTimerWidget({required this.controller});

  final RemotePairingController controller;

  @override
  State<_PairingTimerWidget> createState() => _PairingTimerWidgetState();
}

class _PairingTimerWidgetState extends State<_PairingTimerWidget> {
  late DateTime _startTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  int get _secondsRemaining {
    final elapsed =
        DateTime.now().difference(_startTime).inMilliseconds.abs();
    final remaining =
        ((widget.controller.deadline.inMilliseconds - elapsed) / 1000)
            .ceil();
    return remaining.clamp(0, widget.controller.deadline.inSeconds);
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      '$_secondsRemaining s',
      key: const Key('pairing-timer'),
    );
  }
}
