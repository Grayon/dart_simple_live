import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:simple_live_app/app/log.dart';

/// 内网直连房间主机
///
/// 挂载在现有 shelf 服务（端口 23234）的 `/ws` 路径，协议与云端 Worker 一致。
/// 创建者通过 loopback（127.0.0.1）接入，局域网内其他设备作为 guest 直连。
/// 创建者断开（离开房间页面）即销毁房间并踢掉所有访客。
class SyncRoomHub {
  static final SyncRoomHub instance = SyncRoomHub._();
  SyncRoomHub._();

  static const _roomTtl = Duration(minutes: 10);
  static const _maxMembers = 16;
  static const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  static const _maxContentLength = 1024 * 1024;

  final List<_LanConnection> _connections = [];
  Timer? _ttlTimer;

  void mount(Router router, {String path = '/ws'}) {
    router.get(path, (shelf.Request request) {
      // 每个请求新建 handler，把 shelf Request 带进回调（用于判断 loopback）
      final handler = webSocketHandler(
        (WebSocketChannel channel, String? protocol) =>
            _handle(channel, request),
      );
      return handler(request);
    });
  }

  Future<void> _handle(
    WebSocketChannel channel,
    shelf.Request request,
  ) async {
    final query = request.requestedUri.queryParameters;
    final role = query['role'];
    final app = query['app'] ?? '';
    final platform = query['platform'] ?? '';
    final version = query['v'] ?? '';

    final remoteAddress = _remoteAddress(request);
    final host = _connections.where((c) => c.isHost).toList();

    bool reject(int code, String reason) {
      channel.sink.close(code, reason);
      return false;
    }

    if (role != 'host' && role != 'guest') {
      reject(4004, 'invalid role');
      return;
    }
    if (role == 'host' && !remoteAddress.isLoopback) {
      // 只有本机 loopback 能当创建者，防止局域网内其他人抢占
      reject(4003, 'host only allowed from loopback');
      return;
    }
    if (role == 'host' && host.isNotEmpty) {
      reject(4003, 'room already exists');
      return;
    }
    if (role == 'guest' && host.isEmpty) {
      reject(4001, 'room not found');
      return;
    }
    if (_connections.length >= _maxMembers) {
      reject(4002, 'room is full');
      return;
    }

    final conn = _LanConnection(
      channel: channel,
      id: _randomId(),
      app: app,
      platform: platform,
      version: version,
      isHost: role == 'host',
    );
    _connections.add(conn);

    if (conn.isHost) {
      _ttlTimer?.cancel();
      _ttlTimer = Timer(_roomTtl, () => destroy('room expired'));
    }

    conn.send(jsonEncode({
      't': 'ready',
      'self': conn.id,
      'creator': conn.isHost,
      'users': _userList(),
    }));
    _broadcastUsers();

    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = channel.stream.listen(
      (data) {
        if (data is! String) {
          return;
        }
        Map<String, dynamic> msg;
        try {
          msg = (jsonDecode(data) as Map).cast<String, dynamic>();
        } catch (_) {
          return;
        }
        final type = msg['t'];
        if (type == 'ping') {
          conn.send(jsonEncode({'t': 'pong'}));
          return;
        }
        if (type != 'send') {
          return;
        }
        final kind = msg['kind'];
        final content = msg['content'];
        if (kind is! String ||
            kind.length > 40 ||
            content is! String ||
            content.length > _maxContentLength) {
          return;
        }
        final payload = jsonEncode({
          't': 'recv',
          'from': conn.id,
          'kind': kind,
          'overlay': msg['overlay'] == true,
          'content': content,
        });
        for (final other in _connections) {
          if (other != conn) {
            other.send(payload);
          }
        }
      },
      onDone: () {
        sub.cancel();
        _connections.remove(conn);
        if (conn.isHost) {
          destroy('room destroyed');
        } else {
          _broadcastUsers();
        }
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      onError: (e) {
        Log.logPrint('lan room connection error: $e');
      },
      cancelOnError: true,
    );

    // 保持连接处理函数不提前返回
    await completer.future;
  }

  /// 销毁房间：通知所有访客并断开
  void destroy([String reason = 'room destroyed']) {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    for (final conn in _connections) {
      conn.send(jsonEncode({'t': 'destroyed'}));
      conn.channel.sink.close(4005, reason);
    }
    _connections.clear();
  }

  void _broadcastUsers() {
    if (_connections.isEmpty) {
      return;
    }
    final payload = jsonEncode({'t': 'users', 'users': _userList()});
    for (final conn in _connections) {
      conn.send(payload);
    }
  }

  List<Map<String, dynamic>> _userList() {
    return _connections
        .map((c) => {
              'id': c.id,
              'app': c.app,
              'platform': c.platform,
              'version': c.version,
              'creator': c.isHost,
            })
        .toList();
  }

  InternetAddress _remoteAddress(shelf.Request request) {
    try {
      final info = request.context['shelf.io.connection_info'];
      // HttpConnectionInfo.remoteAddress
      final addr = (info as dynamic).remoteAddress as InternetAddress?;
      if (addr != null) {
        return addr;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    // 取不到地址时按非 loopback 处理（拒绝当 host）
    return InternetAddress('0.0.0.0');
  }

  String _randomId() {
    final random = Random.secure();
    return List.generate(
      4,
      (_) => _alphabet[random.nextInt(_alphabet.length)],
    ).join();
  }
}

class _LanConnection {
  final WebSocketChannel channel;
  final String id;
  final String app;
  final String platform;
  final String version;
  final bool isHost;

  _LanConnection({
    required this.channel,
    required this.id,
    required this.app,
    required this.platform,
    required this.version,
    required this.isHost,
  });

  void send(String raw) {
    try {
      channel.sink.add(raw);
    } catch (_) {}
  }
}
