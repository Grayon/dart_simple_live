import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';

enum SyncRoomTransport { cloud, lan }

enum SyncRoomConnectionState { connecting, connected, disconnected }

/// 同步房间成员
class SyncRoomPeer {
  final String id;
  final String app;
  final String platform;
  final String version;
  final bool creator;

  SyncRoomPeer({
    required this.id,
    required this.app,
    required this.platform,
    required this.version,
    required this.creator,
  });

  factory SyncRoomPeer.fromJson(Map<String, dynamic> json) {
    return SyncRoomPeer(
      id: json['id']?.toString() ?? "",
      app: json['app']?.toString() ?? "",
      platform: json['platform']?.toString() ?? "",
      version: json['version']?.toString() ?? "",
      creator: json['creator'] == true,
    );
  }
}

/// 收到的转发消息
class SyncRoomMessage {
  /// 发送者短 ID
  final String from;

  /// favorite / history / shield_word / bili_account
  final String kind;
  final bool overlay;
  final String content;

  SyncRoomMessage({
    required this.from,
    required this.kind,
    required this.overlay,
    required this.content,
  });
}

class SyncRoomException implements Exception {
  final String message;
  SyncRoomException(this.message);
  @override
  String toString() => message;
}

/// 进入同步房间的参数
class SyncRoomArgs {
  final SyncRoomTransport transport;
  final bool isHost;

  /// 云端房间号（云端访客必填）
  final String? roomCode;

  /// 内网直连地址，如 192.168.1.10:23234（内网访客必填）
  final String? lanAddress;

  SyncRoomArgs({
    required this.transport,
    required this.isHost,
    this.roomCode,
    this.lanAddress,
  });

  factory SyncRoomArgs.cloudHost() =>
      SyncRoomArgs(transport: SyncRoomTransport.cloud, isHost: true);

  factory SyncRoomArgs.cloudGuest(String roomCode) => SyncRoomArgs(
        transport: SyncRoomTransport.cloud,
        isHost: false,
        roomCode: roomCode,
      );

  factory SyncRoomArgs.lanHost() =>
      SyncRoomArgs(transport: SyncRoomTransport.lan, isHost: true);

  factory SyncRoomArgs.lanGuest(String address) => SyncRoomArgs(
        transport: SyncRoomTransport.lan,
        isHost: false,
        lanAddress: address,
      );
}

/// 二维码/手动输入内容解析
class SyncScanCode {
  /// 能解析为新房间（云端房间号或 ws:// 内网地址）时返回参数，否则为 null
  /// （null 时调用方按旧版局域网 http:// 地址处理）
  static SyncRoomArgs? parseRoom(String raw) {
    final code = raw.trim();
    if (code.startsWith('ws://') || code.startsWith('wss://')) {
      final uri = Uri.tryParse(code);
      if (uri == null || uri.host.isEmpty) {
        return null;
      }
      final address =
          uri.hasPort ? '${uri.host}:${uri.port}' : '${uri.host}:${SyncRoomService.kLanPort}';
      return SyncRoomArgs.lanGuest(address);
    }
    final upper = code.toUpperCase();
    if (RegExp(r'^[A-Z0-9]{5}$').hasMatch(upper)) {
      return SyncRoomArgs.cloudGuest(upper);
    }
    return null;
  }
}

/// 自定义 WebSocket 同步房间客户端
///
/// 三种角色：
/// - 云端创建/加入：连接 Cloudflare Worker（见 sync_server/worker.mjs）
/// - 内网访客：直连同局域网设备 ws://<ip>:23234/ws
/// - 内网主机：本机以 loopback 连接内置的 [SyncRoomHub]，UI 与访客完全一致
class SyncRoomService {
  /// 云端中继地址（Cloudflare Worker，见 sync_server/worker.mjs），格式 wss://<域名>/ws
  static const String kCloudRelayUrl =
      'wss://simple-live-sync.any0host.workers.dev/ws';

  static const int kLanPort = 23234;
  static const String kAppName = 'Simple Live';

  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _pingInterval = Duration(seconds: 20);

  final SyncRoomArgs args;

  String? _roomCode;
  String? get roomCode => _roomCode;

  String? _selfId;
  String? get selfId => _selfId;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _pingTimer;
  bool _pongReceived = true;
  bool _handshakeDone = false;
  bool _disposed = false;

  int? _closeCode;
  String? _closeReason;

  Completer<void>? _handshake;

  final _stateController =
      StreamController<SyncRoomConnectionState>.broadcast();
  Stream<SyncRoomConnectionState> get stateStream => _stateController.stream;

  final _usersController = StreamController<List<SyncRoomPeer>>.broadcast();
  Stream<List<SyncRoomPeer>> get usersStream => _usersController.stream;

  final _messageController = StreamController<SyncRoomMessage>.broadcast();
  Stream<SyncRoomMessage> get messageStream => _messageController.stream;

  final _destroyedController = StreamController<void>.broadcast();
  Stream<void> get destroyedStream => _destroyedController.stream;

  SyncRoomService(this.args);

  static String generateRoomCode() {
    final random = Random.secure();
    return List.generate(
      5,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
  }

  /// 建立连接。云端创建房间时会自动换码重试（撞码返回 4003）。
  /// 握手失败（房间不存在/已满等）抛出 [SyncRoomException]。
  Future<void> start() async {
    if (args.transport == SyncRoomTransport.cloud && args.isHost) {
      // 客户端生成房间码，撞到已有房间就换一个，最多 8 次
      for (var i = 0; i < 8; i++) {
        _roomCode = generateRoomCode();
        final ok = await _attempt(_buildUri(_roomCode!, role: 'host'));
        if (ok) {
          _onConnected();
          return;
        }
        if (_closeCode != 4003) {
          throw SyncRoomException(closeMessage());
        }
        Log.d('room code collision, retry with a new code');
      }
      throw SyncRoomException('创建房间失败，请稍后重试');
    }

    final Uri uri;
    if (args.transport == SyncRoomTransport.cloud) {
      final code = args.roomCode!.toUpperCase();
      _roomCode = code;
      uri = _buildUri(code, role: 'guest');
    } else if (args.isHost) {
      // 内网主机：loopback 接入本进程的 hub
      uri = _buildLanUri('127.0.0.1', role: 'host');
    } else {
      var address = args.lanAddress!.trim();
      if (!address.contains(':')) {
        address = '$address:$kLanPort';
      }
      uri = _buildLanUri(address, role: 'guest');
    }

    final ok = await _attempt(uri);
    if (!ok) {
      throw SyncRoomException(closeMessage());
    }
    _onConnected();
  }

  Uri _buildUri(String roomCode, {required String role}) {
    final base = Uri.parse(kCloudRelayUrl);
    return base.replace(queryParameters: {
      'room': roomCode,
      'role': role,
      'app': kAppName,
      'platform': Platform.operatingSystem,
      'v': Utils.packageInfo.version,
    });
  }

  Uri _buildLanUri(String hostPort, {required String role}) {
    final sp = hostPort.split(':');
    return Uri(
      scheme: 'ws',
      host: sp[0],
      port: int.tryParse(sp.length > 1 ? sp[1] : '') ?? kLanPort,
      path: '/ws',
      queryParameters: {
        'role': role,
        'app': kAppName,
        'platform': Platform.operatingSystem,
        'v': Utils.packageInfo.version,
      },
    );
  }

  /// 尝试一次连接；ready 到达返回 true，ready 前断开返回 false。
  Future<bool> _attempt(Uri uri) async {
    _closeCode = null;
    _closeReason = null;
    _handshakeDone = false;
    _handshake = Completer<void>();

    Log.d('sync room connecting: $uri');
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _onData,
      onError: (e) {
        Log.logPrint(e);
        _finishClosed();
      },
      onDone: _onDone,
      cancelOnError: true,
    );

    try {
      await _handshake!.future;
      return true;
    } catch (_) {
      await _cleanupChannel();
      return false;
    }
  }

  void _onConnected() {
    if (_disposed) return;
    _stateController.add(SyncRoomConnectionState.connected);
    _pongReceived = true;
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _ping());
  }

  void _ping() {
    if (!_pongReceived) {
      // 上一个 ping 没回应，判定连接已断
      Log.d('sync room ping timeout');
      _channel?.sink.close(4000, 'ping timeout');
      return;
    }
    _pongReceived = false;
    _sendRaw(jsonMessage({'t': 'ping'}));
  }

  void _onData(dynamic event) {
    if (_disposed || event is! String) {
      return;
    }
    Map<String, dynamic> msg;
    try {
      msg = _decode(event);
    } catch (e) {
      return;
    }
    switch (msg['t']) {
      case 'ready':
        _selfId = msg['self']?.toString();
        if (msg['users'] is List) {
          _usersController.add(
            (msg['users'] as List)
                .map((e) => SyncRoomPeer.fromJson(
                    (e as Map).cast<String, dynamic>()))
                .toList(),
          );
        }
        if (!_handshakeDone) {
          _handshakeDone = true;
          _handshake?.complete();
        }
        break;
      case 'users':
        if (msg['users'] is List) {
          _usersController.add(
            (msg['users'] as List)
                .map((e) => SyncRoomPeer.fromJson(
                    (e as Map).cast<String, dynamic>()))
                .toList(),
          );
        }
        break;
      case 'recv':
        _messageController.add(
          SyncRoomMessage(
            from: msg['from']?.toString() ?? "",
            kind: msg['kind']?.toString() ?? "",
            overlay: msg['overlay'] == true,
            content: msg['content']?.toString() ?? "",
          ),
        );
        break;
      case 'pong':
        _pongReceived = true;
        break;
      case 'destroyed':
        _destroyedController.add(null);
        break;
    }
  }

  void _onDone() {
    if (_disposed) return;
    _closeCode = _channel?.closeCode ?? _closeCode;
    _closeReason = _channel?.closeReason ?? _closeReason;
    Log.d('sync room closed: $_closeCode $_closeReason');
    if (!_handshakeDone) {
      _handshakeDone = true;
      _handshake?.completeError(StateError('closed before ready'));
    } else {
      _stateController.add(SyncRoomConnectionState.disconnected);
    }
  }

  void _finishClosed() {
    if (!_handshakeDone) {
      _handshakeDone = true;
      _handshake?.completeError(StateError('connection error'));
    } else {
      _onDone();
    }
  }

  /// 发送业务数据（kind 见 SyncRoomMessage）
  Future<void> send({
    required String kind,
    required bool overlay,
    required String content,
  }) async {
    _sendRaw(jsonMessage({
      't': 'send',
      'kind': kind,
      'overlay': overlay,
      'content': content,
    }));
  }

  void _sendRaw(String raw) {
    try {
      _channel?.sink.add(raw);
    } catch (e) {
      Log.logPrint(e);
    }
  }

  String closeMessage() {
    switch (_closeCode) {
      case 4001:
        return '房间不存在或已关闭';
      case 4002:
        return '房间已满';
      case 4003:
        return '房间已存在';
      case 4005:
        return '房间已关闭';
      default:
        final reason = _closeReason;
        return reason != null && reason.isNotEmpty
            ? '连接失败：$reason'
            : '连接失败，请检查网络后重试';
    }
  }

  Future<void> _cleanupChannel() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _pingTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _stateController.close();
    _usersController.close();
    _messageController.close();
    _destroyedController.close();
  }

  // 单帧就是一条 JSON，无需 SignalR 的 0x1e 分隔符
  static Map<String, dynamic> _decode(String raw) =>
      (jsonDecode(raw) as Map).cast<String, dynamic>();

  static String jsonMessage(Map<String, dynamic> msg) => jsonEncode(msg);
}
