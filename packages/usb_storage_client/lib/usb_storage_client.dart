/// Data client for the Segno appliance's removable USB volumes.
///
/// The OS mounts drives (`segno-usb-mount@.service` running `segno-usb-ctl`,
/// see `deploy/yocto`), and describes each one in a JSON file under
/// `/run/segno/usb/volumes/`. This package reads those files and watches the
/// directory with inotify, so the app learns of a plug, an unplug or a served
/// eject without polling and without ever starting a process: on the
/// appliance a `fork()` of the app stalls the real-time audio thread (#806).
/// Eject is a request file the app renames into `/run/segno/usb/requests/`;
/// the image's `segno-usb-eject.path` serves it and writes the outcome back
/// into the volume's JSON, so one watch covers both directions.
library;

export 'src/create_usb_storage_client.dart'
    show createUsbStorageClient, kFakeUsbStorage;
export 'src/fake_usb_storage_client.dart' show FakeUsbStorageClient;
export 'src/linux_usb_storage_client.dart' show LinuxUsbStorageClient;
export 'src/removable_volume_record.dart'
    show EjectOutcomeRecord, RemovableVolumeRecord, RemovableVolumeRecordStatus;
export 'src/unsupported_usb_storage_client.dart'
    show UnsupportedUsbStorageClient;
export 'src/usb_storage_client.dart' show UsbStorageClient;
