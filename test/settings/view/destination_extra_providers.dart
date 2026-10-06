import 'package:flutter_bloc/flutter_bloc.dart';

/// Providers a destination's body needs that the trunk this branch is built
/// on does not have yet.
///
/// Empty here. The USB storage service's Storage page (#1177 Part 5) reads a
/// `StorageCubit` from inside `StorageSystemTab`; when that part and this
/// harness meet, the merge adds it here, for example
/// `BlocProvider(create: (_) => StorageCubit(repository: StorageRepository(
/// client: const UnsupportedUsbStorageClient())))`, and regenerates
/// `test/screenshots/goldens/settings_storage.png`. One list, so the merge
/// touches one place rather than every test that opens Storage.
List<BlocProvider<StateStreamableSource<Object?>>> extraProviders() => const [];
