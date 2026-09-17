import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:get/get.dart';
import 'package:miru_app/controllers/watch/reader_controller.dart';
import 'package:miru_app/utils/i18n.dart';
import 'package:miru_app/views/widgets/button.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';

class ControlPanelFooter<T extends ReaderController> extends StatelessWidget {
  const ControlPanelFooter(this.tag, {super.key});
  final String tag;

  @override
  Widget build(BuildContext context) {
    final c = Get.find<T>(tag: tag);
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        // 用 `isAndroidLayout` 而不是 `Platform.isAndroid`：前者是仓库统一的
        // 判断源（`platform_widget.dart`），也是 Android 专属布局唯一的
        // 测试注入点（`debugForceAndroidLayout`）。直接读 `Platform.isAndroid`
        // 会让这段布局在 Windows/CI 上永远走不到、无法验证。
        color: isAndroidLayout
            ? Theme.of(context).colorScheme.background.withOpacity(0.9)
            : Colors.transparent,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(40),
          topRight: Radius.circular(40),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Obx(
        () => Row(
          children: [
            if (c.index.value > 0)
              PlatformFilledButton(
                // 用 `trIn(context)` 而不是 `.i18n`：后者依赖 `i18n.dart` 里
                // 缓存的**全局** context（Android 上是 `Get.context!`，一个
                // 顶层 `final`，只取一次），一旦那棵树被替换/销毁就会抛
                // 「Looking up a deactivated widget's ancestor is unsafe」。
                // 控制面板是叠在阅读器上的浮层，取自己所在树的 context 更可靠。
                child: Text('common.previous'.trIn(context)),
                onPressed: () {
                  c.index.value--;
                },
              ),
            const Spacer(),
            if (c.index.value != c.playList.length - 1)
              PlatformFilledButton(
                child: Text('common.next'.trIn(context)),
                onPressed: () {
                  c.index.value++;
                },
              ),
          ],
        ),
      ),
    ).animate().fade();
  }
}
