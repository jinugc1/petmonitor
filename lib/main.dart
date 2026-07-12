// Default entry point = the Owner App.
//
// This project has two real entry points (main_owner.dart for the iOS
// owner app, main_monitor.dart for the Android monitor) selected with
// `flutter build -t`. Some CI systems and IDEs assume lib/main.dart
// exists; this delegate makes that assumption safe and equivalent to
// building the owner app. The monitor must always be built explicitly:
//   flutter build apk -t lib/main_monitor.dart
import 'main_owner.dart' as owner;

Future<void> main() => owner.main();
