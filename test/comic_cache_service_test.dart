import 'package:flutter_test/flutter_test.dart';
import 'package:miru_app/data/services/comic_cache_service.dart';
import 'package:miru_app/models/comic_cache_config.dart';

/// 记录每次调用的时间与顺序，用于断言 l / m 间隔真的生效。
class Recorder {
  final List<({String url, DateTime at})> downloads = [];
  final List<({int chapter, DateTime at})> chapterStarts = [];
  final List<Duration> sleeps = [];

  final List<String> _pending = [];

  void reset() {
    downloads.clear();
    chapterStarts.clear();
    sleeps.clear();
    _pending.clear();
  }
}

/// 构造一个可控的缓存服务：
///   * fetcher 立即成功，并记录下载时间；
///   * chapterLoader 记录每话开始时间；
///   * sleeper 记录间隔（并把真实等待压缩成 microtask，测试飞快）。
ComicCacheService buildService({
  required ComicCacheConfig config,
  required Recorder recorder,
  Map<int, List<String>>? chapters,
  Set<String>? failing,
  int? maxRetries,
  ComicCacheTrimmer? trimmer,
}) {
  final data = chapters ?? const <int, List<String>>{};
  return ComicCacheService(
    config: config,
    maxRetries: maxRetries ?? 0,
    chapterLoader: (chapterIndex) async {
      recorder.chapterStarts
          .add((chapter: chapterIndex, at: DateTime.now()));
      final urls = data[chapterIndex];
      if (urls == null) {
        return null;
      }
      return ComicCacheChapterTask(chapterIndex: chapterIndex, urls: urls);
    },
    fetcher: (url, headers) async {
      recorder.downloads.add((url: url, at: DateTime.now()));
      return !(failing?.contains(url) ?? false);
    },
    sleeper: (duration) async {
      recorder.sleeps.add(duration);
      // 不真的睡，只让出事件循环，保证顺序仍被尊重。
      await Future<void>.delayed(Duration.zero);
    },
    trimmer: trimmer,
  );
}


/// 间隔断言工具：把「秒级间隔」与「退避重试」区分开。
///
/// 生产实现会用 `l - 已经过的时间` 计算剩余等待，所以真实等待会略小于 l
/// （差值为几毫秒的调度开销）。这里统一用「下界 + 容差」判断。
class IntervalStats {
  IntervalStats(this.sleeps);

  final List<Duration> sleeps;

  static const Duration tolerance = Duration(milliseconds: 200);

  /// 所有 >= [atLeast] 的等待（排除 300ms/600ms 这类重试退避）。
  List<Duration> atLeast(Duration atLeast) =>
      sleeps.where((d) => d >= atLeast - tolerance).toList();

  /// 累计等待时长。
  ///
  /// 实现用 `l - elapsed` 计算剩余等待，因此每段都会比 l 少几毫秒
  /// （调度开销）。断言时按「下界 - 容差 * 段数」比较。
  Duration totalAtLeast(Duration atLeast) =>
      this.atLeast(atLeast).fold(Duration.zero, (a, b) => a + b);

  /// 段数 * (间隔 - 容差)：可靠的下界。
  Duration lowerBound(Duration interval, int segments) => Duration(
        microseconds: segments *
            (interval.inMicroseconds - tolerance.inMicroseconds),
      );
}

void main() {
  late Recorder recorder;

  setUp(() => recorder = Recorder());

  group('生产端：自动缓存后 n 话', () {
    test('只缓存当前话之后的 n 话，不含当前话与更远的话', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          0: ['c0-1'],
          1: ['c1-1'],
          2: ['c2-1'],
          3: ['c3-1'],
          4: ['c4-1'],
        },
      );

      final scheduled = service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 5,
      );
      expect(scheduled, 2, reason: 'n=2 时应该只入队第 1、2 话');

      await pumpUntil(() => !service.isBusy);

      final chaptersCached =
          recorder.chapterStarts.map((e) => e.chapter).toSet();
      expect(chaptersCached, {1, 2});
      expect(recorder.downloads.map((e) => e.url).toSet(),
          {'c1-1', 'c2-1'});
      service.dispose();
    });

    test('n=0 时生产端不缓存任何章节', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 0,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {1: ['c1-1']},
      );
      expect(
        service.scheduleFollowingChapters(
          currentChapterIndex: 0,
          totalChapters: 5,
        ),
        0,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads, isEmpty);
      service.dispose();
    });

    test('到达最后一话时不越界', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 5,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {3: ['c3-1'], 4: ['c4-1']},
      );
      final scheduled = service.scheduleFollowingChapters(
        currentChapterIndex: 4,
        totalChapters: 5,
      );
      expect(scheduled, 0);
      service.dispose();
    });

    test('禁用缓存时不入队', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          enabled: false,
          preloadChapterCount: 3,
          chapterInterval: 0,
          imageInterval: 0,
        ),
        recorder: recorder,
        chapters: {1: ['c1-1']},
      );
      expect(
        service.scheduleFollowingChapters(
          currentChapterIndex: 0,
          totalChapters: 5,
        ),
        0,
      );
      expect(service.isBusy, isFalse);
      service.dispose();
    });
  });

  group('★ 磁盘上限（maxDiskSizeMB）', () {
    test('配置了磁盘上限时，一话缓存完会触发回收（并保护刚缓存的那一话）',
        () async {
      final trims = <({int maxBytes, Set<String> protectedUrls})>[];
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          maxDiskSizeMB: 50,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1', 'c1-2'],
        },
        trimmer: (maxBytes, protectedUrls) async {
          trims.add((maxBytes: maxBytes, protectedUrls: protectedUrls));
          return 0;
        },
      );
      addTearDown(service.dispose);

      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 5,
      );
      await pumpUntil(() => !service.isBusy);

      expect(trims.length, 1, reason: '每话缓存完成后回收一次');
      expect(trims.first.maxBytes, 50 * 1024 * 1024,
          reason: 'MB 应换算成字节');
      expect(trims.first.protectedUrls, containsAll(['c1-1', 'c1-2']),
          reason: '刚缓存的那一话必须受保护，不能被自己删掉');
    });

    test('maxDiskSizeMB=0（不限制）时不做任何回收', () async {
      var trimCalls = 0;
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          maxDiskSizeMB: 0,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
        },
        trimmer: (maxBytes, protectedUrls) async {
          trimCalls++;
          return 0;
        },
      );
      addTearDown(service.dispose);

      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 5,
      );
      await pumpUntil(() => !service.isBusy);

      expect(trimCalls, 0, reason: '0 表示不限制磁盘占用');
    });

    test('回收失败不会中断缓存流程（已缓存的图仍然是成功的）', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          maxDiskSizeMB: 10,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1', 'c1-2'],
        },
        trimmer: (maxBytes, protectedUrls) async =>
            throw StateError('disk error'),
      );
      addTearDown(service.dispose);

      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 5,
      );
      await pumpUntil(() => !service.isBusy);

      expect(service.stats.cached, 2, reason: '回收异常不应影响已下载的图');
      expect(service.stats.cachedChapters, 1);
    });
  });

  group('★ 每一话缓存间隔 l', () {
    test('两话开始缓存的间隔 >= l（单 worker）', () async {
      const l = 3;
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 3,
          chapterInterval: l,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
          2: ['c2-1'],
          3: ['c3-1'],
        },
      );

      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 4,
      );
      await pumpUntil(() => !service.isBusy);

      expect(recorder.chapterStarts.length, 3);
      // 闸门等待次数 = 话数 - 1（第一话不需要等）。
      final stats = IntervalStats(recorder.sleeps);
      expect(stats.atLeast(const Duration(seconds: l)).length, 2,
          reason: '3 话之间应该有 2 次 l 间隔等待，实际: ${recorder.sleeps}');
      expect(stats.totalAtLeast(const Duration(seconds: l)),
          greaterThanOrEqualTo(stats.lowerBound(const Duration(seconds: l), 2)),
          reason: '话间隔的总等待时间应约等于 2 * l');
      service.dispose();
    });

    test('l=0 时不做任何话间隔等待', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 2,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
          2: ['c2-1'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 3,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.sleeps, isEmpty);
      service.dispose();
    });

    test('多 worker 并发时 l 仍是全局闸门（不会各自独立计时）', () async {
      const l = 2;
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 4,
          chapterInterval: l,
          imageInterval: 0,
          maxConcurrent: 4,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
          2: ['c2-1'],
          3: ['c3-1'],
          4: ['c4-1'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 5,
      );
      await pumpUntil(() => !service.isBusy);

      expect(recorder.chapterStarts.length, 4);
      // 4 话 => 至少 3 次闸门等待，即使并发度是 4。
      final stats = IntervalStats(recorder.sleeps);
      expect(stats.atLeast(const Duration(seconds: l)).length,
          greaterThanOrEqualTo(3),
          reason: '全局闸门必须让 4 话串成 3 个间隔，而不是同时开工。'
              '实际: ${recorder.sleeps}');
      expect(
          stats.totalAtLeast(const Duration(seconds: l)),
          greaterThanOrEqualTo(
              stats.lowerBound(const Duration(seconds: l), 3)));
      service.dispose();
    });
  });

  group('★ 一话内图片缓存间隔 m', () {
    test('同一话内每两张图之间有 m 间隔（N 张图 => N-1 次等待）', () async {
      const m = 5;
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: m,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['a', 'b', 'c', 'd'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 2,
      );
      await pumpUntil(() => !service.isBusy);

      expect(recorder.downloads.length, 4);
      final stats = IntervalStats(recorder.sleeps);
      expect(stats.atLeast(const Duration(seconds: m)).length, 3,
          reason: '4 张图之间应该有 3 个 m 间隔，实际: ${recorder.sleeps}');
      expect(stats.totalAtLeast(const Duration(seconds: m)),
          greaterThanOrEqualTo(stats.lowerBound(const Duration(seconds: m), 3)));
      service.dispose();
    });

    test('m=0 时同一话内连续下载（无等待）', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['a', 'b', 'c'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 2,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads.length, 3);
      expect(recorder.sleeps, isEmpty);
      service.dispose();
    });

    test('l 与 m 同时生效：话间 l、话内 m', () async {
      const l = 4;
      const m = 2;
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 2,
          chapterInterval: l,
          imageInterval: m,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['1a', '1b'],
          2: ['2a', '2b'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 3,
      );
      await pumpUntil(() => !service.isBusy);

      expect(recorder.downloads.length, 4);
      final stats = IntervalStats(recorder.sleeps);
      // l 的等待明显长于 m，可以用阈值区分两类间隔。
      expect(
        stats.atLeast(const Duration(seconds: l)).length,
        1,
        reason: '2 话 => 1 次 l，实际: ${recorder.sleeps}',
      );
      expect(
        stats.totalAtLeast(const Duration(seconds: l)),
        greaterThanOrEqualTo(stats.lowerBound(const Duration(seconds: l), 1)),
      );
      final imageWaits = recorder.sleeps
          .where((d) => d >= const Duration(seconds: m) - IntervalStats.tolerance)
          .where((d) => d < const Duration(seconds: l) - IntervalStats.tolerance)
          .toList();
      expect(imageWaits.length, 2,
          reason: '每话 2 张图 => 每话 1 次 m，共 2 次，实际: ${recorder.sleeps}');
      service.dispose();
    });
  });

  group('消费者：阅读时顺带缓存', () {
    test('cacheOnRead=true 时当前话会入队', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 0,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: true,
        ),
        recorder: recorder,
      );
      final ok = service.scheduleChapterTask(
        ComicCacheChapterTask(chapterIndex: 0, urls: ['cur-1', 'cur-2']),
      );
      expect(ok, isTrue);
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads.map((e) => e.url).toSet(), {'cur-1', 'cur-2'});
      service.dispose();
    });

    test('cacheOnRead=false 时当前话不入队', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 0,
          chapterInterval: 0,
          imageInterval: 0,
          cacheOnRead: false,
        ),
        recorder: recorder,
      );
      expect(
        service.scheduleChapterTask(
          ComicCacheChapterTask(chapterIndex: 0, urls: ['cur-1']),
        ),
        isFalse,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads, isEmpty);
      service.dispose();
    });

    test('生产端与消费端可以同时工作', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 2,
          cacheOnRead: true,
        ),
        recorder: recorder,
        chapters: {1: ['next-1']},
      );
      service.scheduleChapterTask(
        ComicCacheChapterTask(chapterIndex: 0, urls: ['cur-1']),
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 2,
      );
      await pumpUntil(() => !service.isBusy);
      expect(
        recorder.downloads.map((e) => e.url).toSet(),
        {'cur-1', 'next-1'},
      );
      service.dispose();
    });
  });

  group('去重 / 取消 / 失败处理（性能与正确性）', () {
    test('同一章节重复入队只下载一次', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 0,
          chapterInterval: 0,
          imageInterval: 0,
        ),
        recorder: recorder,
      );
      final task =
          ComicCacheChapterTask(chapterIndex: 1, urls: ['dup-1', 'dup-2']);
      expect(service.scheduleChapterTask(task), isTrue);
      expect(service.scheduleChapterTask(task), isFalse,
          reason: '同一章节不应重复入队');
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads.length, 2);
      service.dispose();
    });

    test('cancelAll 之后不再下载', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 3,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
          2: ['c2-1'],
          3: ['c3-1'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 4,
      );
      service.cancelAll();
      await pumpUntil(() => !service.isBusy);
      // 取消后队列清空，最多只有取消前已经开始的那一话被下载。
      expect(recorder.downloads.length, lessThanOrEqualTo(1));
      service.dispose();
    });

    test('retainChapters 丢掉已经远离的章节', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 5,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          for (var i = 1; i <= 5; i++) i: ['c$i-1'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 6,
      );
      // 用户跳到第 5 话：只保留 4..5 附近的章节。
      service.retainChapters({4, 5});
      await pumpUntil(() => !service.isBusy);
      final chapters = recorder.chapterStarts.map((e) => e.chapter).toSet();
      expect(chapters.every((c) => c >= 4), isTrue,
          reason: '保留下来的章节应该只有 4、5，实际: $chapters');
      service.dispose();
    });

    test('单张图失败会被标记，不影响其它图', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['good-1', 'bad', 'good-2'],
        },
        failing: {'bad'},
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 2,
      );
      await pumpUntil(() => !service.isBusy);

      final stats = service.stats;
      expect(stats.cached, 2);
      expect(stats.failed, 1);
      service.dispose();
    });

    test('失败的图片会按 maxRetries 重试', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['bad'],
        },
        failing: {'bad'},
        maxRetries: 2,
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 2,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.downloads.length, 3, reason: '首次 + 2 次重试 = 3 次');
      service.dispose();
    });

    test('dispose 之后不再接受新任务', () async {
      final service = buildService(
        config: const ComicCacheConfig(preloadChapterCount: 3),
        recorder: recorder,
        chapters: {1: ['c1-1']},
      );
      service.dispose();
      expect(
        service.scheduleFollowingChapters(
          currentChapterIndex: 0,
          totalChapters: 5,
        ),
        0,
      );
      expect(service.isDisposed, isTrue);
    });

    test('★ updateConfig 后新的 n / l / m 立即生效（不用重建服务）', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1', 'c1-2'],
          2: ['c2-1', 'c2-2'],
          3: ['c3-1', 'c3-2'],
          4: ['c4-1', 'c4-2'],
          5: ['c5-1', 'c5-2'],
          6: ['c6-1', 'c6-2'],
        },
      );
      addTearDown(service.dispose);

      // 先用 n=1, l=0, m=0 跑一轮。
      service.updateConfig(
        const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 1,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 10,
      );
      await pumpUntil(() => !service.isBusy);
      expect(recorder.chapterStarts.length, 1, reason: 'n=1 只缓存下一话');
      expect(recorder.downloads.length, 2, reason: '该话的 2 张图都被缓存');
      recorder.reset();

      // 改成 n=3, l=2, m=1 再跑一轮：话数与间隔都应立刻跟随。
      // 换一个当前话（3 => 后 3 话是 4/5/6），避开上一轮的去重集合。
      recorder.reset();
      service.updateConfig(
        const ComicCacheConfig(
          enabled: true,
          preloadChapterCount: 3,
          chapterInterval: 2,
          imageInterval: 1,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 3,
        totalChapters: 10,
      );
      await pumpUntil(() => !service.isBusy);

      expect(recorder.chapterStarts.length, 3, reason: 'n=3 应缓存后 3 话');
      expect(
        recorder.chapterStarts.map((e) => e.chapter).toList(),
        [4, 5, 6],
        reason: '生产端缓存的应该是「当前话之后 n 话」',
      );

      // 新的 l=2 立刻生效：3 话 => 至少 2 个话间闸门。
      // （第一个闸门可能被上一轮的 _lastChapterStart 吸收，所以用 >= 2
      //  而不是 == 2；闸门是全局的，这是刻意的语义。）
      final stats = IntervalStats(recorder.sleeps);
      final gateSleeps = stats.atLeast(const Duration(seconds: 2));
      expect(gateSleeps.length, greaterThanOrEqualTo(2),
          reason: '新的 l=2 应立刻生效，实际: ${recorder.sleeps}');
      expect(stats.totalAtLeast(const Duration(seconds: 2)),
          greaterThanOrEqualTo(
              stats.lowerBound(const Duration(seconds: 2), 2)),
          reason: '话间总等待应约等于 2 * l');

      // 新的 m=1 立刻生效：每话 2 张图 => 每话 1 次 m，共 3 次。
      final imageSleeps = recorder.sleeps
          .where((d) =>
              d >= const Duration(seconds: 1) - IntervalStats.tolerance &&
              d < const Duration(seconds: 2) - IntervalStats.tolerance)
          .toList();
      expect(imageSleeps.length, 3,
          reason: '新的 m=1 应立刻生效，实际: ${recorder.sleeps}');
    });

    test('updateConfig 关闭缓存会立即取消在途工作', () async {
      final service = buildService(
        config: const ComicCacheConfig(
          preloadChapterCount: 3,
          chapterInterval: 0,
          imageInterval: 0,
          maxConcurrent: 1,
          cacheOnRead: false,
        ),
        recorder: recorder,
        chapters: {
          1: ['c1-1'],
          2: ['c2-1'],
          3: ['c3-1'],
        },
      );
      service.scheduleFollowingChapters(
        currentChapterIndex: 0,
        totalChapters: 4,
      );
      service.updateConfig(
        service.config.copyWith(enabled: false),
      );
      await pumpUntil(() => !service.isBusy);
      expect(service.config.enabled, isFalse);
      expect(service.stats.queuedChapters, 0);
      service.dispose();
    });
  });
}

/// 等待条件成立（带超时，避免测试挂死）。
Future<void> pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('pumpUntil 超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
