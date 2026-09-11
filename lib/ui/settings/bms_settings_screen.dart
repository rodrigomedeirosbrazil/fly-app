import 'package:flutter/material.dart';

import '../../protocol/bms_scan.dart';
import '../../protocol/config_groups.dart';
import '../../protocol/mac_address.dart';
import '../../protocol/settings_validation.dart';
import '../../state/bms_scan_controller.dart';
import '../../state/config_editor.dart';

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
        _showPinDialog();
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
      case SaveFailed():
        _showSnackBar('Não foi possível gravar');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  final TextEditingController _pinController = TextEditingController();

  void _showPinDialog() {
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

      final bmsType = int.tryParse(_typeController.text.trim()) ?? 0;
      final bmsMacStr = _macController.text.trim();
      final bmsMac = parseMac(bmsMacStr) ?? kUnsetMac;

      final outcome = await widget.editor.saveBms(
        BmsConfig(bmsType: bmsType, bmsMac: bmsMac),
        pin: pin,
      );

      await _handleSaveOutcome(outcome);
    });
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
        builder: (context, _) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Type dropdown
                const Text('Tipo de BMS'),
                const SizedBox(height: 8),
                DropdownButton<int>(
                  key: const Key('bms-type'),
                  value: bmsType,
                  items: kBmsTypeNames.entries
                      .map((e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _typeController.text = value.toString();
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),

                // 2. Current address
                const Text('Endereço'),
                const SizedBox(height: 8),
                Text(
                  key: const Key('bms-mac'),
                  formatMac(parseMac(_macController.text) ?? kUnsetMac) ??
                      'não configurado',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),

                // 3. Scan button
                ElevatedButton(
                  key: const Key('scan-bms'),
                  onPressed:
                      widget.armed || widget.scanController.isPolling || widget.config == null
                          ? null
                          : () => widget.scanController.start(),
                  child: const Text('Buscar BMS'),
                ),
                if (widget.scanController.isPolling)
                  const Padding(
                    padding: EdgeInsets.only(top: 8.0),
                    child: Text(
                      'A busca leva 5 segundos. Não desconecte durante a busca.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 16),

                // 4. Scanning indicator
                if (widget.scanController.status == BmsScanStatus.scanning)
                  Row(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(width: 16),
                      const Text('Buscando dispositivos BLE próximos…'),
                    ],
                  ),
                if (widget.scanController.status == BmsScanStatus.scanning)
                  const SizedBox(height: 16),

                // 5. Results
                if (widget.scanController.results.isNotEmpty)
                  ...widget.scanController.results.asMap().entries.map(
                    (e) {
                      final index = e.key;
                      final result = e.value;
                      final typeLabel = result.detectedType != 0
                          ? kBmsTypeNames[result.detectedType] ?? ''
                          : null;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: ListTile(
                          key: Key('scan-result-$index'),
                          title: Text(formatMac(result.mac) ?? '?'),
                          subtitle: Row(
                            children: [
                              Text('${result.rssi} dBm'),
                              if (typeLabel != null) ...[
                                const SizedBox(width: 8),
                                Text(typeLabel),
                              ],
                            ],
                          ),
                          onTap: () => _onScanResultTapped(result),
                        ),
                      );
                    },
                  ),

                // 6. Truncation message
                if (widget.scanController.truncated)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: Text(
                      key: const Key('scan-truncated'),
                      'Mostrando ${widget.scanController.results.length} de ${widget.scanController.total} dispositivos',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.secondary,
                      ),
                    ),
                  ),

                // 7. Manual entry
                TextButton(
                  key: const Key('manual-mac-toggle'),
                  onPressed: () => setState(() => _showManualMac = !_showManualMac),
                  child: const Text('Digitar manualmente'),
                ),
                if (_showManualMac)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
                    child: TextField(
                      key: const Key('manual-mac'),
                      controller: _macController,
                      decoration: const InputDecoration(
                        labelText: 'Endereço MAC (AA:BB:CC:DD:EE:FF)',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(() {}),
                    ),
                  ),

                // 8. Link state
                const SizedBox(height: 16),
                Text(
                  _bmsLinkStatus(),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 16),

                // Validation message
                if (bmsErrorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Text(
                      bmsErrorMessage,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // Refusal message
                if (refusalMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Text(
                      refusalMessage,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),

                if (widget.armed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: Text(
                      'Não é possível gravar enquanto a aeronave está armada',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),

                // 9. Save button
                ElevatedButton(
                  key: const Key('save-bms'),
                  onPressed: bmsDisabled ? null : _saveBms,
                  child: const Text('Salvar'),
                ),
              ],
            ),
          ),
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
      SaveNeedsPin() => 'PIN necessário',
      SaveWrongPin() => 'PIN incorreto',
      SaveRefusedArmed() => 'Recusado: a aeronave está armada',
      SaveRejectedByController() =>
        'O controlador recusou o valor — o app e o firmware discordam sobre a faixa válida',
      SaveUnsupported() => 'Este firmware não aceita gravação',
      SaveBusy() => 'O controlador está ocupado',
      SaveFailed() => 'Não foi possível gravar',
      _ => null,
    };
  }
}
