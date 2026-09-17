import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart';

/// 测试注入点：强制走 Android / 桌面分支。
///
/// `Platform.isAndroid` 来自 `dart:io`，在 Windows/CI 上跑 `flutter test` 时
/// 恒为 false，无法验证 Android 专属布局（例如「不能用依赖 FluentTheme 的
/// 控件」这类约束）。设置它可以在测试里复刻 Android 分支。
///
/// 只在测试中使用，记得 `addTearDown` 复位。
@visibleForTesting
bool? debugForceAndroidLayout;

/// 当前是否按 Android 布局渲染。
bool get isAndroidLayout => debugForceAndroidLayout ?? Platform.isAndroid;

class PlatformBuildWidget extends StatelessWidget {
  const PlatformBuildWidget({
    super.key,
    required this.androidBuilder,
    required this.desktopBuilder,
  });

  final WidgetBuilder androidBuilder;
  final WidgetBuilder desktopBuilder;

  @override
  Widget build(BuildContext context) {
    if (isAndroidLayout) {
      return androidBuilder(context);
    }
    return desktopBuilder(context);
  }
}

class PlatformWidget extends StatelessWidget {
  const PlatformWidget({
    super.key,
    required this.androidWidget,
    required this.desktopWidget,
  });

  final Widget androidWidget;
  final Widget desktopWidget;

  @override
  Widget build(BuildContext context) {
    if (isAndroidLayout) {
      return androidWidget;
    }
    return desktopWidget;
  }
}
