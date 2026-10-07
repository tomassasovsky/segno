import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:operation_guards/operation_guards.dart';
import 'package:segno/storage/cubit/storage_cubit.dart';
import 'package:storage_repository/storage_repository.dart';
import 'package:usb_storage_client/usb_storage_client.dart';

/// Providers a destination's body needs beyond the ones the harness mounts
/// for every destination.
///
/// The USB storage service's Storage page (#1177 Part 5) reads a
/// [StorageCubit] from inside `StorageSystemTab`: here over a build with no
/// USB, and Internal unmeasured, so the page draws its "unavailable" figures
/// rather than this machine's disk. One list, so every test that opens
/// Storage gets it.
List<BlocProvider<StateStreamableSource<Object?>>> extraProviders() => [
  BlocProvider<StorageCubit>(
    create: (_) => StorageCubit(
      repository: StorageRepository(
        guards: GuardRegistry(),
        client: const UnsupportedUsbStorageClient(),
        exportsRoot: () async => '/segno-destination-harness/exports',
        volumeSpace: (_) => null,
      ),
      sampleRate: () => 48000,
    ),
  ),
];
