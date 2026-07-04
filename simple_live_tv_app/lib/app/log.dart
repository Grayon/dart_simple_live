import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/utils.dart';

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static LogFileWriter? logFileWriter;

  /// 初始化日志文件写入器
  /// - 仅在用户开启「日志记录」时真正写文件，避免无谓 IO
  static void initWriter() {
    if (!AppSettingsController.instance.logEnable.value) return;
    try {
      logFileWriter = LogFileWriter();
    } catch (e) {
      if (kDebugMode) print('LogFileWriter init failed: $e');
    }
  }

  static void disposeWriter() {
    logFileWriter?.close();
    logFileWriter = null;
  }

  static String get _currentTime =>
      DateFormat('HH:mm:ss.SSS').format(DateTime.now());

  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  static void d(String message) {
    addDebugLog(message, Colors.orange);
    logger.d("${DateTime.now().toString()}\n$message");
    logFileWriter?.write("[DEBUG] $_currentTime：$message");
  }

  static void i(String message) {
    addDebugLog(message, Colors.blue);
    logger.i("${DateTime.now().toString()}\n$message");
    logFileWriter?.write("[INFO] $_currentTime：$message");
  }

  static void e(String message, StackTrace stackTrace) {
    addDebugLog('$message\r\n\r\n$stackTrace', Colors.red);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
    logFileWriter?.write("[ERROR] $_currentTime：$message\n$stackTrace");
  }

  static void w(String message) {
    addDebugLog(message, Colors.pink);
    logger.w("${DateTime.now().toString()}\n$message");
    logFileWriter?.write("[WARN] $_currentTime：$message");
  }

  static void logPrint(dynamic obj) {
    addDebugLog(obj.toString(), Colors.red);
    logFileWriter?.write("[PRINT] $_currentTime：$obj");
    if (kDebugMode) {
      print(obj);
    }
  }

  static void addDebugLog(String content, Color? color) {
    if (kReleaseMode) return;
    try {
      debugLogs.insert(0, DebugLogModel(DateTime.now(), content, color: color));
      // 防止内存日志无限增长
      if (debugLogs.length > 2000) {
        debugLogs.removeRange(2000, debugLogs.length);
      }
    } catch (e) {
      if (kDebugMode) print(e);
    }
  }
}

class LogFileWriter {
  late String fileName;
  IOSink? fileWriter;
  String? _logDirPath;

  LogFileWriter() {
    var dt = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    fileName = "$dt.log";
    initFile();
  }

  void initFile() async {
    try {
      var supportDir = await getApplicationSupportDirectory();
      var logDir = Directory("${supportDir.path}/log");
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      _logDirPath = logDir.path;
      var logFile = File("${logDir.path}/$fileName");
      fileWriter = logFile.openWrite(mode: FileMode.append);
      writeSystemInfo();
    } catch (e) {
      if (kDebugMode) print('LogFileWriter initFile failed: $e');
    }
  }

  void write(String content) {
    fileWriter?.write(content);
    fileWriter?.write("\r\n");
  }

  Future close() async {
    await fileWriter?.flush();
    await fileWriter?.close();
    fileWriter = null;
  }

  /// 列出当前日志目录下所有 .log 文件（路径、大小、修改时间）
  static Future<List<LogFileModel>> listFiles() async {
    try {
      var supportDir = await getApplicationSupportDirectory();
      var logDir = Directory("${supportDir.path}/log");
      if (!await logDir.exists()) return [];
      var files = <LogFileModel>[];
      await for (var entity in logDir.list()) {
        if (entity is File && entity.path.endsWith('.log')) {
          var stat = await entity.stat();
          files.add(LogFileModel(
            name: entity.uri.pathSegments.last,
            path: entity.path,
            time: stat.modified,
            size: stat.size,
          ));
        }
      }
      files.sort((a, b) => b.time.compareTo(a.time));
      return files;
    } catch (e) {
      return [];
    }
  }
}

class LogFileModel {
  final String name;
  final String path;
  final DateTime time;
  final int size;
  LogFileModel({
    required this.name,
    required this.path,
    required this.time,
    required this.size,
  });
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
