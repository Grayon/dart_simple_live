import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:udp/udp.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

class SyncService extends GetxService {
  static SyncService get instance => Get.find<SyncService>();

  UDP? udp;
  static const int udpPort = 23235;
  static const int httpPort = 23234;
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  NetworkInfo networkInfo = NetworkInfo();
  HttpServer? server;

  var ipAddress = "".obs;
  var httpRunning = false.obs;
  var httpErrorMsg = "".obs;
  Timer? _ipRefreshTimer;

  var deviceId = "";
  @override
  void onInit() {
    Log.d('SyncService init');
    deviceId = (const Uuid().v4()).split('-').first;
    listenUDP();
    initServer();
    super.onInit();
  }

  /// 监听来自其他客户端的UDP广播
  /// - 如果收到广播，回复自己的信息
  void listenUDP() async {
    udp = await UDP.bind(Endpoint.any(port: const Port(udpPort)));
    udp!.asStream().listen((datagram) {
      var str = String.fromCharCodes(datagram!.data);
      Log.i("Received: $str from ${datagram.address}:${datagram.port}");
      if (str.startsWith('{') && str.endsWith('}')) {
        var data = json.decode(str);

        //处理Hello的广播
        if (data["type"] == "hello") {
          //如果http服务已经启动，就回复自己的信息
          if (httpRunning.value) {
            sendInfo();
          }
          return;
        }
      } else if (str == 'Who is SimpleLive?') {
        //如果http服务已经启动，就回复自己的信息
        if (httpRunning.value) {
          sendInfo();
        }
      }
    });
  }

  /// 发送自己的信息
  void sendInfo() async {
    //var ip = await getLocalIP();

    var name = await getDeviceName();

    var data = {
      "id": deviceId,
      "type": "tv",
      "name": name,
      //"address": ip,
      //"port": httpPort,
    };

    await udp!.send(
      json.encode(data).codeUnits,
      Endpoint.broadcast(
        port: const Port(udpPort),
      ),
    );
    Log.i("send udp info: $data");
  }

  /// 读取本地IP
  /// - 方案1: TCP connect 到外部地址，让 OS 选择出口网卡，读取本地地址（最可靠）
  /// - 方案2: 枚举 NetworkInterface，按 Ethernet > WiFi > 其他优先级取
  /// - 方案3: network_info_plus getWifiIP() 兜底（仅 WiFi 有效）
  /// - 只返回单个 IP，避免多接口时拼接产生无效 URL
  Future<String> getLocalIP() async {
    // 方案1: 通过 TCP connect 发现出口 IP
    // OS 路由决定走哪张网卡，socket.address 即为该网卡的本地地址
    try {
      var socket = await Socket.connect(
        '8.8.8.8',
        53,
        timeout: const Duration(seconds: 3),
      );
      var localIp = socket.address.address;
      socket.destroy();
      if (localIp.isNotEmpty &&
          !localIp.startsWith('127') &&
          localIp != '0.0.0.0') {
        Log.d('getLocalIP via TCP connect: $localIp');
        return localIp;
      }
    } catch (e) {
      Log.d('getLocalIP via TCP connect failed: $e');
    }

    // 方案2: 枚举网络接口
    var interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    );
    String? ethernetIp;
    String? wifiIp;
    String? firstIp;

    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        if (addr.isLoopback ||
            addr.isMulticast ||
            addr.isLinkLocal ||
            addr.address.startsWith('127')) {
          continue;
        }
        firstIp ??= addr.address;
        var name = interface.name.toLowerCase();
        if (name.startsWith('eth') ||
            (!name.startsWith('wlan') && name.contains('ethernet'))) {
          ethernetIp ??= addr.address;
        } else if (name.startsWith('wlan')) {
          wifiIp ??= addr.address;
        }
      }
    }

    // 方案3: network_info_plus 获取 WiFi IP（仅 WiFi 连接时有效）
    if (wifiIp == null && ethernetIp == null) {
      try {
        var wifiIp2 = await networkInfo.getWifiIP();
        if (wifiIp2 != null && wifiIp2.isNotEmpty && !wifiIp2.startsWith('127')) {
          Log.d('getLocalIP via network_info_plus: $wifiIp2');
          return wifiIp2;
        }
      } catch (_) {}
    }

    var result = ethernetIp ?? wifiIp ?? firstIp ?? '';
    Log.d('getLocalIP result: $result (found ${interfaces.length} interfaces)');
    return result;
  }

  Future<String> getDeviceName() async {
    var name = "SimpleLive-TV";
    if (Platform.isAndroid) {
      var info = await deviceInfo.androidInfo;
      name = info.model;
    } else if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      name = info.name;
    } else if (Platform.isMacOS) {
      var info = await deviceInfo.macOsInfo;
      name = info.computerName;
    } else if (Platform.isLinux) {
      var info = await deviceInfo.linuxInfo;
      name = info.name;
    } else if (Platform.isWindows) {
      var info = await deviceInfo.windowsInfo;
      name = info.userName;
    }
    return name;
  }

  /// 初始化HTTP服务
  void initServer() async {
    try {
      var serverRouter = Router();
      serverRouter.get('/', _helloRequest);
      serverRouter.get('/info', _infoRequest);
      serverRouter.get('/log', _logListRequest);
      serverRouter.get('/log/<name>', _logFileRequest);
      serverRouter.post('/sync/follow', _syncFollowUserReuqest);
      serverRouter.post('/sync/history', _syncHistoryReuqest);
      serverRouter.post('/sync/blocked_word', _syncBlockedWordReuqest);
      serverRouter.post('/sync/account/bilibili', _syncBiliAccountReuqest);

      var server = await shelf_io.serve(
        serverRouter,
        InternetAddress.anyIPv4,
        httpPort,
      );

      // Enable content compression
      server.autoCompress = true;

      httpRunning.value = true;

      var ip = await getLocalIP();
      ipAddress.value = ip;

      // IP 刷新：为空时每 5s 重试，获取到后每 30s 刷新应对网络切换
      _ipRefreshTimer?.cancel();
      _ipRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        var newIp = await getLocalIP();
        if (newIp.isNotEmpty && newIp != ipAddress.value) {
          ipAddress.value = newIp;
          Log.d('IP changed to $newIp');
          // 获取到 IP 后降频到 30s
          _ipRefreshTimer?.cancel();
          _ipRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
            var newIp2 = await getLocalIP();
            if (newIp2.isNotEmpty && newIp2 != ipAddress.value) {
              ipAddress.value = newIp2;
              Log.d('IP changed to $newIp2');
            }
          });
        }
      });

      Log.d('Serving at http://$ip:${server.port}');
    } catch (e) {
      httpErrorMsg.value = e.toString();
      Log.logPrint(e);
    }
  }

  /// 测试服务能否正常访问
  shelf.Response _helloRequest(shelf.Request request) {
    return toJsonResponse({
      'status': true,
      'message': 'http server is running...',
      "version":
          'SimpeLive ${Platform.operatingSystem} v${Utils.packageInfo.version}',
    });
  }

  /// 发送自己的信息
  Future<shelf.Response> _infoRequest(shelf.Request request) async {
    var name = await getDeviceName();
    return toJsonResponse({
      "id": deviceId,
      'type': 'tv',
      'name': name,
      'version': Utils.packageInfo.version,
      'address': ipAddress.value,
      'port': httpPort,
    });
  }

  /// 列出所有日志文件（JSON）
  Future<shelf.Response> _logListRequest(shelf.Request request) async {
    var files = await LogFileWriter.listFiles();
    // 使用请求方实际连接的 host，避免 ipAddress 为空或多网卡时 URL 错误
    var host = request.requestedUri.host;
    var port = request.requestedUri.port;
    return toJsonResponse({
      'status': true,
      'logEnable': AppSettingsController.instance.logEnable.value,
      'ip': ipAddress.value,
      'files': files
          .map((f) => {
                'name': f.name,
                'size': f.size,
                'time': f.time.toIso8601String(),
                'url': 'http://$host:$port/log/${Uri.encodeComponent(f.name)}',
              })
          .toList(),
    });
  }

  /// 下载指定日志文件（纯文本）
  Future<shelf.Response> _logFileRequest(shelf.Request request, String name) async {
    name = Uri.decodeComponent(name);
    // 防止路径穿越
    if (name.contains('/') || name.contains('..') || !name.endsWith('.log')) {
      return shelf.Response(400, body: 'invalid name');
    }
    try {
      var files = await LogFileWriter.listFiles();
      var target = files.where((f) => f.name == name).toList();
      if (target.isEmpty) {
        return shelf.Response(404, body: 'log not found');
      }
      var file = File(target.first.path);
      var content = await file.readAsString();
      return shelf.Response.ok(
        content,
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Disposition': 'attachment; filename="$name"',
        },
      );
    } catch (e) {
      return shelf.Response(500, body: e.toString());
    }
  }

  /// 同步关注用户列表
  Future<shelf.Response> _syncFollowUserReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');

      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        await DBService.instance.followBox.clear();
      }
      for (var item in jsonBody) {
        var user = FollowUser.fromJson(item);
        await DBService.instance.followBox.put(user.id, user);
      }

      SmartDialog.showToast('已同步关注用户列表');
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步观看记录
  Future<shelf.Response> _syncHistoryReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncFollowUserReuqest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
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

      SmartDialog.showToast('已同步观看记录');
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步弹幕屏蔽词
  Future<shelf.Response> _syncBlockedWordReuqest(shelf.Request request) async {
    try {
      var overlay =
          int.parse(request.requestedUri.queryParameters['overlay'] ?? '0');
      var body = await request.readAsString();
      Log.d('_syncBlockedWordReuqest: $body');
      var jsonBody = json.decode(body);
      if (overlay == 1) {
        AppSettingsController.instance.clearShieldList();
      }
      for (var keyword in jsonBody) {
        AppSettingsController.instance.addShieldList(keyword.trim());
      }
      SmartDialog.showToast('已同步弹幕屏蔽词');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  /// 同步哔哩哔哩账号
  Future<shelf.Response> _syncBiliAccountReuqest(shelf.Request request) async {
    try {
      var body = await request.readAsString();
      Log.d('_syncBiliAccountReuqest: $body');
      var jsonBody = json.decode(body);
      var cookie = jsonBody['cookie'];
      BiliBiliAccountService.instance.setCookie(cookie);
      BiliBiliAccountService.instance.loadUserInfo();
      SmartDialog.showToast('已同步哔哩哔哩账号');
      return toJsonResponse({
        'status': true,
        'message': 'success',
      });
    } catch (e) {
      return toJsonResponse({
        'status': false,
        'message': e.toString(),
      });
    }
  }

  shelf.Response toJsonResponse(Map<String, dynamic> data) {
    return shelf.Response.ok(
      json.encode(data),
      headers: {
        'Content-Type': 'application/json',
      },
      encoding: Encoding.getByName('utf-8'),
    );
  }

  @override
  void onClose() {
    Log.d('SyncService close');
    _ipRefreshTimer?.cancel();
    udp?.close();
    server?.close(force: true);
    super.onClose();
  }
}
