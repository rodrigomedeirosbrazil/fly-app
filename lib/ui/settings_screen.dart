import 'package:flutter/material.dart';

import '../protocol/config_groups.dart';
import '../protocol/settings_validation.dart';
import '../state/config_editor.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.editor,
    required this.power,
    required this.thermal,
    required this.armed,
    required this.selectableMotorTempSource,
  });

  final ConfigEditor editor;
  final PowerConfig? power;
  final ThermalConfig? thermal;
  final bool armed;
  final bool selectableMotorTempSource;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _capacityController;
  late TextEditingController _minVoltageController;
  late TextEditingController _maxVoltageController;
  late TextEditingController _dividerRatioController;
  late TextEditingController _motorStartController;
  late TextEditingController _motorMaxController;
  late TextEditingController _escStartController;
  late TextEditingController _escMaxController;
  late TextEditingController _motorSourceController;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    // Validation runs in build() against the controllers' current text, so the
    // save button is only as fresh as the last rebuild -- without this,
    // typing an inverted range leaves it live. A listener per controller
    // rather than onChanged on eight fields: a field added later cannot
    // forget to opt in.
    for (final c in _controllers) {
      c.addListener(_onFieldChanged);
    }
  }

  void _onFieldChanged() => setState(() {});

  void _initializeControllers() {
    final p = widget.power;
    _capacityController =
        TextEditingController(text: p?.capacityMah.toString() ?? '');
    _minVoltageController = TextEditingController(
        text: p != null ? (p.minVoltageMv / 1000).toStringAsFixed(1) : '');
    _maxVoltageController = TextEditingController(
        text: p != null ? (p.maxVoltageMv / 1000).toStringAsFixed(1) : '');
    _dividerRatioController =
        TextEditingController(text: p?.voltageDividerRatio.toString() ?? '');

    final t = widget.thermal;
    _motorStartController = TextEditingController(
        text: t != null ? t.motorReductionStartC.toStringAsFixed(0) : '');
    _motorMaxController =
        TextEditingController(text: t != null ? t.motorMaxC.toStringAsFixed(0) : '');
    _escStartController = TextEditingController(
        text: t != null ? t.escReductionStartC.toStringAsFixed(0) : '');
    _escMaxController =
        TextEditingController(text: t != null ? t.escMaxC.toStringAsFixed(0) : '');
    _motorSourceController =
        TextEditingController(text: t?.motorTempSource.toString() ?? '');
  }

  @override
  void didUpdateWidget(SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.power != widget.power || oldWidget.thermal != widget.thermal) {
      _capacityController.dispose();
      _minVoltageController.dispose();
      _maxVoltageController.dispose();
      _dividerRatioController.dispose();
      _motorStartController.dispose();
      _motorMaxController.dispose();
      _escStartController.dispose();
      _escMaxController.dispose();
      _motorSourceController.dispose();
      _initializeControllers();
    }
  }

  /// Every field's controller, in one place: the listeners in initState and
  /// the disposal below both walk it, so a field added later cannot be wired
  /// into one and forgotten in the other.
  List<TextEditingController> get _controllers => [
        _capacityController,
        _minVoltageController,
        _maxVoltageController,
        _dividerRatioController,
        _motorStartController,
        _motorMaxController,
        _escStartController,
        _escMaxController,
        _motorSourceController,
      ];

  @override
  void dispose() {
    for (final c in _controllers) {
      c.removeListener(_onFieldChanged);
      c.dispose();
    }
    super.dispose();
  }

  SettingsError _validatePower() {
    if (widget.power == null) return SettingsError.none;

    final capacity = int.tryParse(_capacityController.text) ?? 0;
    final minVoltage =
        ((double.tryParse(_minVoltageController.text) ?? 0) * 1000).toInt();
    final maxVoltage =
        ((double.tryParse(_maxVoltageController.text) ?? 0) * 1000).toInt();
    final dividerRatio = double.tryParse(_dividerRatioController.text) ?? 0;

    return validatePower(
      capacityMah: capacity,
      minVoltageMv: minVoltage,
      maxVoltageMv: maxVoltage,
      dividerRatio: dividerRatio,
    );
  }

  SettingsError _validateThermal() {
    if (widget.thermal == null) return SettingsError.none;

    final motorStart = double.tryParse(_motorStartController.text) ?? 0;
    final motorMax = double.tryParse(_motorMaxController.text) ?? 0;
    final escStart = double.tryParse(_escStartController.text) ?? 0;
    final escMax = double.tryParse(_escMaxController.text) ?? 0;
    final motorSource = int.tryParse(_motorSourceController.text) ?? 0;

    return validateThermal(
      motorReductionStartC: motorStart,
      motorMaxC: motorMax,
      escReductionStartC: escStart,
      escMaxC: escMax,
      motorTempSource: motorSource,
    );
  }

  Future<void> _savePower() async {
    final capacity = int.tryParse(_capacityController.text) ?? 0;
    final minVoltage =
        ((double.tryParse(_minVoltageController.text) ?? 0) * 1000).toInt();
    final maxVoltage =
        ((double.tryParse(_maxVoltageController.text) ?? 0) * 1000).toInt();
    final dividerRatio = double.tryParse(_dividerRatioController.text) ?? 0;

    final config = PowerConfig(
      capacityMah: capacity,
      minVoltageMv: minVoltage,
      maxVoltageMv: maxVoltage,
      powerControlEnabled: widget.power?.powerControlEnabled ?? false,
      voltageDividerRatio: dividerRatio,
    );

    await _handleSaveOutcome(
      await widget.editor.savePower(config),
      isPower: true,
    );
  }

  Future<void> _saveThermal() async {
    final motorStart = double.tryParse(_motorStartController.text) ?? 0;
    final motorMax = double.tryParse(_motorMaxController.text) ?? 0;
    final escStart = double.tryParse(_escStartController.text) ?? 0;
    final escMax = double.tryParse(_escMaxController.text) ?? 0;
    final motorSource = int.tryParse(_motorSourceController.text) ?? 0;

    final config = ThermalConfig(
      motorReductionStartC: motorStart,
      motorMaxC: motorMax,
      escReductionStartC: escStart,
      escMaxC: escMax,
      motorTempSource: motorSource,
    );

    await _handleSaveOutcome(
      await widget.editor.saveThermal(config),
      isPower: false,
    );
  }

  Future<void> _handleSaveOutcome(SaveOutcome outcome,
      {required bool isPower}) async {
    if (!mounted) return;

    switch (outcome) {
      case SaveOk(:final power, :final thermal):
        _showSnackBar('Gravado');
        if (power != null) {
          _minVoltageController.text =
              (power.minVoltageMv / 1000).toStringAsFixed(1);
          _maxVoltageController.text =
              (power.maxVoltageMv / 1000).toStringAsFixed(1);
          _capacityController.text = power.capacityMah.toString();
          _dividerRatioController.text = power.voltageDividerRatio.toString();
        }
        if (thermal != null) {
          _motorStartController.text =
              thermal.motorReductionStartC.toStringAsFixed(0);
          _motorMaxController.text = thermal.motorMaxC.toStringAsFixed(0);
          _escStartController.text =
              thermal.escReductionStartC.toStringAsFixed(0);
          _escMaxController.text = thermal.escMaxC.toStringAsFixed(0);
          _motorSourceController.text = thermal.motorTempSource.toString();
        }
      case SaveNeedsPin():
        _showPinDialog(isPower: isPower);
      case SaveWrongPin():
        _showSnackBar('PIN incorreto');
      case SaveRefusedArmed():
        _showSnackBar('Recusado: a aeronave está armada');
      case SaveRejectedByController():
        _showSnackBar(
            'O controlador recusou o valor — o app e o firmware discordam sobre a faixa válida');
      case SaveUnsupported():
        _showSnackBar('Este firmware não aceita gravação');
      case SaveFailed():
        _showSnackBar('Não foi possível gravar');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showPinDialog({required bool isPower}) {
    final pinController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('PIN'),
        content: TextField(
          controller: pinController,
          obscureText: true,
          decoration: const InputDecoration(hintText: 'Digite o PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final pin = pinController.text;
              pinController.dispose();

              final outcome = isPower
                  ? await widget.editor.savePower(
                      PowerConfig(
                        capacityMah:
                            int.tryParse(_capacityController.text) ?? 0,
                        minVoltageMv:
                            ((double.tryParse(_minVoltageController.text) ?? 0) *
                                    1000)
                                .toInt(),
                        maxVoltageMv:
                            ((double.tryParse(_maxVoltageController.text) ?? 0) *
                                    1000)
                                .toInt(),
                        powerControlEnabled:
                            widget.power?.powerControlEnabled ?? false,
                        voltageDividerRatio:
                            double.tryParse(_dividerRatioController.text) ?? 0,
                      ),
                      pin: pin,
                    )
                  : await widget.editor.saveThermal(
                      ThermalConfig(
                        motorReductionStartC:
                            double.tryParse(_motorStartController.text) ?? 0,
                        motorMaxC:
                            double.tryParse(_motorMaxController.text) ?? 0,
                        escReductionStartC:
                            double.tryParse(_escStartController.text) ?? 0,
                        escMaxC: double.tryParse(_escMaxController.text) ?? 0,
                        motorTempSource:
                            int.tryParse(_motorSourceController.text) ?? 0,
                      ),
                      pin: pin,
                    );

              await _handleSaveOutcome(outcome, isPower: isPower);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final powerError = _validatePower();
    final thermalError = _validateThermal();
    final powerErrorMessage = messageFor(powerError);
    final thermalErrorMessage = messageFor(thermalError);

    final powerDisabled = widget.power == null ||
        widget.armed ||
        powerError != SettingsError.none;
    final thermalDisabled = widget.thermal == null ||
        widget.armed ||
        thermalError != SettingsError.none;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuração'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
          Text(
            'Energia',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('capacity'),
            controller: _capacityController,
            decoration: const InputDecoration(
              labelText: 'Capacidade (mAh)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('min-voltage'),
            controller: _minVoltageController,
            decoration: const InputDecoration(
              labelText: 'Tensão mínima (V)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('max-voltage'),
            controller: _maxVoltageController,
            decoration: const InputDecoration(
              labelText: 'Tensão máxima (V)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('divider-ratio'),
            controller: _dividerRatioController,
            decoration: const InputDecoration(
              labelText: 'Divisor de tensão',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          if (powerErrorMessage != null)
            Text(
              powerErrorMessage,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          if (powerErrorMessage != null) const SizedBox(height: 12),
          if (widget.armed)
            Text(
              'Não é possível gravar enquanto a aeronave está armada',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          if (widget.armed) const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('save-power'),
            onPressed: powerDisabled ? null : _savePower,
            child: const Text('Gravar'),
          ),
          const SizedBox(height: 32),
          Text(
            'Térmica',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('motor-start'),
            controller: _motorStartController,
            decoration: const InputDecoration(
              labelText: 'Início da redução do motor (°C)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('motor-max'),
            controller: _motorMaxController,
            decoration: const InputDecoration(
              labelText: 'Máximo do motor (°C)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('esc-start'),
            controller: _escStartController,
            decoration: const InputDecoration(
              labelText: 'Início da redução do ESC (°C)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('esc-max'),
            controller: _escMaxController,
            decoration: const InputDecoration(
              labelText: 'Máximo do ESC (°C)',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          if (widget.selectableMotorTempSource) ...[
            const Text('Origem da temperatura do motor'),
            const SizedBox(height: 8),
            DropdownButton<int>(
              value: int.tryParse(_motorSourceController.text) ?? 0,
              items: const [
                DropdownMenuItem(value: 0, child: Text('CAN')),
                DropdownMenuItem(value: 1, child: Text('NTC')),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _motorSourceController.text = value.toString();
                  });
                }
              },
            ),
            const SizedBox(height: 12),
          ],
          if (thermalErrorMessage != null)
            Text(
              thermalErrorMessage,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          if (thermalErrorMessage != null) const SizedBox(height: 12),
          if (widget.armed)
            Text(
              'Não é possível gravar enquanto a aeronave está armada',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          if (widget.armed) const SizedBox(height: 12),
          ElevatedButton(
            key: const Key('save-thermal'),
            onPressed: thermalDisabled ? null : _saveThermal,
            child: const Text('Gravar'),
          ),
            ],
          ),
        ),
      ),
    );
  }
}
