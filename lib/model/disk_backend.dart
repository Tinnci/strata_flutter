import '../src/rust/api/scan.dart' as rust;
import 'file_tree.dart';

class ScanUpdate {
  const ScanUpdate({
    required this.entryCount,
    required this.scannedBytes,
    this.catalog,
    this.isFinal = false,
  });

  final int entryCount;
  final int scannedBytes;
  final MapCatalog? catalog;
  final bool isFinal;
}

abstract interface class DiskBackend {
  bool get supportsSystemActions;

  Future<List<DiskVolume>> listVolumes();

  Future<MapCatalog> scanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  });

  Stream<ScanUpdate> watchScanPath(
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
  Stream<ScanUpdate> watchScanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) {
    return rust
        .scanDirectoryStream(
          rootPath: rootPath,
          pruneBelowBytes: BigInt.from(pruneBelowBytes),
        )
        .map((event) {
          final finalResult = event.finalResult;
          if (finalResult != null) {
            return ScanUpdate(
              entryCount: finalResult.entryCount.toInt(),
              scannedBytes: finalResult.totalScannedBytes.toInt(),
              catalog: MapCatalog.fromScanResult(finalResult, volume: volume),
              isFinal: true,
            );
          }
          final liveCatalog = event.topEntries.isNotEmpty
              ? MapCatalog.fromLiveSnapshot(
                  rootPath: rootPath,
                  entryCount: event.entryCount.toInt(),
                  topEntries: event.topEntries,
                  volume: volume,
                )
              : null;
          return ScanUpdate(
            entryCount: event.entryCount.toInt(),
            scannedBytes: event.scannedBytes.toInt(),
            catalog: liveCatalog,
            isFinal: false,
          );
        });
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
  Stream<ScanUpdate> watchScanPath(
    String rootPath, {
    DiskVolume? volume,
    int pruneBelowBytes = 1000000,
  }) async* {
    final c = SampleCatalog.build();
    yield ScanUpdate(
      entryCount: c.tree.entryCount,
      scannedBytes: c.tree.nodes[FileTree.root].size,
      catalog: c,
      isFinal: true,
    );
  }

  @override
  Future<void> revealInExplorer(String path) async {}

  @override
  Future<void> moveToTrash(String path) async {}
}
