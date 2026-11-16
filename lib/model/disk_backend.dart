import '../src/rust/api/scan.dart' as rust;
import 'file_tree.dart';

abstract interface class DiskBackend {
  bool get supportsSystemActions;

  Future<List<DiskVolume>> listVolumes();

  Future<MapCatalog> scanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  });

  Future<void> revealInExplorer(String path);

  Future<void> moveToTrash(String path);
}

class NativeDiskBackend implements DiskBackend {
  const NativeDiskBackend();

  @override
  bool get supportsSystemActions => true;

  @override
  Future<List<DiskVolume>> listVolumes() async {
    return rust
        .listVolumes()
        .map(
          (v) => DiskVolume(
            name: v.name,
            mountPoint: v.mountPoint,
            totalBytes: v.totalBytes.toInt(),
            availableBytes: v.availableBytes.toInt(),
            isSystemDrive: v.isSystemDrive,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<MapCatalog> scanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) async {
    final result = await rust.scanDirectory(
      rootPath: rootPath,
      pruneBelowBytes: BigInt.from(pruneBelowBytes),
    );
    return MapCatalog.fromScanResult(result, volume: volume);
  }

  @override
  Future<void> revealInExplorer(String path) {
    return rust.revealInExplorer(path: path);
  }

  @override
  Future<void> moveToTrash(String path) {
    return rust.moveToTrash(path: path);
  }
}

class SampleDiskBackend implements DiskBackend {
  const SampleDiskBackend();

  @override
  bool get supportsSystemActions => false;

  @override
  Future<List<DiskVolume>> listVolumes() async => const [];

  @override
  Future<MapCatalog> scanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) async {
    return SampleCatalog.build();
  }

  @override
  Future<void> revealInExplorer(String path) async {}

  @override
  Future<void> moveToTrash(String path) async {}
}
