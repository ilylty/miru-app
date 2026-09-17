import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miru_app/models/comic_cache_config.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/utils/i18n.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:miru_app/views/widgets/settings/settings_tile.dart';

/// 设置页里的「漫画缓存」配置面板。
///
/// 可配置项（全部可配置化）：
///   * 是否开启漫画缓存
///   * 生产者：自动缓存后 n 话
///   * 每一话之间的缓存间隔 l（秒）
///   * 一话内图片之间的缓存间隔 m（秒）
///   * 最大并发、磁盘上限、阅读时顺带缓存、条漫无感切换
///
/// 注意：Android 走的是 `GetMaterialApp`（**没有 FluentTheme**），
/// 所以这里所有控件都必须按平台分流：
/// 数字输入用 [TextField] / `fluent.NumberBox`，
/// 开关用 [Switch] / `fluent.ToggleSwitch`。
/// 直接无条件使用 fluent 控件会在 Android 上抛
/// `A FluentTheme widget is necessary to draw this layout`，
/// 导致整块设置面板渲染失败。
class ComicCacheSettings extends StatefulWidget {
  const ComicCacheSettings({super.key});

  @override
  State<ComicCacheSettings> createState() => _ComicCacheSettingsState();
}

class _ComicCacheSettingsState extends State<ComicCacheSettings> {
  late ComicCacheConfig _config;

  /// Android 数字输入框的控制器（每个配置项一个，保持输入状态）。
  late final Map<String, TextEditingController> _controllers = {
    'preload': TextEditingController(),
    'chapter': TextEditingController(),
    'image': TextEditingController(),
    'concurrent': TextEditingController(),
    'disk': TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    _config = ComicCacheConfigStore.load();
    _syncControllers();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 把当前配置写回输入框（初始化 / 外部改动后调用）。
  void _syncControllers() {
    _controllers['preload']!.text = '${_config.preloadChapterCount}';
    _controllers['chapter']!.text = '${_config.chapterInterval}';
    _controllers['image']!.text = '${_config.imageInterval}';
    _controllers['concurrent']!.text = '${_config.maxConcurrent}';
    _controllers['disk']!.text = '${_config.maxDiskSizeMB}';
  }

  Future<void> _update(ComicCacheConfig next) async {
    setState(() {
      _config = next;
    });
    await ComicCacheConfigStore.save(next);
  }

  /// Android 上裸的 Text/Row 需要自己补 16px 左右间距，
  /// 才能和 [SettingsTile] 内部的 [ListTile]（自带 16px contentPadding）对齐。
  /// 桌面端设置页外层已经有 30px 的 ListView padding，不需要再补。
  EdgeInsets get _androidInset => isAndroidLayout
      ? const EdgeInsets.symmetric(horizontal: 16)
      : EdgeInsets.zero;

  /// 数字输入行的通用外壳（左标题 + 右控件）。
  Widget _row({
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: EdgeInsets.only(
        left: _androidInset.left,
        right: _androidInset.right,
        top: 6,
        bottom: 6,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          trailing,
        ],
      ),
    );
  }

  /// 数字输入行。
  Widget _numberRow({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String controllerKey,
    required num value,
    required num min,
    required num max,
    required ValueChanged<num> onChanged,
  }) {
    return _row(
      title: title.trIn(context),
      subtitle: subtitle.trIn(context),
      trailing: PlatformWidget(
        // Android：Material TextField（不依赖 FluentTheme）。
        androidWidget: SizedBox(
          width: 96,
          child: TextField(
            controller: _controllers[controllerKey],
            keyboardType: const TextInputType.numberWithOptions(
              decimal: false,
              signed: false,
            ),
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
            ),
            onSubmitted: (text) {
              final parsed = num.tryParse(text);
              if (parsed == null) {
                // 输入非法时回退到当前值，避免把空/乱输入写进配置。
                _syncControllers();
                return;
              }
              final clamped = parsed.clamp(min, max).toDouble();
              _controllers[controllerKey]!.text = '${clamped.round()}';
              onChanged(clamped);
            },
          ),
        ),
        // 桌面：Fluent NumberBox。
        desktopWidget: SizedBox(
          width: 120,
          child: fluent.NumberBox<num>(
            value: value,
            min: min,
            max: max,
            smallChange: 1,
            mode: fluent.SpinButtonPlacementMode.inline,
            onChanged: (v) {
              if (v == null) {
                return;
              }
              onChanged(v);
            },
          ),
        ),
      ),
    );
  }

  /// 开关行。
  Widget _switchRow({
    required BuildContext context,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SettingsTile(
      title: title.trIn(context),
      buildSubtitle: () => subtitle.trIn(context),
      trailing: PlatformWidget(
        androidWidget: Switch(
          value: value,
          onChanged: onChanged,
        ),
        desktopWidget: fluent.ToggleSwitch(
          checked: value,
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 标题/副标题是裸的 Text，需要和下面的 [SettingsTile]（ListTile 自带
    // 16px）对齐，否则 Android 上标题会贴屏幕左边而开关行却缩进了 16px。
    final headerInset = _androidInset;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: headerInset,
          child: Text(
            'comic-cache.title'.trIn(context),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: headerInset,
          child: Text(
            'comic-cache.subtitle'.trIn(context),
            style: const TextStyle(fontSize: 12),
          ),
        ),
        const SizedBox(height: 8),
        _switchRow(
          context: context,
          title: 'comic-cache.enabled',
          subtitle: 'comic-cache.enabled-subtitle',
          value: _config.enabled,
          onChanged: (v) => _update(_config.copyWith(enabled: v)),
        ),
        const SizedBox(height: 8),
        _numberRow(
          context: context,
          title: 'comic-cache.preload-count',
          subtitle: 'comic-cache.preload-count-subtitle',
          controllerKey: 'preload',
          value: _config.preloadChapterCount,
          min: ComicCacheConfig.minPreloadChapterCount,
          max: ComicCacheConfig.maxPreloadChapterCount,
          onChanged: (v) => _update(
            _config.copyWith(preloadChapterCount: v.round()),
          ),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.chapter-interval',
          subtitle: 'comic-cache.chapter-interval-subtitle',
          controllerKey: 'chapter',
          value: _config.chapterInterval,
          min: 0,
          max: ComicCacheConfig.maxIntervalSeconds,
          onChanged: (v) => _update(_config.copyWith(chapterInterval: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.image-interval',
          subtitle: 'comic-cache.image-interval-subtitle',
          controllerKey: 'image',
          value: _config.imageInterval,
          min: 0,
          max: ComicCacheConfig.maxIntervalSeconds,
          onChanged: (v) => _update(_config.copyWith(imageInterval: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.max-concurrent',
          subtitle: 'comic-cache.max-concurrent-subtitle',
          controllerKey: 'concurrent',
          value: _config.maxConcurrent,
          min: ComicCacheConfig.minConcurrent,
          max: ComicCacheConfig.maxConcurrentLimit,
          onChanged: (v) => _update(_config.copyWith(maxConcurrent: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.max-disk-size',
          subtitle: 'comic-cache.max-disk-size-subtitle',
          controllerKey: 'disk',
          value: _config.maxDiskSizeMB,
          min: 0,
          max: ComicCacheConfig.maxDiskSizeMBLimit,
          onChanged: (v) => _update(_config.copyWith(maxDiskSizeMB: v.round())),
        ),
        const SizedBox(height: 8),
        _switchRow(
          context: context,
          title: 'comic-cache.cache-on-read',
          subtitle: 'comic-cache.cache-on-read-subtitle',
          value: _config.cacheOnRead,
          onChanged: (v) => _update(_config.copyWith(cacheOnRead: v)),
        ),
        _switchRow(
          context: context,
          title: 'comic-cache.seamless-switch',
          subtitle: 'comic-cache.seamless-switch-subtitle',
          value: _config.seamlessChapterSwitch,
          onChanged: (v) => _update(_config.copyWith(seamlessChapterSwitch: v)),
        ),
      ],
    );
  }
}
