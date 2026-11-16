import 'package:flutter/material.dart';

import 'ui/strata_app.dart';

void main() {
  runApp(const StrataApp());
}

class StrataApp extends StatelessWidget {
  const StrataApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Strata',
      debugShowCheckedModeBanner: false,
      home: StrataRootView(),
    );
  }
}
