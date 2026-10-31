import 'dart:async';
import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:simple_live_tv_app/services/sync_room_service.dart';

class SyncController extends BaseController {
  /// 云端房间（跨网络中继）
  late final SyncRoomService cloudService;

  /// 内网直连房间（本机 loopback 作为创建者）
  late final SyncRoomService lanService;

  StreamSubscription? _cloudStateSub;
  StreamSubscription? _cloudMsgSub;
  StreamSubscription? _cloudDestroyedSub;
  StreamSubscription? _lanStateSub;
  StreamSubscription? _lanMsgSub;

  var cloudRoomId = "--".obs;
  var cloudState = SyncRoomConnectionState.connecting.obs;
  var lanState = SyncRoomConnectionState.connecting.obs;

  Timer? _timer;
  var countDown = 600.obs;

  @override
  void onInit() {
    cloudService = SyncRoomService(SyncRoomArgs.cloudHost());
    lanService = SyncRoomService(SyncRoomArgs.lanHost());
    connect();
    super.onInit();
  }

  void connect() async {
    _cloudStateSub = cloudService.stateStream.listen((state) {
      cloudState.value = state;
    });
    _cloudMsgSub = cloudService.messageStream.listen(_onMessage);
    _cloudDestroyedSub = cloudService.destroyedStream.listen((_) {
      SmartDialog.showToast("云端房间已被销毁");
      Get.back();
    });

    _lanStateSub = lanService.stateStream.listen((state) {
      lanState.value = state;
    });
    _lanMsgSub = lanService.messageStream.listen(_onMessage);

    try {
      await cloudService.start();
      cloudRoomId.value = cloudService.roomCode ?? "--";
      _startTimer();
    } catch (e) {
      Log.logPrint('cloud room failed: $e');
      if (e is SyncRoomException) {
        SmartDialog.showToast("云端房间创建失败：${e.message}");
      }
      cloudState.value = SyncRoomConnectionState.disconnected;
    }

    try {
      await lanService.start();
    } catch (e) {
      Log.logPrint('lan room failed: $e');
      lanState.value = SyncRoomConnectionState.disconnected;
    }
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

  void _onMessage(SyncRoomMessage message) {
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
      SmartDialog.showToast('已同步关注用户列表');
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

  @override
  void onClose() {
    _timer?.cancel();
    _cloudStateSub?.cancel();
    _cloudMsgSub?.cancel();
    _cloudDestroyedSub?.cancel();
    _lanStateSub?.cancel();
    _lanMsgSub?.cancel();
    cloudService.dispose();
    lanService.dispose();
    super.onClose();
  }
}
