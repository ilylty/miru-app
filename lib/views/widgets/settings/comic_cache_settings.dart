import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
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
class ComicCacheSettings extends StatefulWidget {
  const ComicCacheSettings({super.key});

  @override
  State<ComicCacheSettings> createState() => _ComicCacheSettingsState();
}

class _ComicCacheSettingsState extends State<ComicCacheSettings> {
  late ComicCacheConfig _config;

  @override
  void initState() {
    super.initState();
    _config = ComicCacheConfigStore.load();
  }

  Future<void> _update(ComicCacheConfig next) async {
    setState(() {
      _config = next;
    });
    await ComicCacheConfigStore.save(next);
  }

  Widget _numberRow({
    required BuildContext context,
    required String title,
    required String subtitle,
    required num value,
    required num min,
    required num max,
    required ValueChanged<num> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.trIn(context)),
                const SizedBox(height: 2),
                Text(subtitle.trIn(context),
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
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
        ],
      ),
    );
  }

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'comic-cache.title'.trIn(context),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          'comic-cache.subtitle'.trIn(context),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        _switchRow(
          context: context,
          title: 'comic-cache.enabled'.trIn(context),
          subtitle: 'comic-cache.enabled-subtitle'.trIn(context),
          value: _config.enabled,
          onChanged: (v) => _update(_config.copyWith(enabled: v)),
        ),
        const SizedBox(height: 8),
        _numberRow(
          context: context,
          title: 'comic-cache.preload-count'.trIn(context),
          subtitle: 'comic-cache.preload-count-subtitle'.trIn(context),
          value: _config.preloadChapterCount,
          min: ComicCacheConfig.minPreloadChapterCount,
          max: ComicCacheConfig.maxPreloadChapterCount,
          onChanged: (v) => _update(
            _config.copyWith(preloadChapterCount: v.round()),
          ),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.chapter-interval'.trIn(context),
          subtitle: 'comic-cache.chapter-interval-subtitle'.trIn(context),
          value: _config.chapterInterval,
          min: 0,
          max: ComicCacheConfig.maxIntervalSeconds,
          onChanged: (v) => _update(_config.copyWith(chapterInterval: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.image-interval'.trIn(context),
          subtitle: 'comic-cache.image-interval-subtitle'.trIn(context),
          value: _config.imageInterval,
          min: 0,
          max: ComicCacheConfig.maxIntervalSeconds,
          onChanged: (v) => _update(_config.copyWith(imageInterval: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.max-concurrent'.trIn(context),
          subtitle: 'comic-cache.max-concurrent-subtitle'.trIn(context),
          value: _config.maxConcurrent,
          min: ComicCacheConfig.minConcurrent,
          max: ComicCacheConfig.maxConcurrentLimit,
          onChanged: (v) => _update(_config.copyWith(maxConcurrent: v.round())),
        ),
        _numberRow(
          context: context,
          title: 'comic-cache.max-disk-size'.trIn(context),
          subtitle: 'comic-cache.max-disk-size-subtitle'.trIn(context),
          value: _config.maxDiskSizeMB,
          min: 0,
          max: ComicCacheConfig.maxDiskSizeMBLimit,
          onChanged: (v) => _update(_config.copyWith(maxDiskSizeMB: v.round())),
        ),
        const SizedBox(height: 8),
        _switchRow(
          context: context,
          title: 'comic-cache.cache-on-read'.trIn(context),
          subtitle: 'comic-cache.cache-on-read-subtitle'.trIn(context),
          value: _config.cacheOnRead,
          onChanged: (v) => _update(_config.copyWith(cacheOnRead: v)),
        ),
        _switchRow(
          context: context,
          title: 'comic-cache.seamless-switch'.trIn(context),
          subtitle: 'comic-cache.seamless-switch-subtitle'.trIn(context),
          value: _config.seamlessChapterSwitch,
          onChanged: (v) => _update(_config.copyWith(seamlessChapterSwitch: v)),
        ),
      ],
    );
  }
}
