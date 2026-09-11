import 'package:flutter/material.dart';

import '../../protocol/config_groups.dart';
import '../../protocol/settings_validation.dart';
import '../../state/config_editor.dart';
import 'number_input.dart';

class PowerSettingsScreen extends StatefulWidget {
  const PowerSettingsScreen({
    super.key,
    required this.editor,
    required this.config,
    required this.armed,
    required this.sensorVolts,
  });

  final ConfigEditor editor;
  final PowerConfig? config;
  final bool armed;

  /// The pack voltage the controller is reading right now, or null when its
  /// signal state is not Valid. Calibration needs a number that is true at the
  /// moment it is applied, which is why this arrives live rather than as a
  /// snapshot.
  final double? sensorVolts;

  @override
  State<PowerSettingsScreen> createState() => _PowerSettingsScreenState();
}

class _PowerSettingsScreenState extends State<PowerSettingsScreen> {
  late TextEditingController _minVoltageCellController;
  late TextEditingController _maxVoltageCellController;
  late TextEditingController _capacityCustomController;
  late TextEditingController _bmsReferenceController;

  int? _selectedCapacityPreset;
  bool _showCustomCapacity = false;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _powerControlEnabled = widget.config?.powerControlEnabled ?? false;
    for (final c in _controllers) {
      c.addListener(_onFieldChanged);
    }
  }

  void _onFieldChanged() => setState(() {});

  void _initializeControllers() {
    final p = widget.config;

    // Voltage controllers: per-cell format
    final minPerCell =
        p != null ? (p.minVoltageMv / 1000) / kSeriesCells : 0.0;
    final maxPerCell =
        p != null ? (p.maxVoltageMv / 1000) / kSeriesCells : 0.0;

    _minVoltageCellController = TextEditingController(
      text: p != null ? minPerCell.toStringAsFixed(2) : '',
    );
    _maxVoltageCellController = TextEditingController(
      text: p != null ? maxPerCell.toStringAsFixed(2) : '',
    );

    // Capacity: determine if it's a preset or custom
    String capacityCustomText = '';
    if (p != null) {
      if (p.capacityMah == 18000) {
        _selectedCapacityPreset = 18000;
        _showCustomCapacity = false;
      } else if (p.capacityMah == 34000) {
        _selectedCapacityPreset = 34000;
        _showCustomCapacity = false;
      } else if (p.capacityMah == 65000) {
        _selectedCapacityPreset = 65000;
        _showCustomCapacity = false;
      } else {
        _selectedCapacityPreset = null;
        _showCustomCapacity = true;
        final ahValue = p.capacityMah / 1000;
        // If it's a whole number, display without decimal
        capacityCustomText = ahValue == ahValue.toInt()
            ? ahValue.toInt().toString()
            : ahValue.toString();
      }
    } else {
      _selectedCapacityPreset = null;
      _showCustomCapacity = false;
    }

    _capacityCustomController = TextEditingController(text: capacityCustomText);
    _bmsReferenceController = TextEditingController();
  }

  @override
  void didUpdateWidget(PowerSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _minVoltageCellController.dispose();
      _maxVoltageCellController.dispose();
      _capacityCustomController.dispose();
      _bmsReferenceController.dispose();
      _initializeControllers();
    }
  }

  List<TextEditingController> get _controllers => [
        _minVoltageCellController,
        _maxVoltageCellController,
        _capacityCustomController,
        _bmsReferenceController,
      ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    _pinController.dispose();
    super.dispose();
  }

  /// Local, not read from `widget.config`, because the pilot can change it.
  /// The firmware gates every derating path on this flag, so a screen that
  /// displayed it without letting it move would leave the web portal as the
  /// only way to turn power limiting off.
  late bool _powerControlEnabled;

  SettingsError _validatePower() {
    if (widget.config == null) return SettingsError.none;

    // Null, not zero: `abc` -- or `3,15` before parseSetting understood the
    // comma -- must not read as a deliberate 0 V.
    final minPerCell = parseSetting(_minVoltageCellController.text);
    final maxPerCell = parseSetting(_maxVoltageCellController.text);
    if (minPerCell == null || maxPerCell == null) {
      return SettingsError.invalidNumber;
    }
    if (_showCustomCapacity &&
        parseSetting(_capacityCustomController.text) == null) {
      return SettingsError.invalidNumber;
    }

    final minVoltageMv = (minPerCell * kSeriesCells * 1000).toInt();
    final maxVoltageMv = (maxPerCell * kSeriesCells * 1000).toInt();

    final capacityMah = _getSelectedCapacityMah();

    return validatePower(
      capacityMah: capacityMah,
      minVoltageMv: minVoltageMv,
      maxVoltageMv: maxVoltageMv,
      dividerRatio: widget.config?.voltageDividerRatio ?? 0,
    );
  }

  int _getSelectedCapacityMah() {
    if (_selectedCapacityPreset != null) {
      return _selectedCapacityPreset!;
    }
    if (_showCustomCapacity) {
      final ahValue = parseSetting(_capacityCustomController.text) ?? 0;
      return (ahValue * 1000).toInt();
    }
    return 0;
  }

  double _getMinVoltageMv() {
    final minPerCell = parseSetting(_minVoltageCellController.text) ?? 0;
    return minPerCell * kSeriesCells * 1000;
  }

  double _getMaxVoltageMv() {
    final maxPerCell = parseSetting(_maxVoltageCellController.text) ?? 0;
    return maxPerCell * kSeriesCells * 1000;
  }

  double _getPackTotalMin() {
    final minPerCell = parseSetting(_minVoltageCellController.text) ?? 0;
    return minPerCell * kSeriesCells;
  }

  double _getPackTotalMax() {
    final maxPerCell = parseSetting(_maxVoltageCellController.text) ?? 0;
    return maxPerCell * kSeriesCells;
  }

  double? _getComputedCalibrationRatio() {
    if (widget.sensorVolts == null || widget.sensorVolts == 0) return null;

    final bmsRef = parseSetting(_bmsReferenceController.text);
    if (bmsRef == null) return null;

    final currentRatio = widget.config?.voltageDividerRatio ?? 0;
    if (currentRatio == 0) return null;

    return currentRatio * (bmsRef / widget.sensorVolts!);
  }

  bool _isCalibrationValid() {
    if (widget.sensorVolts == null) return false;

    final bmsRef = parseSetting(_bmsReferenceController.text);
    if (bmsRef == null) return false;

    final refError = validateCalibrationReference(bmsRef);
    if (refError != SettingsError.none) return false;

    final computedRatio = _getComputedCalibrationRatio();
    if (computedRatio == null) return false;

    final ratioError = validateDividerRatio(computedRatio);
    if (ratioError != SettingsError.none) return false;

    return true;
  }

  Future<void> _savePower() async {
    final config = PowerConfig(
      capacityMah: _getSelectedCapacityMah(),
      minVoltageMv: _getMinVoltageMv().round(),
      maxVoltageMv: _getMaxVoltageMv().round(),
      powerControlEnabled: _powerControlEnabled,
      voltageDividerRatio: widget.config?.voltageDividerRatio ?? 0,
    );

    await _handleSaveOutcome(await widget.editor.savePower(config));
  }

  Future<void> _applyCalibration() async {
    final newRatio = _getComputedCalibrationRatio();
    if (newRatio == null) return;

    final config = PowerConfig(
      capacityMah: _getSelectedCapacityMah(),
      minVoltageMv: _getMinVoltageMv().round(),
      maxVoltageMv: _getMaxVoltageMv().round(),
      powerControlEnabled: _powerControlEnabled,
      voltageDividerRatio: newRatio,
    );

    await _handleSaveOutcome(await widget.editor.savePower(config));
  }

  Future<void> _handleSaveOutcome(SaveOutcome outcome) async {
    if (!mounted) return;

    switch (outcome) {
      case SaveOk(:final power):
        _showSnackBar('Gravado');
        if (power != null) {
          final minPerCell = (power.minVoltageMv / 1000) / kSeriesCells;
          final maxPerCell = (power.maxVoltageMv / 1000) / kSeriesCells;
          _minVoltageCellController.text = minPerCell.toStringAsFixed(2);
          _maxVoltageCellController.text = maxPerCell.toStringAsFixed(2);
          _powerControlEnabled = power.powerControlEnabled;

          // Update capacity display
          if (power.capacityMah == 18000) {
            _selectedCapacityPreset = 18000;
            _showCustomCapacity = false;
          } else if (power.capacityMah == 34000) {
            _selectedCapacityPreset = 34000;
            _showCustomCapacity = false;
          } else if (power.capacityMah == 65000) {
            _selectedCapacityPreset = 65000;
            _showCustomCapacity = false;
          } else {
            _selectedCapacityPreset = null;
            _showCustomCapacity = true;
            _capacityCustomController.text =
                (power.capacityMah / 1000).toString();
          }
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

  /// Owned by the screen, not by the dialog. Disposing it when the dialog
  /// closes destroys it while the TextField holding it is still mounted --
  /// Navigator.pop only starts the teardown, and the exit animation outlives
  /// even the Future showDialog returns. Outliving every dialog is simpler
  /// than racing one.
  final TextEditingController _pinController = TextEditingController();

  void _showPinDialog() {
    _pinController.clear();
    // The dialog returns the PIN rather than acting inside its own button.
    // Disposing the controller in the handler destroys it while the TextField
    // that holds it is still mounted -- Navigator.pop only starts the route
    // teardown -- and the framework asserts. This path had no test until one
    // drove SaveNeedsPin, which is why it survived.
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

      // Built from the fields, not from widget.config: the pilot may have
      // changed something between the first save and entering the PIN, and
      // rebuilding from the original would discard it while still reporting
      // success.
      final config = PowerConfig(
        capacityMah: _getSelectedCapacityMah(),
        minVoltageMv: _getMinVoltageMv().round(),
        maxVoltageMv: _getMaxVoltageMv().round(),
        powerControlEnabled: _powerControlEnabled,
        voltageDividerRatio: widget.config?.voltageDividerRatio ?? 0,
      );

      await _handleSaveOutcome(
        await widget.editor.savePower(config, pin: pin),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final powerError = _validatePower();
    final powerErrorMessage = messageFor(powerError);

    final saveDisabled = widget.config == null ||
        widget.armed ||
        powerError != SettingsError.none;

    final minPackVoltage = _getPackTotalMin();
    final maxPackVoltage = _getPackTotalMax();

    final computedRatio = _getComputedCalibrationRatio();
    final calibrationValid = _isCalibrationValid();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bateria e Energia'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Capacity section
              Text(
                'Capacidade da Bateria',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              DropdownButton<int?>(
                value: _selectedCapacityPreset,
                isExpanded: true,
                onChanged: (value) {
                  setState(() {
                    _selectedCapacityPreset = value;
                    _showCustomCapacity = value == null;
                  });
                },
                items: [
                  const DropdownMenuItem(value: 18000, child: Text('18 Ah')),
                  const DropdownMenuItem(value: 34000, child: Text('34 Ah')),
                  const DropdownMenuItem(value: 65000, child: Text('65 Ah')),
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Personalizado (inserir valor)'),
                  ),
                ],
              ),
              if (_showCustomCapacity) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('capacity-custom'),
                  controller: _capacityCustomController,
                  decoration: const InputDecoration(
                    labelText: 'Capacidade (Ah)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: kSettingsKeyboard,
                  inputFormatters: kSettingsFormatters,
                ),
              ],
              const SizedBox(height: 24),
              // Voltage section
              Text(
                'Tensões por Célula',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('min-voltage-cell'),
                controller: _minVoltageCellController,
                decoration: InputDecoration(
                  labelText: 'Tensão Mínima (V)',
                  border: const OutlineInputBorder(),
                  helperText: 'Total: ${minPackVoltage.toStringAsFixed(2)} V (14 células)',
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('max-voltage-cell'),
                controller: _maxVoltageCellController,
                decoration: InputDecoration(
                  labelText: 'Tensão Máxima (V)',
                  border: const OutlineInputBorder(),
                  helperText: 'Total: ${maxPackVoltage.toStringAsFixed(2)} V (14 células)',
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              if (powerErrorMessage != null)
                Text(
                  powerErrorMessage,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 24),
              // Power control section
              Text(
                'Controle de Energia',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _powerControlEnabled,
                onChanged: (v) =>
                    setState(() => _powerControlEnabled = v ?? false),
                title: const Text('Ativar Controle de Energia'),
                subtitle: const Text(
                  'Quando ativado, a saída de energia é limitada com base na tensão da bateria, temperatura do motor e temperatura do ESC. Quando desativado, a energia total está disponível sem limitações.',
                ),
              ),
              const SizedBox(height: 24),
              // Calibration section
              Text(
                'Calibração de Tensão',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Leitura atual do sensor: ${widget.sensorVolts != null ? widget.sensorVolts!.toStringAsFixed(2) : 'Sem leitura'} V',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('bms-reference'),
                controller: _bmsReferenceController,
                decoration: InputDecoration(
                  labelText: 'Tensão de Referência do BMS (V)',
                  border: const OutlineInputBorder(),
                  helperText:
                      'Tensão que o BMS mostra. O sistema calculará o fator de correção automaticamente.',
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              Text(
                'Divisor de Tensão Atual: ${widget.config?.voltageDividerRatio.toStringAsFixed(2) ?? '--'}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (computedRatio != null && calibrationValid)
                Text(
                  'Novo Divisor: ${computedRatio.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              const SizedBox(height: 4),
              if (!calibrationValid &&
                  _bmsReferenceController.text.isNotEmpty)
                Text(
                  messageFor(validateCalibrationReference(
                          parseSetting(_bmsReferenceController.text) ?? 0))
                      .toString(),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const SizedBox(height: 12),
              ElevatedButton(
                key: const Key('calibrate'),
                onPressed: calibrationValid ? _applyCalibration : null,
                child: const Text('Calibrar'),
              ),
              const SizedBox(height: 24),
              // Save button
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      key: const Key('save-power'),
                      onPressed: saveDisabled ? null : _savePower,
                      child: const Text('Salvar'),
                    ),
                  ),
                ],
              ),
              if (widget.armed)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'A aeronave está armada',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
