import 'features/diagnostics/diagnostics_bootstrap.dart';

import 'mobile_app.dart';

export 'mobile_app.dart' show BheMobileApp;

void main() => runWithMobileDiagnostics(const BheMobileApp());
