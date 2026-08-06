import 'dart:math';

/// 轻量 ID 生成器（组件包内置，不依赖宿主项目的 IdGenerator）
class IdGenerator {
  static final Random _random = Random();
  static int _counter = 0;

  /// 生成唯一 ID：时间戳 + 随机数 + 自增计数
  static String generate() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rand = _random.nextInt(0xFFFFFF).toRadixString(36);
    final seq = (_counter++).toRadixString(36);
    return 'pdf_ai_${ts}_$rand$seq';
  }
}
