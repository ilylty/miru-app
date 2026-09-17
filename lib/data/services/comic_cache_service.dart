import 'dart:async';
import 'dart:collection';

import 'package:miru_app/models/comic_cache_config.dart';

/// 下载单张图片的实现，返回值表示是否成功。
typedef ComicImageFetcher = Future<bool> Function(
  String url,
  Map<String, String>? headers,
);

/// 判断某张图片是否已经在磁盘缓存里。
typedef ComicCacheProbe = Future<bool> Function(String url);

/// 按需解析某一话的内容（urls / headers）。返回 null 表示解析失败。
typedef ComicChapterLoader = Future<ComicCacheChapterTask?> Function(
  int chapterIndex,
);

/// 可注入的等待实现（测试时把间隔压缩为 0）。
typedef ComicCacheSleeper = Future<void> Function(Duration duration);

/// 可注入的时钟（测试时用于断言间隔）。
typedef ComicCacheClock = DateTime Function();

/// 磁盘上限回收：传入字节上限，返回实际删除的文件数。
typedef ComicCacheTrimmer = Future<int> Function(
  int maxBytes,
  Set<String> protectedUrls,
);

/// 一个待缓存的章节任务。
class ComicCacheChapterTask {
  ComicCacheChapterTask({
    required this.chapterIndex,
    required this.urls,
    this.headers,
  });

  /// 章节序号（相对于阅读器播放列表）。
  final int chapterIndex;

  /// 该章节的所有图片地址。
  final List<String> urls;

  /// 该章节请求所需的 headers。
  final Map<String, String>? headers;

  @override
  String toString() =>
      'ComicCacheChapterTask(chapter: $chapterIndex, images: ${urls.length})';
}

/// 缓存运行状态快照，供 UI 展示。
class ComicCacheStats {
  const ComicCacheStats({
    this.cached = 0,
    this.failed = 0,
    this.pending = 0,
    this.activeChapters = 0,
    this.queuedChapters = 0,
    this.cachedChapters = 0,
  });

  /// 已缓存成功的图片数。
  final int cached;

  /// 最终失败的图片数。
  final int failed;

  /// 正在下载中的图片数。
  final int pending;

  /// 正在处理的章节数。
  final int activeChapters;

  /// 排队等待的章节数。
  final int queuedChapters;

  /// 已经完整缓存完成的章节数。
  final int cachedChapters;

  @override
  String toString() => 'ComicCacheStats(cached: $cached, failed: $failed, '
      'pending: $pending, active: $activeChapters, queued: $queuedChapters, '
      'cachedChapters: $cachedChapters)';
}

class _CacheJob {
  _CacheJob.index(this.chapterIndex)
      : urls = null,
        headers = null;

  _CacheJob.task(ComicCacheChapterTask task)
      : chapterIndex = task.chapterIndex,
        urls = task.urls,
        headers = task.headers;

  final int chapterIndex;
  List<String>? urls;
  Map<String, String>? headers;
}

/// 漫画缓存调度器。
///
/// 生产端：把「当前话之后的 n 话」按配置的间隔缓存到本地磁盘。
/// 消费端：用户实际阅读的章节也会入队，间隔同样可配置。
///
/// 间隔语义：
///   - **l = [ComicCacheConfig.chapterInterval]**：任意两话「开始缓存」的时间差
///     至少为 l 秒（全局串行闸门，多个 worker 也不会破坏这个节奏）。
///   - **m = [ComicCacheConfig.imageInterval]**：同一话内两张图片下载之间的间隔。
///
/// 性能设计：
///   1. 优先级：越接近当前阅读位置的章节越先缓存，翻页命中率最高。
///   2. 并发受限：[ComicCacheConfig.maxConcurrent] 个 worker，避免连接数爆炸。
///   3. 去重：同一张图片只下载一次（在途 / 已缓存都会跳过）。
///   4. 可取消：[cancelAll] / [retainChapters] / [dispose] 立即停掉无用工作。
///   5. 失败退避：单张图有限次重试后标记失败，不阻塞队列。
///   6. 顺序收尾：同一 worker 内逐张下载，避免瞬时打开几十个连接。
class ComicCacheService {
  ComicCacheService({
    required ComicCacheConfig config,
    ComicChapterLoader? chapterLoader,
    ComicImageFetcher? fetcher,
    ComicCacheProbe? cacheProbe,
    ComicCacheSleeper? sleeper,
    ComicCacheClock? clock,
    ComicCacheTrimmer? trimmer,
    this.maxRetries = 2,
  })  : _config = config,
        _chapterLoader = chapterLoader,
        _fetcher = fetcher,
        _cacheProbe = cacheProbe,
        _sleeper = sleeper ?? Future<void>.delayed,
        _clock = clock ?? DateTime.now,
        _trimmer = trimmer;

  ComicCacheConfig _config;

  final ComicChapterLoader? _chapterLoader;
  final ComicImageFetcher? _fetcher;
  final ComicCacheProbe? _cacheProbe;
  final ComicCacheSleeper _sleeper;
  final ComicCacheClock _clock;

  /// 磁盘上限回收（null 表示不限制磁盘占用）。
  final ComicCacheTrimmer? _trimmer;

  /// 最近一次磁盘回收删除的文件数（供测试 / 诊断）。
  int lastTrimmedFiles = 0;

  /// 单张图片的最大重试次数。
  final int maxRetries;

  final Queue<_CacheJob> _queue = Queue<_CacheJob>();
  final Set<String> _inFlight = <String>{};
  final Set<String> _done = <String>{};
  final Set<String> _failed = <String>{};

  /// 已认领（排队 / 进行中 / 已完成）的章节，用于避免同一话被重复调度。
  final Set<int> _claimedChapters = <int>{};
  final Set<int> _activeChapters = <int>{};
  final Set<int> _completedChapters = <int>{};

  int _activeWorkers = 0;
  int _generation = 0;
  bool _disposed = false;

  /// 全局「话」间隔闸门的状态。
  DateTime? _lastChapterStart;
  Future<void> _chapterGate = Future<void>.value();

  ComicCacheConfig get config => _config;

  /// 更新配置（设置页改完立即生效，不需要重建服务）。
  void updateConfig(ComicCacheConfig config) {
    _config = config;
    if (!config.enabled) {
      cancelAll();
    }
  }

  bool get isDisposed => _disposed;

  /// 当前是否还有排队/进行中的工作。
  bool get isBusy => _queue.isNotEmpty || _activeWorkers > 0;

  ComicCacheStats get stats => ComicCacheStats(
        cached: _done.length,
        failed: _failed.length,
        pending: _inFlight.length,
        activeChapters: _activeChapters.length,
        queuedChapters: _queue.length,
        cachedChapters: _completedChapters.length,
      );

  /// 取消所有排队与进行中的任务。
  void cancelAll() {
    _generation++;
    for (final job in _queue) {
      _claimedChapters.remove(job.chapterIndex);
    }
    _queue.clear();
  }

  /// 只保留 [keepChapterIndexes] 里的章节，取消其它排队任务。
  ///
  /// 用户手动跳到很远的章节时调用，避免还在慢慢缓存已经无意义的章节。
  void retainChapters(Set<int> keepChapterIndexes) {
    if (_queue.isEmpty) {
      return;
    }
    final kept = Queue<_CacheJob>();
    var removed = 0;
    while (_queue.isNotEmpty) {
      final job = _queue.removeFirst();
      if (keepChapterIndexes.contains(job.chapterIndex)) {
        kept.add(job);
      } else {
        _claimedChapters.remove(job.chapterIndex);
        removed++;
      }
    }
    _queue.addAll(kept);
    if (removed > 0) {
      // 队列结构变了，让正在跑的 worker 在下一轮重新取任务。
      _generation++;
    }
  }

  /// 生产者：把「当前话之后的 n 话」加入缓存队列。
  ///
  /// [currentChapterIndex] 为当前阅读的章节序号，[totalChapters] 为总章节数。
  /// 返回实际入队的章节数量。
  int scheduleFollowingChapters({
    required int currentChapterIndex,
    required int totalChapters,
  }) {
    if (_disposed || !_config.enabled) {
      return 0;
    }
    final count = _config.preloadChapterCount;
    if (count <= 0) {
      return 0;
    }
    final indexes = <int>[];
    for (var offset = 1; offset <= count; offset++) {
      final chapterIndex = currentChapterIndex + offset;
      if (chapterIndex >= totalChapters) {
        break;
      }
      indexes.add(chapterIndex);
    }
    return scheduleChapters(indexes);
  }

  /// 把若干章节按「离当前阅读位置由近到远」的顺序入队。
  int scheduleChapters(Iterable<int> chapterIndexes, {int? fromChapter}) {
    if (_disposed || !_config.enabled) {
      return 0;
    }
    final sorted = chapterIndexes.toList();
    if (fromChapter != null) {
      sorted.sort((a, b) =>
          (a - fromChapter).abs().compareTo((b - fromChapter).abs()));
    }
    var scheduled = 0;
    for (final index in sorted) {
      if (enqueueChapterIndex(index)) {
        scheduled++;
      }
    }
    return scheduled;
  }

  /// 消费者：用户阅读时顺带缓存指定章节（URL 已知）。
  bool scheduleChapterTask(ComicCacheChapterTask task) {
    if (_disposed || !_config.enabled || !_config.cacheOnRead) {
      return false;
    }
    return _enqueue(_CacheJob.task(task));
  }

  /// 入队一个「按需解析」的章节。
  bool enqueueChapterIndex(int chapterIndex) =>
      _enqueue(_CacheJob.index(chapterIndex));

  bool _enqueue(_CacheJob job) {
    if (_disposed || !_config.enabled) {
      return false;
    }
    if (!_claimedChapters.add(job.chapterIndex)) {
      return false;
    }
    _queue.add(job);
    _pump();
    return true;
  }

  void _pump() {
    if (_disposed || !_config.enabled) {
      return;
    }
    final limit = _config.maxConcurrent;
    while (!_disposed &&
        _activeWorkers < limit &&
        _queue.isNotEmpty &&
        _config.enabled) {
      _activeWorkers++;
      unawaited(_workerLoop());
    }
  }

  /// 单个缓存 worker：取一话 → 按 m 的间隔逐张缓存 → 下一话（受 l 闸门限制）。
  Future<void> _workerLoop() async {
    try {
      while (!_disposed && _config.enabled) {
        if (_queue.isEmpty) {
          return;
        }
        final job = _queue.removeFirst();
        final generation = _generation;
        // 每一话之间的缓存间隔 l：全局串行闸门。
        await _acquireChapterSlot();
        if (!_isCurrent(generation)) {
          return;
        }
        _activeChapters.add(job.chapterIndex);
        var loaded = true;
        try {
          loaded = await _runChapter(job, generation);
        } finally {
          _activeChapters.remove(job.chapterIndex);
          if (loaded) {
            _completedChapters.add(job.chapterIndex);
          } else {
            // 章节内容没拿到（网络/解析失败）：释放认领，
            // 下次窗口同步时可以重试，而不是永久卡住这一话。
            _claimedChapters.remove(job.chapterIndex);
          }
        }
      }
    } finally {
      _activeWorkers--;
      if (!_disposed) {
        _pump();
      }
    }
  }

  /// 全局章节闸门：保证任意两话开始缓存的时间差 >= l。
  Future<void> _acquireChapterSlot() {
    final interval = _config.chapterIntervalDuration;
    final next = _chapterGate.then((_) async {
      if (_disposed || !_config.enabled) {
        return;
      }
      final last = _lastChapterStart;
      if (last != null) {
        final elapsed = _clock().difference(last);
        if (elapsed < interval) {
          await _sleeper(interval - elapsed);
        }
      }
      _lastChapterStart = _clock();
    });
    _chapterGate = next;
    return next;
  }

  /// 返回是否成功拿到章节内容。
  Future<bool> _runChapter(_CacheJob job, int generation) async {
    var urls = job.urls;
    var headers = job.headers;
    if (urls == null) {
      final loader = _chapterLoader;
      if (loader == null) {
        return false;
      }
      final task = await loader(job.chapterIndex);
      if (task == null) {
        return false;
      }
      urls = task.urls;
      headers = task.headers;
    }
    for (var i = 0; i < urls.length; i++) {
      if (!_isCurrent(generation)) {
        return true;
      }
      // 话内图片之间的间隔 m。
      if (i > 0 && _config.imageInterval > 0) {
        await _sleeper(_config.imageIntervalDuration);
        if (!_isCurrent(generation)) {
          return true;
        }
      }
      await _cacheOne(urls[i], headers, generation);
    }
    // 一话缓存完成后按配置回收磁盘（LRU，保护当前话）。
    await _enforceDiskLimit(urls);
    return true;
  }

  /// 按 [ComicCacheConfig.maxDiskSizeMB] 回收磁盘缓存。
  ///
  /// [protectedUrls] 是刚刚缓存的那一话：即使它让总量超限也不删，
  /// 否则会出现「刚下完就被删、阅读时又得重下」的抖动。
  Future<void> _enforceDiskLimit(List<String> protectedUrls) async {
    final trimmer = _trimmer;
    final limitMB = _config.maxDiskSizeMB;
    if (trimmer == null || limitMB <= 0) {
      return;
    }
    try {
      lastTrimmedFiles = await trimmer(
        limitMB * 1024 * 1024,
        protectedUrls.toSet(),
      );
    } catch (_) {
      // 回收失败不能影响阅读 / 缓存主流程。
    }
  }

  /// 缓存一张图片；已缓存 / 在途的图片会被跳过。
  Future<bool> _cacheOne(
    String url,
    Map<String, String>? headers,
    int generation,
  ) async {
    if (_done.contains(url) || _inFlight.contains(url)) {
      return true;
    }
    if (!_isCurrent(generation)) {
      return false;
    }
    if (_cacheProbe != null) {
      try {
        if (await _cacheProbe!(url)) {
          _done.add(url);
          return true;
        }
      } catch (_) {
        // 探测失败就继续走下载流程。
      }
    }
    _inFlight.add(url);
    try {
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        if (!_isCurrent(generation)) {
          return false;
        }
        final ok = await _fetch(url, headers);
        if (ok) {
          _done.add(url);
          _failed.remove(url);
          return true;
        }
        if (attempt < maxRetries) {
          // 线性退避，避免对同一个坏链接疯狂重试。
          await _sleeper(Duration(milliseconds: 300 * (attempt + 1)));
        }
      }
      _failed.add(url);
      return false;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<bool> _fetch(String url, Map<String, String>? headers) async {
    final fetcher = _fetcher;
    if (fetcher != null) {
      try {
        return await fetcher(url, headers);
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void dispose() {
    _disposed = true;
    _queue.clear();
    _claimedChapters.clear();
  }
}
