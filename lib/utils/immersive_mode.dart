import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';

/// 阅读器「沉浸模式」：隐藏状态栏与底部导航 / 手势条（小白条）。
///
/// Android 上进入阅读器时调用 [enter]、退出时调用 [exit]，让画面真正铺满
/// 整块屏幕。做法与视频播放器一致（见 `VideoPlayerController.onInit` /
/// `onClose` 里的 `SystemUiMode.immersiveSticky`），区别是这里做成可重入的：
///
///   * 用 `immersiveSticky` 而不是 `immersive`：用户从边缘划出系统栏后，
///     系统栏会自动收起，不需要再点一下屏幕；
///   * 用引用计数而不是布尔量：阅读器可能被叠着打开（例如从阅读器里再进
///     设置二级页），只有最外层退出时才恢复系统栏，避免中途把栏弹回来。
class ImmersiveMode {
  ImmersiveMode._();

  static int _holders = 0;
  static bool _applied = false;

  // 注意：`_applied` 假设「除了本类，没有别人改系统 UI 模式」。
  // 视频播放器（`VideoPlayerController`）是唯一的例外 —— 它直接调
  // `SystemChrome.setEnabledSystemUIMode` 而不是走本类，但它与阅读器
  // 不会同时存在（`WatchPage` 只会构造其中一种），所以不会互相踩。

  /// 当前是否处于沉浸模式（供测试断言）。
  static bool get isActive => _holders > 0;

  /// 进入沉浸模式（可重入，与 [exit] 配对）。
  static Future<void> enter() async {
    _holders++;
    await _apply(immersive: true);
  }

  /// 退出沉浸模式（与 [enter] 配对）。
  static Future<void> exit() async {
    if (_holders > 0) {
      _holders--;
    }
    if (_holders == 0) {
      await _apply(immersive: false);
    }
  }

  /// 复位内部状态（测试用；也用于应用级重置）。
  @visibleForTesting
  static void reset() {
    _holders = 0;
    _applied = false;
  }

  static Future<void> _apply({required bool immersive}) async {
    // 只有 Android 有系统栏需要隐藏；桌面窗口没有这个概念。
    if (!isAndroidLayout) {
      return;
    }
    if (_applied == immersive) {
      return;
    }
    _applied = immersive;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {
      // 平台通道不可用（定制 ROM / 测试环境）时不能影响阅读本身。
    }
  }
}
