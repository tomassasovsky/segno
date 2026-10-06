/// One table of which appliance operations may commit while others are in
/// flight, checked at each operation's commit point, not when its dialog
/// opens (accepted behaviour 6.12).
library;

export 'src/guard_registry.dart';
