import 'package:flutter/material.dart';

import 'src/rust/frb_generated.dart';
import 'ui/strata_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const StrataApp(enableRust: true));
}

class StrataApp extends StatelessWidget {
  const StrataApp({super.key, this.enableRust = false});

  final bool enableRust;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Strata',
      debugShowCheckedModeBanner: false,
      home: StrataRootView(enableRust: enableRust),
    );
  }
}
