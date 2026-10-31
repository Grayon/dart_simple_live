import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/sync_room_service.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class SyncPage extends StatelessWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("数据同步"),
        actions: [
          Visibility(
            visible: GetPlatform.isAndroid || GetPlatform.isIOS,
            child: TextButton.icon(
              onPressed: () async {
                var result = await Get.toNamed(RoutePath.kSyncScan);
                if (result == null || result.isEmpty) {
                  return;
                }
                _openByCode(result);
              },
              icon: const Icon(Remix.qr_scan_line),
              label: const Text("扫一扫"),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "同步房间",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("创建云端房间"),
                  leading: const Icon(Remix.cloud_line),
                  subtitle: const Text("通过云端中继，跨网络同步"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(
                      RoutePath.kRemoteSyncRoom,
                      arguments: SyncRoomArgs.cloudHost(),
                    );
                  },
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("创建内网直连房间"),
                  leading: const Icon(Remix.home_wifi_line),
                  subtitle: const Text("同一局域网内直连，不经过服务器"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(
                      RoutePath.kRemoteSyncRoom,
                      arguments: SyncRoomArgs.lanHost(),
                    );
                  },
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("加入云端房间"),
                  leading: const Icon(Remix.add_circle_line),
                  subtitle: const Text("输入其他设备的5位房间号"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _joinCloudRoom(),
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("加入内网直连房间"),
                  leading: const Icon(Remix.router_line),
                  subtitle: const Text("输入主机的局域网IP地址"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _joinLanRoom(),
                ),
                AppStyle.divider,
                ListTile(
                  title: const Text("WebDAV"),
                  leading: const Icon(Icons.cloud_upload_outlined),
                  subtitle: const Text("通过WebDAV同步数据"),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(RoutePath.kRemoteSyncWebDav);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "局域网同步（旧版HTTP）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  title: const Text("局域网同步"),
                  subtitle: const Text("与旧版客户端在局域网内同步数据"),
                  leading: const Icon(Remix.device_line),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Get.toNamed(RoutePath.kLocalSync);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 扫码结果分流：云端房间号 / ws 内网直连 / 旧版 http 局域网
  static void _openByCode(String code) {
    final args = SyncScanCode.parseRoom(code);
    if (args != null) {
      Get.toNamed(RoutePath.kRemoteSyncRoom, arguments: args);
    } else {
      Get.toNamed(RoutePath.kLocalSync, arguments: code);
    }
  }

  void _joinCloudRoom() async {
    var input = await Utils.showEditTextDialog(
      "",
      title: "加入云端房间",
      hintText: "请输入5位房间号,不区分大小写",
      validate: (text) {
        if (text.isEmpty) {
          SmartDialog.showToast("房间号不能为空");
          return false;
        }
        if (text.length != 5) {
          SmartDialog.showToast("请输入5位房间号");
          return false;
        }
        return true;
      },
    );
    if (input != null && input.isNotEmpty) {
      Get.toNamed(
        RoutePath.kRemoteSyncRoom,
        arguments: SyncRoomArgs.cloudGuest(input.toUpperCase()),
      );
    }
  }

  void _joinLanRoom() async {
    var input = await Utils.showEditTextDialog(
      "",
      title: "加入内网直连房间",
      hintText: "请输入主机IP，如 192.168.1.10",
      validate: (text) {
        if (text.isEmpty) {
          SmartDialog.showToast("地址不能为空");
          return false;
        }
        return true;
      },
    );
    if (input != null && input.isNotEmpty) {
      var address = input.trim();
      if (address.startsWith('ws://')) {
        final uri = Uri.tryParse(address);
        if (uri != null && uri.host.isNotEmpty) {
          address =
              uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
        }
      }
      Get.toNamed(
        RoutePath.kRemoteSyncRoom,
        arguments: SyncRoomArgs.lanGuest(address),
      );
    }
  }
}
