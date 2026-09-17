import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ★ Android 窗口主题必须声明 `windowLayoutInDisplayCutoutMode=shortEdges`。
///
/// 用户报告：Android 上阅读漫画时**底部小白条已沉浸**，但**顶部通知栏位置
/// 仍是一条黑色区域**，而详情页的同一区域能正常显示图片。
///
/// 根因（Android 官方语义，见 developer.android.com/develop/ui/views/layout/display-cutout）：
///   * 默认值 `LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT` 的行为是
///     「**只有当刘海被系统栏包住时**，内容才画进刘海区域；否则窗口不覆盖刘海，
///     内容可能被 letterbox」。
///   * 阅读器进入沉浸模式后**隐藏了状态栏** → 刘海不再「被系统栏包住」
///     → 窗口不再覆盖刘海 → 顶部被 letterbox 成一条黑带。
///   * 详情页系统栏可见 → 窗口覆盖刘海 → 图片正常显示。这正是用户看到的对比。
///   * 刘海只在屏幕**短边**（竖屏时的顶部），所以只有顶部出黑带、底部正常 ——
///     与「底部小白条已沉浸、顶部仍是黑条」的现象完全吻合。
///
/// `shortEdges` 的语义是「**无论系统栏是否隐藏**，内容都延伸到短边的刘海区域」，
/// 因此沉浸模式下不会再被 letterbox。
///
/// 这是**原生资源层**的配置，`flutter test` 里跑不到 Android 窗口管理器，
/// 所以这里用「解析真实 styles.xml」的方式做回归护栏（源码被改回去就报错）。
/// 编译产物层面的验证用 `aapt2 dump resources`（见 MEMORY）。
void main() {
  /// 取 `<style name="<name>" ...> ... </style>` 的块内容。
  String styleBlock(String xml, String name) {
    final match = RegExp(
      '<style\\s+name="$name"[^>]*>(.*?)</style>',
      dotAll: true,
    ).firstMatch(xml);
    expect(match, isNotNull, reason: 'styles.xml 里应存在 <style name="$name">');
    return match!.group(1)!;
  }

  void expectShortEdges(String path, String name) {
    final xml = File(path).readAsStringSync();
    final body = styleBlock(xml, name);
    expect(
      body,
      contains('android:windowLayoutInDisplayCutoutMode'),
      reason:
          '$path 的 $name 必须声明 windowLayoutInDisplayCutoutMode，\n'
          '否则隐藏状态栏后顶部刘海区域会被 letterbox 成黑带。',
    );
    expect(
      RegExp(
        r'<item\s+name="android:windowLayoutInDisplayCutoutMode"\s*>\s*shortEdges\s*</item>',
      ).hasMatch(body),
      isTrue,
      reason: '$path 的 $name 的 windowLayoutInDisplayCutoutMode 必须是 shortEdges\n'
          '（default 在系统栏隐藏时不会把内容画进刘海区域）。',
    );
  }

  group('★ Android 沉浸模式的窗口主题（刘海区域）', () {
    const base = 'android/app/src/main/res';

    test('日间主题：LaunchTheme / NormalTheme 都允许画进刘海区域', () {
      expectShortEdges('$base/values/styles.xml', 'LaunchTheme');
      expectShortEdges('$base/values/styles.xml', 'NormalTheme');
    });

    test('夜间主题：LaunchTheme / NormalTheme 都允许画进刘海区域', () {
      expectShortEdges('$base/values-night/styles.xml', 'LaunchTheme');
      expectShortEdges('$base/values-night/styles.xml', 'NormalTheme');
    });

    test('护栏本身有效：缺属性 / 写成 default 都会被抓到', () {
      // 自检：确认断言不是「怎么写都通过」。
      expect(
        () => expectShortEdges('test/fixtures/styles_without_cutout.xml', 'NormalTheme'),
        throwsA(isA<TestFailure>()),
      );
      expect(
        () => expectShortEdges('test/fixtures/styles_cutout_default.xml', 'NormalTheme'),
        throwsA(isA<TestFailure>()),
      );
    });
  });
}
