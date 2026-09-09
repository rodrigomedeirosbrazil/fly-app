import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const FlyApp());
}
