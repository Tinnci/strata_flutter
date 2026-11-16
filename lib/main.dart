import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'model/disk_backend.dart';
import 'src/rust/frb_generated.dart';
import 'ui/strata_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  final window = WindowManager.instance.getCurrent();
  if (window != null) {
    window.titleBarStyle = TitleBarStyle.hidden;
    window.setSize(const Size(1280, 800).toNative(), false);
    window.minimumSize = const Size(1040, 660).toNative();
    window.center();
    window.show();
    window.focus();
  }

  runApp(
    const StrataApp(
      backend: NativeDiskBackend(),
      enableWindowChrome: true,
    ),
  );
}

class StrataApp extends StatelessWidget {
  const StrataApp({
    super.key,
    this.backend = const SampleDiskBackend(),
    this.enableWindowChrome = false,
  });

  final DiskBackend backend;
  final bool enableWindowChrome;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Strata',
      debugShowCheckedModeBanner: false,
      home: StrataRootView(
        backend: backend,
        enableWindowChrome: enableWindowChrome,
      ),
    );
  }
}
