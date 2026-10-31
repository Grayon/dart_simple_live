import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/sync_room_service.dart';
import 'package:simple_live_app/services/sync_service.dart';

class RemoteSyncRoomController extends BaseController {
  final SyncRoomArgs args;
  final SyncRoomService service;

  RemoteSyncRoomController(this.args) : service = SyncRoomService(args);

  StreamSubscription? _stateSubscription;
  StreamSubscription? _usersSubscription;
  StreamSubscription? _messageSubscription;
  StreamSubscription? _destroyedSubscription;
  Worker? _ipWorker;

  /// 房间号（云端）或内网地址
  var currentRoomId = "--".obs;

  /// 二维码内容：云端为 5 位房间号，内网为 ws:// 地址
  var qrData = "".obs;

  var roomUsers = <SyncRoomPeer>[].obs;

  var state = SyncRoomConnectionState.connecting.obs;

  Timer? _timer;
  var countDown = 600.obs;

  bool get isLan => args.transport == SyncRoomTransport.lan;
  bool get _isHost => args.isHost;

  @override
  void onInit() {
    connect();
    super.onInit();
  }

  void connect() async {
    _stateSubscription = service.stateStream.listen((event) {
      state.value = event;
    });
    _usersSubscription = service.usersStream.listen((users) {
      roomUsers.assignAll(users);
    });
    _messageSubscription = service.messageStream.listen((message) {
      switch (message.kind) {
        case 'favorite':
          onReceiveFavorite(message.overlay, message.content);
          break;
        case 'history':
          onReceiveHistory(message.overlay, message.content);
          break;
        case 'shield_word':
          onReceiveShieldWord(message.overlay, message.content);
          break;
        case 'bili_account':
          onReceiveBiliAccount(message.overlay, message.content);
          break;
      }
    });
    _destroyedSubscription = service.destroyedStream.listen((_) {
      SmartDialog.showToast("房间已被销毁");
      Get.back();
    });

    try {
      await service.start();
      _onConnected();
    } on SyncRoomException catch (e) {
      SmartDialog.showToast(e.message);
      Get.back();
    } catch (e) {
      SmartDialog.showToast("连接房间失败");
      Log.logPrint(e);
      Get.back();
    }
  }

  void _onConnected() {
    if (isLan) {
      if (_isHost) {
        // 内网主机：展示本机 IP，IP 刷新后同步更新
        _updateLanInfo();
        _ipWorker =
            ever(SyncService.instance.ipAddress, (_) => _updateLanInfo());
      } else {
        currentRoomId.value = args.lanAddress ?? "";
        qrData.value = 'ws://${args.lanAddress}/ws';
      }
    } else {
      currentRoomId.value = service.roomCode ?? "";
      qrData.value = service.roomCode ?? "";
    }
    _startTimer();
  }

  void _updateLanInfo() {
    var ip = SyncService.instance.ipAddress.value;
    var ips =
        ip.split(';').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (ips.isEmpty) {
      currentRoomId.value = "获取IP中...";
      qrData.value = "";
      return;
    }
    currentRoomId.value = '${ips.first}:${SyncRoomService.kLanPort}';
    qrData.value = ips
        .map((e) => 'ws://$e:${SyncRoomService.kLanPort}/ws')
        .join(';');
  }

  void _startTimer() {
    // 倒计时10分钟，自动关闭页面（与服务端 TTL 一致）
    countDown.value = 600;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      countDown--;
      if (countDown <= 0) {
        timer.cancel();
        Get.back();
      }
    });
  }

  void onReceiveFavorite(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        await DBService.instance.followBox.clear();
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }
      SmartDialog.showToast("已同步关注列表");
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveHistory(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        await DBService.instance.historyBox.clear();
      }
      for (var item in jsonBody) {
        var history = History.fromJson(item);
        if (DBService.instance.historyBox.containsKey(history.id)) {
          var old = DBService.instance.historyBox.get(history.id);
          //如果本地的更新时间比较新，就不更新
          if (old!.updateTime.isAfter(history.updateTime)) {
            continue;
          }
        }
        await DBService.instance.addOrUpdateHistory(history);
      }
      SmartDialog.showToast('已同步历史记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveShieldWord(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      if (overlay) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var item in jsonBody) {
        AppSettingsController.instance.addShieldList(item);
      }
      SmartDialog.showToast('已同步屏蔽词');
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  void onReceiveBiliAccount(bool overlay, String data) async {
    try {
      var jsonBody = json.decode(data);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
    } catch (e) {
      SmartDialog.showToast("同步失败:$e");
      Log.logPrint(e);
    }
  }

  Future<bool> showOverlayDialog() async {
    var overlay = await Utils.showAlertDialog(
      "是否覆盖远端数据？",
      title: "数据覆盖",
      confirm: "覆盖",
      cancel: "不覆盖",
    );
    return overlay;
  }

  bool get _hasOtherDevice =>
      roomUsers.any((u) => u.id != service.selfId);

  void syncFollow() async {
    await _send(
      kind: 'favorite',
      checkEmptyTip: "无设备连接",
      sendingTip: "发送中...",
      buildData: () {
        var users = DBService.instance.getFollowList();
        return json.encode(users.map((e) => e.toJson()).toList());
      },
      successTip: "已发送关注列表",
    );
  }

  void syncHistory() async {
    await _send(
      kind: 'history',
      checkEmptyTip: "无设备连接",
      sendingTip: "发送中...",
      buildData: () {
        var histores = DBService.instance.getHistores();
        return json.encode(histores.map((e) => e.toJson()).toList());
      },
      successTip: "已发送历史记录",
    );
  }

  void syncBlockedWord() async {
    await _send(
      kind: 'shield_word',
      checkEmptyTip: "无设备连接",
      sendingTip: "发送中...",
      buildData: () => json.encode(AppSettingsController.instance.shieldList.toList()),
      successTip: "已发送屏蔽词",
    );
  }

  void syncBiliAccount() async {
    if (!BiliBiliAccountService.instance.logined.value) {
      SmartDialog.showToast("未登录哔哩哔哩");
      return;
    }
    await _send(
      kind: 'bili_account',
      checkEmptyTip: "无设备连接",
      sendingTip: "发送中...",
      buildData: () => json.encode({
        "cookie": BiliBiliAccountService.instance.cookie,
      }),
      successTip: "已发送哔哩哔哩账号",
      alwaysOverlay: true,
    );
  }

  Future<void> _send({
    required String kind,
    required String checkEmptyTip,
    required String sendingTip,
    required String Function() buildData,
    required String successTip,
    bool alwaysOverlay = false,
  }) async {
    try {
      if (!_hasOtherDevice) {
        SmartDialog.showToast(checkEmptyTip);
        return;
      }
      final overlay =
          alwaysOverlay ? true : await showOverlayDialog();
      SmartDialog.showLoading(msg: sendingTip);
      await service.send(
        kind: kind,
        overlay: overlay,
        content: buildData(),
      );
      SmartDialog.showToast(successTip);
    } catch (e) {
      SmartDialog.showToast("发送失败:$e");
      Log.logPrint(e);
    } finally {
      SmartDialog.dismiss();
    }
  }

  void showQRInfo() {
    Utils.showBottomSheet(
      title: isLan ? "内网直连信息" : "房间信息",
      child: Column(
        children: [
          Obx(
            () => qrData.value.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  )
                : Column(
                    children: [
                      QrImageView(
                        data: qrData.value.split(';').first,
                        version: QrVersions.auto,
                        backgroundColor: Colors.white,
                        padding: AppStyle.edgeInsetsA12,
                        size: 200,
                      ),
                      AppStyle.vGap24,
                      Text(
                        currentRoomId.value,
                        textAlign: TextAlign.center,
                        style: Get.textTheme.titleLarge,
                      ),
                      Text(
                        isLan
                            ? "请确认两台设备处于同一局域网\n使用其他 Simple Live 客户端扫码直连"
                            : "请使用其他Simple Live客户端扫描上方二维码\n建立连接后可选择需要同步的数据",
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  @override
  void onClose() {
    _timer?.cancel();
    _stateSubscription?.cancel();
    _usersSubscription?.cancel();
    _messageSubscription?.cancel();
    _destroyedSubscription?.cancel();
    _ipWorker?.dispose();
    service.dispose();
    super.onClose();
  }
}
