import 'package:flutter/material.dart';

import '../../protocol/bms_scan.dart';
import '../../protocol/config_groups.dart';
import '../../protocol/mac_address.dart';
import '../../protocol/settings_validation.dart';
import '../../state/bms_scan_controller.dart';
import '../../state/config_editor.dart';
import '../widgets/status_chip.dart';
import 'settings_card.dart';

class BmsSettingsScreen extends StatefulWidget {
  const BmsSettingsScreen({
    super.key,
    required this.editor,
    required this.scanController,
    required this.config,
    required this.armed,
    required this.bmsConnected,
    required this.bmsConfigured,
  });

  final ConfigEditor editor;
  final BmsScanController scanController;
  final BmsConfig? config;
  final bool armed;
  final bool? bmsConnected;
  final bool? bmsConfigured;

  @override
  State<BmsSettingsScreen> createState() => _BmsSettingsScreenState();
}

class _BmsSettingsScreenState extends State<BmsSettingsScreen> {
  late TextEditingController _typeController;
  late TextEditingController _macController;
  bool _showManualMac = false;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    widget.scanController.addListener(_onScanChanged);
  }

  void _initializeControllers() {
    final c = widget.config;
    _typeController = TextEditingController(
        text: c != null ? c.bmsType.toString() : '');
    _macController = TextEditingController(
        text: c != null ? (formatMac(c.bmsMac) ?? '') : '');
  }

  void _onScanChanged() => setState(() {});

  @override
  void didUpdateWidget(BmsSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _typeController.dispose();
      _macController.dispose();
      _initializeControllers();
    }
  }

  @override
  void dispose() {
    widget.scanController.removeListener(_onScanChanged);
    _typeController.dispose();
    _macController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  SettingsError _validateBms() {
    if (widget.config == null) return SettingsError.none;

    final bmsType = int.tryParse(_typeController.text.trim()) ?? 0;
    final bmsMacStr = _macController.text.trim();
    final bmsMac = parseMac(bmsMacStr) ?? kUnsetMac;

    return validateBms(bmsType: bmsType, bmsMac: bmsMac);
  }

  Future<void> _saveBms() async {
    final bmsType = int.tryParse(_typeController.text.trim()) ?? 0;
    final bmsMacStr = _macController.text.trim();
    final bmsMac = parseMac(bmsMacStr) ?? kUnsetMac;

    final config = BmsConfig(bmsType: bmsType, bmsMac: bmsMac);

    await _handleSaveOutcome(
      await widget.editor.saveBms(config),
    );
  }

  Future<void> _handleSaveOutcome(SaveOutcome outcome) async {
    if (!mounted) return;

    switch (outcome) {
      case SaveOk(:final bms):
        _showSnackBar('Gravado');
        if (bms != null) {
          _typeController.text = bms.bmsType.toString();
          _macController.text = formatMac(bms.bmsMac) ?? '';
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
  /// The dialog used to end in a hardcoded `saveBms`, which was wrong the
  /// moment a second thing on this screen needed authentication: starting a
  /// scan is a write by the firmware's gate, so tapping "Buscar BMS" without
  /// a session would have prompted and then saved the form instead of
  /// scanning. What asked for the PIN is what continues.
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

  /// Re-saves from the fields, not from `widget.config`: the pilot may have
  /// changed something between the first save and entering the PIN.
  Future<void> _saveWithPin(String pin) async {
    final outcome = await widget.editor.saveBms(
      BmsConfig(
        bmsType: int.tryParse(_typeController.text.trim()) ?? 0,
        bmsMac: parseMac(_macController.text.trim()) ?? kUnsetMac,
      ),
      pin: pin,
    );
    await _handleSaveOutcome(outcome);
  }

  /// Starting a scan needs the PIN, because `opRequiresAuth` says so: the
  /// firmware treats it as a write. So the first scan of a connection prompts
  /// exactly like the first save does, instead of reporting the missing
  /// session as a refusal the pilot can do nothing about.
  Future<void> _startScan() async {
    final outcome = await widget.scanController.start();
    if (!mounted || outcome is! SaveNeedsPin) return;
    _askPin((pin) => widget.scanController.start(pin: pin));
  }

  void _onScanResultTapped(BmsScanResult result) {
    setState(() {
      _macController.text = formatMac(result.mac) ?? '';
      if (result.detectedType != 0) {
        _typeController.text = result.detectedType.toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bmsError = _validateBms();
    final bmsErrorMessage = messageFor(bmsError);
    final bmsType = int.tryParse(_typeController.text.trim()) ?? 0;

    final bmsDisabled = widget.config == null ||
        widget.armed ||
        bmsError != SettingsError.none;

    final refusalMessage = widget.scanController.refusal != null
        ? _messageForOutcome(widget.scanController.refusal!)
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuração do BMS'),
      ),
      body: ListenableBuilder(
        listenable: widget.scanController,
        builder: (context, _) => Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SettingsCard(
                      title: 'DISPOSITIVO',
                      children: [
                        DropdownButton<int>(
                          key: const Key('bms-type'),
                          value: bmsType,
                          isExpanded: true,
                          items: kBmsTypeNames.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ))
                              .toList(),
                          onChanged: widget.armed
                              ? null
                              : (value) {
                                  if (value != null) {
                                    setState(() {
                                      _typeController.text = value.toString();
                                    });
                                  }
                                },
                        ),
                        const SizedBox(height: 16),
                        Text('ENDEREÇO', style: settingsSectionLabel(context)),
                        const SizedBox(height: 6),
                        Text(
                          key: const Key('bms-mac'),
                          formatMac(parseMac(_macController.text) ?? kUnsetMac) ??
                              'não configurado',
                          style: settingsIdentifier(context),
                        ),
                      ],
                    ),
                    SettingsCard(
                      title: 'BUSCA',
                      children: [
                        OutlinedButton(
                          key: const Key('scan-bms'),
                          onPressed: widget.armed ||
                                  widget.scanController.isPolling ||
                                  widget.config == null
                              ? null
                              : _startScan,
                          child: const Text('Buscar BMS'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'A busca leva 5 segundos. Não desconecte durante a busca.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        if (widget.scanController.status ==
                            BmsScanStatus.scanning) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Buscando dispositivos BLE próximos…',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                        if (widget.scanController.status ==
                            BmsScanStatus.error) ...[
                          const SizedBox(height: 12),
                          Text(
                            key: const Key('scan-error'),
                            widget.scanController.lostContact
                                ? 'A busca não respondeu. O controlador pode '
                                    'ter ficado ocupado — tente de novo.'
                                // The controller answered, and what it
                                // answered is that its scan failed. It tears
                                // down the BMS link and starts scanning in
                                // the same breath, and the scan loses that
                                // race often enough to be worth naming.
                                : 'O controlador não conseguiu buscar. Se há '
                                    'um BMS conectado, escolha "Nenhum", '
                                    'salve, e busque de novo.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (widget.scanController.status ==
                                BmsScanStatus.complete &&
                            widget.scanController.results.isEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            key: const Key('scan-empty'),
                            'Nenhum dispositivo encontrado. Ligue o BMS e '
                            'tente de novo.',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        if (widget.scanController.results.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          ...widget.scanController.results
                              .asMap()
                              .entries
                              .map((e) => _ResultTile(
                                    index: e.key,
                                    result: e.value,
                                    onTap: () => _onScanResultTapped(e.value),
                                  )),
                        ],
                        if (widget.scanController.truncated) ...[
                          const SizedBox(height: 4),
                          Text(
                            key: const Key('scan-truncated'),
                            'Mostrando ${widget.scanController.results.length} de ${widget.scanController.total} dispositivos',
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const Key('manual-mac-toggle'),
                            onPressed: () => setState(
                                () => _showManualMac = !_showManualMac),
                            child: const Text('Digitar manualmente'),
                          ),
                        ),
                        if (_showManualMac)
                          TextField(
                            key: const Key('manual-mac'),
                            controller: _macController,
                            decoration: const InputDecoration(
                              labelText: 'Endereço MAC (AA:BB:CC:DD:EE:FF)',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) => setState(() {}),
                          ),
                      ],
                    ),
                    SettingsCard(
                      title: 'ESTADO',
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: StatusChip(
                            text: _bmsLinkStatus().toUpperCase(),
                            color: (widget.bmsConnected ?? false)
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            _SaveFooter(
              messages: [
                ?bmsErrorMessage,
                ?refusalMessage,
                if (widget.armed)
                  'Não é possível gravar enquanto a aeronave está armada',
              ],
              child: FilledButton(
                key: const Key('save-bms'),
                onPressed: bmsDisabled ? null : _saveBms,
                child: const Text('Salvar'),
              ),
            ),
          ],
        ),
      ),
    );

  }

  String _bmsLinkStatus() {
    if (widget.bmsConnected == true) return 'BMS conectado';
    if (widget.bmsConfigured == true) return 'BMS configurado, sem conexão';
    return 'Nenhum BMS configurado';
  }

  String? _messageForOutcome(SaveOutcome outcome) {
    return switch (outcome) {
      // Answered by the prompt, not by a line of text.
      SaveNeedsPin() => null,
      SaveWrongPin() => 'PIN incorreto',
      SaveRefusedArmed() => 'Recusado: a aeronave está armada',
      SaveRejectedByController() =>
        'O controlador recusou o valor — o app e o firmware discordam sobre a faixa válida',
      SaveUnsupported() => 'Este firmware não aceita gravação',
      SaveBusy() => 'O controlador está ocupado',
      SaveFailed(:final cause) => cause == SaveFailure.linkLost
          ? 'A conexão caiu antes de gravar'
          : 'O controlador não respondeu. Tente de novo.',
      _ => null,
    };
  }
}

/// One device the scan found: its address, how strong it is, and the type it
/// announced — or nothing where it announced none, because this app never
/// asks the controller to find out.
class _ResultTile extends StatelessWidget {
  const _ResultTile({
    required this.index,
    required this.result,
    required this.onTap,
  });

  final int index;
  final BmsScanResult result;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeLabel =
        result.detectedType != 0 ? kBmsTypeNames[result.detectedType] : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: Key('scan-result-$index'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatMac(result.mac) ?? '?',
                        style: settingsIdentifier(context).copyWith(fontSize: 15)),
                    const SizedBox(height: 2),
                    Text(
                      '${result.rssi} dBm',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (typeLabel != null)
                StatusChip(text: typeLabel, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
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
