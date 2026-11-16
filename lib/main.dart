import 'package:material_ui/material_ui.dart';

import 'model/disk_backend.dart';
import 'src/rust/frb_generated.dart';
import 'ui/strata_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const StrataApp(backend: NativeDiskBackend()));
}

class StrataApp extends StatelessWidget {
  const StrataApp({super.key, this.backend = const SampleDiskBackend()});

  final DiskBackend backend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Strata',
      debugShowCheckedModeBanner: false,
      home: StrataRootView(backend: backend),
    );
  }
}
