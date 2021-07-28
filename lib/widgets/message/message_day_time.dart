import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

import '../../bloc/minute_timer_cubit.dart';
import '../../utils/datetime_format_utils.dart';
import '../../utils/hook.dart';
import '../brightness_observer.dart';
import 'message.dart';

class MessageDayTime extends HookWidget {
  const MessageDayTime({
    Key? key,
    required this.dateTime,
  }) : super(key: key);

  final DateTime dateTime;

  @override
  Widget build(BuildContext context) {
    final dateTimeString =
        useBlocStateConverter<MinuteTimerCubit, DateTime, String>(
      converter: (dateTime) => formatDateTimeOfDay(this.dateTime),
      keys: [dateTime],
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: BrightnessData.themeOf(context).dateTime,
          ),
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: 64,
            ),
            child: Text(
              dateTimeString,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: MessageItemWidget.secondaryFontSize,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
