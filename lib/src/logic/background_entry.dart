import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'app_runtime.dart';

class _BackgroundBinding extends BindingBase
    with SchedulerBinding, ServicesBinding {}

void runBackground() {
  _BackgroundBinding();
  AppRuntime().start();
}
