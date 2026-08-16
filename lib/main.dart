import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/packing_proof_mobile_app.dart';
import 'services/crash_log_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final CrashLogService crashLog = CrashLogService();
  FlutterError.onError = (FlutterErrorDetails details) {
    unawaited(
      crashLog.record(
        details.exception,
        details.stack ?? StackTrace.current,
      ),
    );
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (
    Object error,
    StackTrace stack,
  ) {
    unawaited(crashLog.record(error, stack));
    return true;
  };
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  runApp(const PackingProofMobileApp());
}
