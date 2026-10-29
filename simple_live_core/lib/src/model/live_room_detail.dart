import 'dart:convert';

class LiveRoomDetail {
  /// 房间ID
  final String roomId;

  /// 房间标题
  final String title;

  /// 封面
  final String cover;

  /// 用户名
  final String userName;

  /// 头像
  final String userAvatar;

  /// 在线（平台公开指标：抖音为真实观看人次，其余平台为热度/人气值）
  final int online;

  /// 累计看过人数（平台公开的真实人次，目前 B 站 App 接口提供）
  final int? watchedCount;

  /// 贵宾/舰长在线数（真实人数，仅为实际观众的下限；斗鱼由弹幕推送，
  /// B 站为舰长数）
  final int? nobleCount;

  /// 介绍
  final String? introduction;

  /// 公告
  final String? notice;

  /// 状态
  final bool status;

  /// 附加信息
  final dynamic data;

  /// 弹幕附加信息
  final dynamic danmakuData;

  /// 是否录播
  final bool isRecord;

  /// 链接
  final String url;

  /// 显示时间
  final String? showTime;

  LiveRoomDetail({
    required this.roomId,
    required this.title,
    required this.cover,
    required this.userName,
    required this.userAvatar,
    required this.online,
    this.watchedCount,
    this.nobleCount,
    this.introduction,
    this.notice,
    required this.status,
    this.data,
    this.danmakuData,
    required this.url,
    this.isRecord = false,
    this.showTime,
  });

  @override
  String toString() {
    return json.encode({
      "roomId": roomId,
      "title": title,
      "cover": cover,
      "userName": userName,
      "userAvatar": userAvatar,
      "online": online,
      "watchedCount": watchedCount,
      "nobleCount": nobleCount,
      "introduction": introduction,
      "notice": notice,
      "status": status,
      "data": data.toString(),
      "danmakuData": danmakuData.toString(),
      "url": url,
      "isRecord": isRecord,
      "showTime": showTime,
    });
  }
}
