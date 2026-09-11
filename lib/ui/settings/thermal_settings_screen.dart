import 'package:flutter/material.dart';

import '../../protocol/config_groups.dart';
import '../../protocol/settings_validation.dart';
import '../../state/config_editor.dart';
import 'number_input.dart';

class ThermalSettingsScreen extends StatefulWidget {
  const ThermalSettingsScreen({
    super.key,
    required this.editor,
    required this.config,
    required this.armed,
    required this.selectableMotorTempSource,
  });

  final ConfigEditor editor;
  final ThermalConfig? config;
  final bool armed;
  final bool selectableMotorTempSource;

  @override
  State<ThermalSettingsScreen> createState() => _ThermalSettingsScreenState();
}

class _ThermalSettingsScreenState extends State<ThermalSettingsScreen> {
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
    // rather than onChanged on four fields: a field added later cannot
    // forget to opt in.
    for (final c in _controllers) {
      c.addListener(_onFieldChanged);
    }
  }

  void _onFieldChanged() => setState(() {});

  void _initializeControllers() {
    final t = widget.config;
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
  void didUpdateWidget(ThermalSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
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
    _pinController.dispose();
    super.dispose();
  }

  SettingsError _validateThermal() {
    if (widget.config == null) return SettingsError.none;

    // Null, not zero. A field holding `abc` -- or `3,15` before parseSetting
    // understood the comma -- used to read as 0 °C, which passes both the
    // range and the ordering rule and writes a band that cuts power from zero
    // upward.
    final motorStart = parseSetting(_motorStartController.text);
    final motorMax = parseSetting(_motorMaxController.text);
    final escStart = parseSetting(_escStartController.text);
    final escMax = parseSetting(_escMaxController.text);
    final motorSource = int.tryParse(_motorSourceController.text.trim());

    if (motorStart == null ||
        motorMax == null ||
        escStart == null ||
        escMax == null ||
        motorSource == null) {
      return SettingsError.invalidNumber;
    }

    return validateThermal(
      motorReductionStartC: motorStart,
      motorMaxC: motorMax,
      escReductionStartC: escStart,
      escMaxC: escMax,
      motorTempSource: motorSource,
    );
  }

  Future<void> _saveThermal() async {
    final motorStart = parseSetting(_motorStartController.text) ?? 0;
    final motorMax = parseSetting(_motorMaxController.text) ?? 0;
    final escStart = parseSetting(_escStartController.text) ?? 0;
    final escMax = parseSetting(_escMaxController.text) ?? 0;
    final motorSource = int.tryParse(_motorSourceController.text.trim()) ?? 0;

    final config = ThermalConfig(
      motorReductionStartC: motorStart,
      motorMaxC: motorMax,
      escReductionStartC: escStart,
      escMaxC: escMax,
      motorTempSource: motorSource,
    );

    await _handleSaveOutcome(
      await widget.editor.saveThermal(config),
    );
  }

  Future<void> _handleSaveOutcome(SaveOutcome outcome) async {
    if (!mounted) return;

    switch (outcome) {
      case SaveOk(:final thermal):
        _showSnackBar('Gravado');
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
      // changed something between the first save and entering the PIN.
      final outcome = await widget.editor.saveThermal(
        ThermalConfig(
          motorReductionStartC: parseSetting(_motorStartController.text) ?? 0,
          motorMaxC: parseSetting(_motorMaxController.text) ?? 0,
          escReductionStartC: parseSetting(_escStartController.text) ?? 0,
          escMaxC: parseSetting(_escMaxController.text) ?? 0,
          motorTempSource: int.tryParse(_motorSourceController.text.trim()) ?? 0,
        ),
        pin: pin,
      );

      await _handleSaveOutcome(outcome);
    });
  }

  @override
  Widget build(BuildContext context) {
    final thermalError = _validateThermal();
    final thermalErrorMessage = messageFor(thermalError);

    final thermalDisabled = widget.config == null ||
        widget.armed ||
        thermalError != SettingsError.none;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Proteção Térmica'),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              TextField(
                key: const Key('motor-start'),
                controller: _motorStartController,
                decoration: const InputDecoration(
                  labelText: 'Início da redução do motor (°C)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('motor-max'),
                controller: _motorMaxController,
                decoration: const InputDecoration(
                  labelText: 'Máximo do motor (°C)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('esc-start'),
                controller: _escStartController,
                decoration: const InputDecoration(
                  labelText: 'Início da redução do ESC (°C)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('esc-max'),
                controller: _escMaxController,
                decoration: const InputDecoration(
                  labelText: 'Máximo do ESC (°C)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: kSettingsKeyboard,
                inputFormatters: kSettingsFormatters,
              ),
              const SizedBox(height: 12),
              if (widget.selectableMotorTempSource) ...[
                const Text('Origem da temperatura do motor'),
                const SizedBox(height: 8),
                DropdownButton<int>(
                  value: int.tryParse(_motorSourceController.text.trim()) ?? 0,
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
