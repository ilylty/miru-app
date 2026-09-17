/// 漫画缓存配置（可在设置中配置）。
///
/// 生产端（producer）：自动缓存「当前话之后」的 n 话。
/// 消费端（consumer）：用户实际阅读时，
///   - 每话之间的缓存间隔为 [chapterInterval]（l）
///   - 一话内部图片之间的缓存间隔为 [imageInterval]（m）
///
/// 所有字段都可配置，且都会做安全裁剪，避免出现 0 间隔疯狂请求或者
/// 负数导致逻辑异常。
class ComicCacheConfig {
  const ComicCacheConfig({
    this.enabled = true,
    this.preloadChapterCount = defaultPreloadChapterCount,
    this.chapterInterval = 3,
    this.imageInterval = 1,
    this.maxConcurrent = 3,
    this.maxDiskSizeMB = 0,
    this.cacheOnRead = true,
    this.seamlessChapterSwitch = true,
  });

  /// 是否开启漫画缓存。
  final bool enabled;

  /// 自动缓存后面 n 话（生产者）。
  final int preloadChapterCount;

  /// 每一话之间的缓存间隔 l（秒）。
  final int chapterInterval;

  /// 一话内部图片之间的缓存间隔 m（秒）。
  final int imageInterval;

  /// 同时进行的最大缓存并发数。
  final int maxConcurrent;

  /// 磁盘缓存上限（MB），0 表示不限制（由系统清理）。
  final int maxDiskSizeMB;

  /// 用户阅读时是否顺带缓存（消费者触发）。
  final bool cacheOnRead;

  /// 条漫模式下翻页/回拉章节时是否使用无感（瀑布流）切换。
  final bool seamlessChapterSwitch;

  /// 各字段取值范围。
  static const int minPreloadChapterCount = 0;
  static const int maxPreloadChapterCount = 20;
  static const int maxIntervalSeconds = 60;
  static const int minConcurrent = 1;
  static const int maxConcurrentLimit = 8;
  static const int maxDiskSizeMBLimit = 10240;

  /// 默认「后 n 话」（设置页默认值与模型保持一致）。
  static const int defaultPreloadChapterCount = 2;

  static int _clampInt(int? value, int min, int max, int fallback) {
    if (value == null) return fallback;
    if (value.isNaN) return fallback;
    return value.clamp(min, max).toInt();
  }

  static bool _readBool(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.toLowerCase().trim();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
  }

  /// 从存储中读取配置，任何非法值都会被裁剪到安全范围。
  factory ComicCacheConfig.fromMap(Map<dynamic, dynamic>? map) {
    final data = map ?? const <dynamic, dynamic>{};
    const fallback = ComicCacheConfig();
    return ComicCacheConfig(
      enabled: _readBool(data['enabled'], fallback.enabled),
      preloadChapterCount: _clampInt(
        _asInt(data['preloadChapterCount']),
        minPreloadChapterCount,
        maxPreloadChapterCount,
        fallback.preloadChapterCount,
      ),
      chapterInterval: _clampInt(
        _asInt(data['chapterInterval']),
        0,
        maxIntervalSeconds,
        fallback.chapterInterval,
      ),
      imageInterval: _clampInt(
        _asInt(data['imageInterval']),
        0,
        maxIntervalSeconds,
        fallback.imageInterval,
      ),
      maxConcurrent: _clampInt(
        _asInt(data['maxConcurrent']),
        minConcurrent,
        maxConcurrentLimit,
        fallback.maxConcurrent,
      ),
      maxDiskSizeMB: _clampInt(
        _asInt(data['maxDiskSizeMB']),
        0,
        maxDiskSizeMBLimit,
        fallback.maxDiskSizeMB,
      ),
      cacheOnRead: _readBool(data['cacheOnRead'], fallback.cacheOnRead),
      seamlessChapterSwitch: _readBool(
        data['seamlessChapterSwitch'],
        fallback.seamlessChapterSwitch,
      ),
    );
  }

  static int? _asInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  Map<String, dynamic> toMap() => {
        'enabled': enabled,
        'preloadChapterCount': preloadChapterCount,
        'chapterInterval': chapterInterval,
        'imageInterval': imageInterval,
        'maxConcurrent': maxConcurrent,
        'maxDiskSizeMB': maxDiskSizeMB,
        'cacheOnRead': cacheOnRead,
        'seamlessChapterSwitch': seamlessChapterSwitch,
      };

  ComicCacheConfig copyWith({
    bool? enabled,
    int? preloadChapterCount,
    int? chapterInterval,
    int? imageInterval,
    int? maxConcurrent,
    int? maxDiskSizeMB,
    bool? cacheOnRead,
    bool? seamlessChapterSwitch,
  }) {
    return ComicCacheConfig(
      enabled: enabled ?? this.enabled,
      preloadChapterCount: preloadChapterCount ?? this.preloadChapterCount,
      chapterInterval: chapterInterval ?? this.chapterInterval,
      imageInterval: imageInterval ?? this.imageInterval,
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      maxDiskSizeMB: maxDiskSizeMB ?? this.maxDiskSizeMB,
      cacheOnRead: cacheOnRead ?? this.cacheOnRead,
      seamlessChapterSwitch:
          seamlessChapterSwitch ?? this.seamlessChapterSwitch,
    );
  }

  Duration get chapterIntervalDuration => Duration(seconds: chapterInterval);

  Duration get imageIntervalDuration => Duration(seconds: imageInterval);

  @override
  bool operator ==(Object other) {
    return other is ComicCacheConfig &&
        other.enabled == enabled &&
        other.preloadChapterCount == preloadChapterCount &&
        other.chapterInterval == chapterInterval &&
        other.imageInterval == imageInterval &&
        other.maxConcurrent == maxConcurrent &&
        other.maxDiskSizeMB == maxDiskSizeMB &&
        other.cacheOnRead == cacheOnRead &&
        other.seamlessChapterSwitch == seamlessChapterSwitch;
  }

  @override
  int get hashCode => Object.hash(
        enabled,
        preloadChapterCount,
        chapterInterval,
        imageInterval,
        maxConcurrent,
        maxDiskSizeMB,
        cacheOnRead,
        seamlessChapterSwitch,
      );

  @override
  String toString() => 'ComicCacheConfig(enabled: $enabled, '
      'preload: $preloadChapterCount, chapterInterval: ${chapterInterval}s, '
      'imageInterval: ${imageInterval}s, maxConcurrent: $maxConcurrent, '
      'maxDiskSizeMB: $maxDiskSizeMB, cacheOnRead: $cacheOnRead, '
      'seamlessChapterSwitch: $seamlessChapterSwitch)';
}
