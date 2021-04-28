import 'package:flutter/widgets.dart';
import 'package:flutter_app/bloc/simple_cubit.dart';
import 'package:flutter_app/utils/hook.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_portal/flutter_portal.dart';

import 'menu.dart';

class FullScreenVisibleCubit extends SimpleCubit<bool> {
  FullScreenVisibleCubit(bool state) : super(state);
}

class FullScreenPortal extends HookWidget {
  const FullScreenPortal({
    Key? key,
    required this.builder,
    required this.portalBuilder,
    this.duration = const Duration(milliseconds: 100),
    this.curve = Curves.easeOut,
  }) : super(key: key);

  final WidgetBuilder builder;
  final WidgetBuilder portalBuilder;

  final Duration duration;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    final visibleBloc =
        useBloc<FullScreenVisibleCubit>(() => FullScreenVisibleCubit(false));
    final visible = useBlocState(bloc: visibleBloc);
    return BlocProvider.value(
      value: visibleBloc,
      child: Barrier(
        duration: duration,
        visible: visible,
        onClose: () => visibleBloc.emit(false),
        child: PortalEntry(
          closeDuration: duration,
          visible: visible,
          portal: TweenAnimationBuilder<double>(
            duration: duration,
            tween: Tween(begin: 0, end: visible ? 1 : 0),
            curve: curve,
            builder: (context, progress, child) => Opacity(
              opacity: progress,
              child: child,
            ),
            child: Builder(builder: portalBuilder),
          ),
          child: Builder(builder: builder),
        ),
      ),
    );
  }
}
