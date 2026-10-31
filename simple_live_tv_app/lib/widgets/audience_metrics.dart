import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';

import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';

/// 全屏 HUD 标题下方的观众指标（在线人数/贵宾/舰长/看过/热度）。
/// 平台公开了真实人数的优先展示，热度/人气放最后。
class AudienceMetrics extends StatelessWidget {
  final LiveRoomController controller;

  const AudienceMetrics({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final detail = controller.detail.value;
      final siteId = controller.site.id;
      final chips = <Widget>[];

      void addChip(IconData icon, Color color, String text) {
        chips.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24.w, color: color),
            SizedBox(width: 6.w),
            Text(
              text,
              style: TextStyle(fontSize: 22.w, color: Colors.white),
            ),
          ],
        ));
      }

      if (siteId == "bilibili") {
        final realOnline = controller.realOnlineCount.value;
        if (realOnline > 0) {
          addChip(Remix.user_smile_line, const Color(0xFF7FB3FF),
              "${Utils.onlineToString(realOnline)}人在线");
        }
        final watched = controller.watchedCount.value > 0
            ? controller.watchedCount.value
            : (detail?.watchedCount ?? 0);
        if (watched > 0) {
          addChip(Remix.eye_line, const Color(0xFF7FB3FF),
              "${Utils.onlineToString(watched)}人看过");
        }
        final guards = controller.nobleCount.value;
        if (guards > 0) {
          addChip(Remix.vip_crown_fill, Colors.amber.shade600,
              "舰长${Utils.onlineToString(guards)}");
        }
      } else if (siteId == "douyu") {
        final noble = controller.nobleCount.value;
        if (noble > 0) {
          addChip(Remix.vip_crown_fill, Colors.amber.shade600,
              "贵宾${Utils.onlineToString(noble)}");
        }
      }

      // 热度/人气（抖音的 online 本身就是真实观看人次）
      final isReal = Utils.isRealAudienceCount(siteId);
      addChip(
        isReal ? Remix.user_smile_line : Remix.fire_fill,
        isReal ? const Color(0xFF7FB3FF) : Colors.orange,
        Utils.onlineToString(detail?.online ?? 0),
      );

      // TV 上横向排布、等比缩小
      return FittedBox(
        alignment: Alignment.centerLeft,
        fit: BoxFit.scaleDown,
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) SizedBox(width: 20.w),
              chips[i],
            ],
          ],
        ),
      );
    });
  }
}
