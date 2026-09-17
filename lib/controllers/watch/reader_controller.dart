import 'dart:async';

import 'package:get/get.dart';
import 'package:miru_app/models/extension.dart';
import 'package:miru_app/models/history.dart';
import 'package:miru_app/controllers/home_controller.dart';
import 'package:miru_app/data/services/database_service.dart';
import 'package:miru_app/data/services/extension_service.dart';
import 'package:miru_app/utils/immersive_mode.dart';

class ReaderController<T> extends GetxController {
  final String title;
  final List<ExtensionEpisode> playList;
  final String detailUrl;
  final int playIndex;
  final int episodeGroupId;
  final ExtensionService runtime;
  final String? cover;
  final String anilistID;

  ReaderController({
    required this.title,
    required this.playList,
    required this.detailUrl,
    required this.playIndex,
    required this.episodeGroupId,
    required this.runtime,
    required this.anilistID,
    this.cover,
  });

  late Rx<T?> watchData = Rx(null);
  final error = ''.obs;
  final isShowControlPanel = false.obs;
  late final index = playIndex.obs;
  get cuurentPlayUrl => playList[index.value].url;
  Timer? _timer;

  /// 是否已进入沉浸模式。
  ///
  /// 用实例字段而不是只依赖 [ImmersiveMode] 的引用计数：
  /// GetX 在「注册了但从未构建就删除」时也会调用 `onClose`，
  /// 那时 `onInit` 从未跑过，不能去配对地减少计数。
  bool _immersiveEntered = false;

  @override
  void onInit() {
    // 阅读时隐藏系统栏（状态栏 + 底部导航 / 手势条）。
    //
    // ★ Android 上 `Scaffold` 只会把内容限制在系统栏之间，状态栏与底部
    //   「小白条」依然可见 —— 漫画/小说阅读时这既浪费屏幕也干扰沉浸感。
    //   做法与视频播放器一致（`SystemUiMode.immersiveSticky`），
    //   但放在基类里，让漫画与小说阅读器都生效。
    _enterImmersive();
    getContent();
    ever(index, (callback) => getContent());
    super.onInit();
  }

  void _enterImmersive() {
    if (_immersiveEntered) {
      return;
    }
    _immersiveEntered = true;
    unawaited(ImmersiveMode.enter());
  }

  @override
  void onClose() {
    if (_immersiveEntered) {
      _immersiveEntered = false;
      unawaited(ImmersiveMode.exit());
    }
    super.onClose();
  }

  getContent() async {
    try {
      error.value = '';
      watchData.value = null;
      watchData.value = await runtime.watch(cuurentPlayUrl) as T;
    } catch (e) {
      error.value = e.toString();
    }
  }

  void previousPage() {}

  void nextPage() {}

  showControlPanel() {
    isShowControlPanel.value = true;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), () {
      isShowControlPanel.value = false;
    });
  }

  addHistory(String progress, String totalProgress) async {
    await DatabaseService.putHistory(
      History()
        ..url = detailUrl
        ..episodeId = index.value
        ..type = runtime.extension.type
        ..episodeGroupId = episodeGroupId
        ..package = runtime.extension.package
        ..episodeTitle = playList[index.value].name
        ..title = title
        ..progress = progress
        ..totalProgress = totalProgress
        ..cover = cover,
    );
    await Get.find<HomePageController>().onRefresh();
  }
}
