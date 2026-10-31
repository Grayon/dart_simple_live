import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';

import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// 观众指标（在线人数/贵宾/舰长/看过/热度）
///
/// 直播间信息栏与全屏 HUD 共用：平台公开了真实人数的（抖音观看人次、
/// B站看过人数、斗鱼贵宾/B站舰长）优先展示，热度/人气放最后。
/// [onDarkBackground] 为 true 时使用白字，用于全屏播放的半透明 HUD。
class AudienceMetrics extends StatelessWidget {
  final LiveRoomController controller;

  /// 深色背景上的白字样式（全屏 HUD）
  final bool onDarkBackground;

  /// 横向排列（HUD 空间有限），否则纵向排列（信息栏）
  final bool horizontal;

  const AudienceMetrics({
    super.key,
    required this.controller,
    this.onDarkBackground = false,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final detail = controller.detail.value;
      final siteId = controller.site.id;
      final textColor = onDarkBackground ? Colors.white : null;
      final chips = <Widget>[];

      void addChip(IconData icon, Color color, String text, String tooltip) {
        chips.add(
          Tooltip(
            message: tooltip,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: color),
                AppStyle.hGap4,
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      if (siteId == "bilibili") {
        final realOnline = controller.realOnlineCount.value;
        if (realOnline > 0) {
          addChip(
            Remix.user_smile_line,
            const Color(0xFF7FB3FF),
            "${Utils.onlineToString(realOnline)}人在线",
            "直播间实时在线观众数（与B站App一致，仅部分房间开放）",
          );
        }
        // WS WATCHED_CHANGE 实时更新；未推送时回退进房接口的累计看过数
        final watched = controller.watchedCount.value > 0
            ? controller.watchedCount.value
            : (detail?.watchedCount ?? 0);
        if (watched > 0) {
          addChip(
            Remix.eye_line,
            const Color(0xFF7FB3FF),
            "${Utils.onlineToString(watched)}人看过",
            "累计看过人数（平台公开的真实人次）",
          );
        }
        final guards = controller.nobleCount.value;
        if (guards > 0) {
          addChip(
            Remix.vip_crown_fill,
            Colors.amber.shade600,
            "舰长${Utils.onlineToString(guards)}",
            "大航海（舰长/提督/总督）在线数，真实人数",
          );
        }
      } else if (siteId == "douyu") {
        final noble = controller.nobleCount.value;
        if (noble > 0) {
          addChip(
            Remix.vip_crown_fill,
            Colors.amber.shade600,
            "贵宾${Utils.onlineToString(noble)}",
            "贵宾在线数（与斗鱼手机App一致），真实人数的下限参考",
          );
        }
      }

      // 热度/人气（抖音的 online 本身就是真实观看人次）
      final isReal = Utils.isRealAudienceCount(siteId);
      addChip(
        isReal ? Remix.user_smile_line : Remix.fire_fill,
        isReal ? const Color(0xFF7FB3FF) : Colors.orange,
        Utils.onlineToString(detail?.online ?? 0),
        Utils.audienceMetricName(siteId),
      );

      if (horizontal) {
        // HUD 空间有限，超长时等比缩小而不是滚动
        return FittedBox(
          alignment: Alignment.centerLeft,
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < chips.length; i++) ...[
                if (i > 0) AppStyle.hGap12,
                chips[i],
              ],
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) AppStyle.vGap4,
            chips[i],
          ],
        ],
      );
    });
  }
}
