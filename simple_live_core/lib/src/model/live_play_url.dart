import 'dart:convert';

class LivePlayUrl {
  /// 播放地址
  final List<String> urls;

  /// 请求头
  final Map<String, String>? headers;

  /// 原画 raw 线路在 [urls] 中的下标（原生原画或开关开启时合成的 raw 线路）
  final Set<int> rawIndexes;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.rawIndexes = const {},
  });

  @override
  String toString() {
    return json.encode({
      "urls": urls,
      "headers": headers.toString(),
      "rawIndexes": rawIndexes.toList(),
    });
  }
}
