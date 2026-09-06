import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../ondevice/ondevice_voice_controller.dart';

Future<void> showVoiceModePicker(BuildContext context, WidgetRef ref) =>
    startVoiceCommandOnly(context, ref);
