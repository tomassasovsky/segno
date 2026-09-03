/// The pedal layer for the Segno console board: the state-frame model and the
/// binary link codec shared with the board's firmware as one contract, the
/// `PedalRepository` over a `PedalLink`, the UART link to the board, and the
/// on-screen pedal that mirrors it.
library;

export 'src/pedal_button.dart';
export 'src/pedal_event.dart';
export 'src/pedal_link.dart';
export 'src/pedal_link_codec.dart';
export 'src/pedal_link_message.dart';
export 'src/pedal_mode.dart';
export 'src/pedal_repository.dart';
export 'src/pedal_state_frame.dart';
export 'src/simulator_pedal_link.dart';
export 'src/uart_pedal_link.dart';
