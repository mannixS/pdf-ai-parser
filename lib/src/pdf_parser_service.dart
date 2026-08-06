import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Separation 专色/扩展色彩空间描述（[/Separation/Name base <</C0[...]/C1[...]>>]）
///
/// [c0]：浓度 n=0 时的基色值；[c1]：n=1 时的基色值
/// [baseType]：基色空间类型（0=Gray、1=RGB、2=CMYK、3=Lab）
class _SeparationSpace {
  final List<double> c0;
  final List<double> c1;
  final int baseType;
  const _SeparationSpace(this.c0, this.c1, this.baseType);
}

/// 图片色彩空间描述
///
/// [type]：0=Gray、1=RGB、2=CMYK、3=Indexed（索引查色表）
/// [samplesPerPixel]：每像素字节数（Indexed/Gray=1、RGB=3、CMYK=4）
/// [palette]：Indexed 查色表（每项为基色空间样本）
/// [baseType]：Indexed 的基色空间类型（0/1/2）
class _ImageColorSpace {
  final int type;
  final int samplesPerPixel;
  final List<List<int>> palette;
  final int baseType;
  const _ImageColorSpace(this.type, this.samplesPerPixel,
      {this.palette = const [], this.baseType = 1});
}

class PdfParserService {
  /// 将 PDF 文件的第一个页面解析成矢量 SVG 格式的字符串
  static String convertPdfToSvg(Uint8List pdfBytes) {
    // 默认的宽高（若 PDF 未指定 MediaBox/CropBox）
    double width = 800.0;
    double height = 600.0;

    // 1. 尝试从 PDF 数据中提取页面宽高（/MediaBox 或 /CropBox）
    final mediaBox = _extractMediaBox(pdfBytes);
    if (mediaBox != null) {
      width = mediaBox[2] - mediaBox[0];
      height = mediaBox[3] - mediaBox[1];
      if (width <= 0) width = 800.0;
      if (height <= 0) height = 600.0;
    }

    // 2. 提取所有的 stream 流数据对象并解压
    final contentStreams = _extractStreams(pdfBytes);

    // 3. 收集全部 ToUnicode CMap（CID → Unicode），用于解码 CID 字体文字
    final toUnicodeMap = _collectToUnicodeMaps(contentStreams);

    // 3.5 解析全部图片 XObject（/ImX），供 Do 操作嵌入 SVG
    final images = _extractImageXObjects(pdfBytes);

    // 3.6 解析页面资源中的扩展色彩空间（/CSx → Separation 专色等），
    // 供 `cs`/`scn` 颜色命令使用（AI 导出的黑色边框/条形码依赖此支持）
    final colorSpaces = _extractColorSpaces(pdfBytes);

    // 4. 将所有内容流的文本块拼接，再送入状态机翻译
    final sbText = StringBuffer();
    for (final streamText in contentStreams) {
      sbText.writeln(streamText);
    }

    return _translateContentStreamToSvg(
        sbText.toString(), width, height, toUnicodeMap, images, colorSpaces);
  }

  /// 解析 PDF 中所有图片 XObject（/ImX → PNG 字节）
  static Map<String, Uint8List> _extractImageXObjects(Uint8List pdfBytes) {
    final result = <String, Uint8List>{};
    final text = String.fromCharCodes(pdfBytes);
    final refReg = RegExp(r'/Im(\d+)\s+(\d+)\s+(\d+)\s+R');
    for (final m in refReg.allMatches(text)) {
      final name = 'Im${m.group(1)}';
      if (result.containsKey(name)) continue;
      final objNum = int.parse(m.group(2)!);
      final png = _extractAndDecodeImage(pdfBytes, objNum);
      if (png != null) result[name] = png;
    }
    return result;
  }

  /// 解析 PDF 页面资源中的 ColorSpace 定义（/CS0 /CS1 /CS2 → Separation 专色等）。
  ///
  /// AI 导出的 PDF 常用 `/CS2 cs 1 scn`（Separation/All）绘制黑色边框，
  /// 以及 `/CS0 cs 1 scn`（PANTONE Neutral Black）绘制条形码。
  static Map<String, _SeparationSpace> _extractColorSpaces(Uint8List pdfBytes) {
    final result = <String, _SeparationSpace>{};
    final text = String.fromCharCodes(pdfBytes);
    // 先提取 /ColorSpace<</CS0 12 0 R/CS1 13 0 R/CS2 14 0 R>> 字典，
    // 再遍历其中所有 /CSx 引用（allMatches 对嵌套写法不可靠，须分段匹配）
    final csDicts = RegExp(r'/ColorSpace\s*<<(.*?)>>', dotAll: true)
        .allMatches(text)
        .toList();
    final refs = <String, int>{};
    for (final cd in csDicts) {
      final dictBody = cd.group(1)!;
      for (final m in RegExp(r'/CS(\d+)\s+(\d+)\s+\d+\s+R').allMatches(dictBody)) {
        refs['CS${m.group(1)}'] = int.parse(m.group(2)!);
      }
    }
    for (final entry in refs.entries) {
      final csName = entry.key;
      final objNum = entry.value;
      final body = _readObjBody(pdfBytes, objNum);
      if (body == null) {
        continue;
      }
      // [/Separation/Name<base><</C0[ ... ]/C1[ ... ]/...>>]
      // 名称与基色之间用 / 分隔且无空格；base 可能为单个名字（/DeviceCMYK）
      // 或间接引用（如 PANTONE 的 35 0 R，无 / 前缀），因此用非贪婪 (.+?) 匹配到 << 为止
      final sep = RegExp(
              r'\[/Separation\s*/([^/\s]+)\s*/?(.+?)<</C0\[([^\]]+)\]/C1\[([^\]]+)\]',
              dotAll: true)
          .firstMatch(body);
      if (sep == null) continue;
      final baseRef = sep.group(2)!;
      final c0 = sep
          .group(3)!
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .map(double.parse)
          .toList();
      final c1 = sep
          .group(4)!
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .map(double.parse)
          .toList();
      int baseType;
      if (baseRef.contains('CMYK')) {
        baseType = 2;
      } else if (baseRef.contains('RGB')) {
        baseType = 1;
      } else if (baseRef.contains('Lab')) {
        baseType = 3;
      } else {
        // 间接引用（如 PANTONE 的 CIELab 35 0 R）
        final refObj = int.tryParse(baseRef.split(' ').first);
        if (refObj != null) {
          final baseBody = _readObjBody(pdfBytes, refObj);
          if (baseBody != null && baseBody.contains('Lab')) {
            baseType = 3;
          } else {
            baseType = 0;
          }
        } else {
          baseType = 0;
        }
      }
      result[csName] = _SeparationSpace(c0, c1, baseType);
    }
    return result;
  }

  /// Separation 浓度 n → RGB 颜色
  static String _hexFromSeparation(_SeparationSpace sp, double n) {
    final vals = <double>[
      for (int i = 0; i < sp.c0.length; i++)
        sp.c0[i] + (sp.c1[i] - sp.c0[i]) * n,
    ];
    if (sp.baseType == 2 && vals.length >= 4) {
      // DeviceCMYK 基色
      return _rgbToHex(_cmykToRgb(vals[0], vals[1], vals[2], vals[3]));
    } else if (sp.baseType == 3 && vals.length >= 3) {
      // CIELab 基色（PANTONE 专色等）
      return _rgbToHex(_labToRgb(vals[0], vals[1], vals[2]));
    } else if (sp.baseType == 1 && vals.length >= 3) {
      return _rgbToHex([
        (vals[0] * 255).round().clamp(0, 255),
        (vals[1] * 255).round().clamp(0, 255),
        (vals[2] * 255).round().clamp(0, 255),
      ]);
    }
    final v = (vals.isEmpty ? 0 : vals[0] * 255).round().clamp(0, 255);
    return _rgbToHex([v, v, v]);
  }

  /// CIELab → RGB（D65 白点），用于 PANTONE 等 Lab 基色的专色转换
  static List<int> _labToRgb(double l, double a, double b) {
    double fInv(double t) =>
        t > 0.206893 ? t * t * t : (t - 16 / 116) / 7.787;
    final fy = (l + 16) / 116;
    final fx = fy + a / 500;
    final fz = fy - b / 200;
    final x = 0.95047 * fInv(fx);
    final y = 1.0 * fInv(fy);
    final z = 1.08883 * fInv(fz);
    double rl = x * 3.2406 + y * -1.5372 + z * -0.4986;
    double gl = x * -0.9689 + y * 1.8758 + z * 0.0415;
    double bl = x * 0.0557 + y * -0.2040 + z * 1.0570;
    double gamma(double c) =>
        c > 0.0031308 ? 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055 : 12.92 * c;
    return [
      (gamma(rl) * 255).round().clamp(0, 255),
      (gamma(gl) * 255).round().clamp(0, 255),
      (gamma(bl) * 255).round().clamp(0, 255),
    ];
  }

  /// 提取单个图片对象（字典 + 流），解码为 PNG 字节。
  ///
  /// 支持色彩空间：DeviceGray / DeviceRGB / DeviceCMYK / Indexed
  /// （含间接引用与查色表，如 AI 导出的双色二维码 /Im1 /Im2）。
  static Uint8List? _extractAndDecodeImage(Uint8List pdfBytes, int objNum) {
    try {
      final body = _readObjBody(pdfBytes, objNum);
      if (body == null) return null;
      // 跳过非图片对象（字典可能无空格：/Subtype/Image）
      if (!RegExp(r'/Subtype\s*/Image').hasMatch(body)) return null;

      final width = _getDictInt(body, 'Width');
      final height = _getDictInt(body, 'Height');
      if (width == null || height == null || width <= 0 || height <= 0) {
        return null;
      }
      final bpc = _getDictInt(body, 'BitsPerComponent') ?? 8;
      if (bpc != 8 && bpc != 1) return null;

      // 解析色彩空间（直接名 / 间接引用 / Indexed 查色表）
      final cs = _resolveColorSpace(pdfBytes, body);

      // Filter 名可能带前导斜杠（/FlateDecode）
      final filter = (_getDictName(body, 'Filter') ?? '').replaceAll('/', '');
      final streamBytes = _extractStreamBytes(body);
      if (streamBytes == null) return null;

      List<int> pixels;
      if (filter.isEmpty || filter == 'FlateDecode') {
        try {
          pixels = ZLibDecoder().convert(streamBytes);
        } catch (_) {
          return null;
        }
      } else if (filter == 'DCTDecode') {
        // JPEG 已是完整图片，可直接嵌入
        return streamBytes;
      } else {
        return null;
      }

      // 期望长度校验（Indexed/Gray=1 字节/像素；RGB=3；CMYK=4）
      final expectedLen = width * height * cs.samplesPerPixel;
      if (pixels.length < expectedLen) return null;

      final rgba = _pixelsToRgba(pixels, width, height, cs);
      return _encodePng(width, height, rgba);
    } catch (_) {
      return null;
    }
  }

  /// 读取指定对象的原始内容（字典 + 流）
  static String? _readObjBody(Uint8List pdfBytes, int objNum) {
    final text = String.fromCharCodes(pdfBytes);
    final m = RegExp('$objNum\\s+\\d+\\s+obj(.*?)(?:endobj|%%EOF)',
            dotAll: true)
        .firstMatch(text);
    return m?.group(1);
  }

  /// 提取对象体内的 stream 数据字节（不含 stream 关键字与 endstream）
  static Uint8List? _extractStreamBytes(String body) {
    final m = RegExp(r'stream\r?\n(.*?)endstream', dotAll: true).firstMatch(body);
    if (m == null) return null;
    return Uint8List.fromList(m.group(1)!.codeUnits);
  }

  /// 解析图片色彩空间：支持直接名、间接引用（含 Indexed 查色表）
  static _ImageColorSpace _resolveColorSpace(Uint8List pdfBytes, String body) {
    // 1) 直接名 /ColorSpace/DeviceCMYK 或 /ColorSpace /DeviceRGB
    final direct = RegExp(r'/ColorSpace\s*/(\w+)').firstMatch(body);
    if (direct != null) {
      final name = direct.group(1)!;
      if (name == 'DeviceGray' || name == 'CalGray') {
        return const _ImageColorSpace(0, 1);
      }
      if (name == 'DeviceCMYK') return const _ImageColorSpace(2, 4);
      if (name == 'DeviceRGB' || name == 'CalRGB') {
        return const _ImageColorSpace(1, 3);
      }
    }
    // 2) 间接引用 /ColorSpace 13 0 R
    final ind = RegExp(r'/ColorSpace\s+(\d+)\s+\d+\s+R').firstMatch(body);
    if (ind != null) {
      final refBody = _readObjBody(pdfBytes, int.parse(ind.group(1)!));
      if (refBody != null) {
        // Indexed: [/Indexed/Base hival N 0 R]（查色表在 N 0 R）
        final indexed =
            RegExp(r'\[/Indexed\s*/(\w+)\s+(\d+)\s+(\d+)\s+\d+\s+R\]')
                .firstMatch(refBody);
        if (indexed != null) {
          final baseName = indexed.group(1)!;
          final hival = int.parse(indexed.group(2)!);
          final tableObj = int.parse(indexed.group(3)!);
          final baseType =
              baseName.contains('CMYK') ? 2 : (baseName.contains('Gray') ? 0 : 1);
          final baseSamples = baseType == 2 ? 4 : (baseType == 0 ? 1 : 3);
          final palette =
              _readLookupTable(pdfBytes, tableObj, hival + 1, baseSamples);
          return _ImageColorSpace(3, 1, palette: palette, baseType: baseType);
        }
        // 其他间接引用：直接名
        if (refBody.contains('/DeviceCMYK')) return const _ImageColorSpace(2, 4);
        if (refBody.contains('/DeviceGray')) return const _ImageColorSpace(0, 1);
        if (refBody.contains('/DeviceRGB')) return const _ImageColorSpace(1, 3);
      }
    }
    return const _ImageColorSpace(1, 3); // 默认 RGB
  }

  /// 读取 Indexed 查色表（对象内 stream，可能无压缩）
  static List<List<int>> _readLookupTable(
      Uint8List pdfBytes, int objNum, int count, int samples) {
    final body = _readObjBody(pdfBytes, objNum);
    if (body == null) return [];
    final bytes = _extractStreamBytes(body);
    if (bytes == null) return [];
    var data = bytes;
    final filter = (_getDictName(body, 'Filter') ?? '').replaceAll('/', '');
    if (filter == 'FlateDecode') {
      try {
        data = Uint8List.fromList(ZLibDecoder().convert(bytes));
      } catch (_) {
        return [];
      }
    }
    // 去掉末尾可能多捕获的换行
    while (data.isNotEmpty && (data.last == 0x0A || data.last == 0x0D)) {
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    final entries = <List<int>>[];
    for (int i = 0; i + samples <= data.length && entries.length < count;
        i += samples) {
      entries.add(data.sublist(i, i + samples));
    }
    return entries;
  }

  /// 像素数据 → RGBA（按色彩空间；Indexed 需查色表）
  static List<int> _pixelsToRgba(
      List<int> px, int width, int height, _ImageColorSpace cs) {
    final rgba = List<int>.filled(width * height * 4, 255);
    final n = width * height;
    if (cs.type == 3) {
      // Indexed：每像素 1 字节索引 → 查色表 → 基色空间转 RGBA
      for (int i = 0; i < n; i++) {
        final idx = px[i];
        if (idx < cs.palette.length) {
          _sampleToRgba(rgba, i * 4, cs.palette[idx], cs.baseType);
        }
      }
      return rgba;
    }
    final samples = cs.samplesPerPixel;
    for (int i = 0; i < n; i++) {
      final base = i * samples;
      final o = i * 4;
      if (cs.type == 1) {
        rgba[o] = px[base];
        rgba[o + 1] = px[base + 1];
        rgba[o + 2] = px[base + 2];
      } else if (cs.type == 2) {
        _sampleToRgba(rgba, o, px.sublist(base, base + 4), 2);
      } else {
        rgba[o] = px[base];
        rgba[o + 1] = px[base];
        rgba[o + 2] = px[base];
      }
    }
    return rgba;
  }

  /// 将基色空间样本写入 RGBA（CMYK 用 _cmykToRgb 校正，Gray 三通道相同）
  static void _sampleToRgba(
      List<int> rgba, int o, List<int> sample, int baseType) {
    if (baseType == 2 && sample.length >= 4) {
      final rgb = _cmykToRgb(sample[0] / 255.0, sample[1] / 255.0,
          sample[2] / 255.0, sample[3] / 255.0);
      rgba[o] = rgb[0];
      rgba[o + 1] = rgb[1];
      rgba[o + 2] = rgb[2];
    } else if (baseType == 1 && sample.length >= 3) {
      rgba[o] = sample[0];
      rgba[o + 1] = sample[1];
      rgba[o + 2] = sample[2];
    } else if (sample.isNotEmpty) {
      rgba[o] = sample[0];
      rgba[o + 1] = sample[0];
      rgba[o + 2] = sample[0];
    }
  }

  /// 手动编码 PNG（RGBA，8bit）
  static Uint8List _encodePng(int width, int height, List<int> rgba) {
    final out = BytesBuilder();
    out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 6) // RGBA
      ..setUint8(10, 0)
      ..setUint8(11, 0)
      ..setUint8(12, 0);
    _writePngChunk(out, 'IHDR', ihdr.buffer.asUint8List());

    final rawLen = width * 4 + 1;
    final rawData = Uint8List(rawLen * height);
    for (int y = 0; y < height; y++) {
      rawData[y * rawLen] = 0;
      for (int x = 0; x < width * 4; x++) {
        rawData[y * rawLen + 1 + x] = rgba[y * width * 4 + x];
      }
    }
    final idat = ZLibEncoder().convert(rawData);
    _writePngChunk(out, 'IDAT', idat);
    _writePngChunk(out, 'IEND', Uint8List(0));
    return out.toBytes();
  }

  static void _writePngChunk(BytesBuilder out, String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    out.add(type.codeUnits);
    out.add(data);
    var crc = 0xFFFFFFFF;
    for (final b in [...type.codeUnits, ...data]) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
      }
    }
    crc ^= 0xFFFFFFFF;
    final crcData = ByteData(4)..setUint32(0, crc);
    out.add(crcData.buffer.asUint8List());
  }

  /// 从对象字典提取整数属性（字典可能无空格分隔）
  static int? _getDictInt(String body, String key) {
    final m = RegExp('/$key\\s+(\\d+)').firstMatch(body);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 从对象字典提取名称属性（兼容 `/ColorSpace/DeviceCMYK` 无空格、
  /// `/ColorSpace /DeviceRGB` 带空格、以及数组 `[/DeviceRGB]`）
  static String? _getDictName(String body, String key) {
    // 带空格形式
    final m = RegExp('/$key\\s+(/\\S+)').firstMatch(body);
    if (m != null) {
      final name = m.group(1)!.trim();
      // 数组形式 /ColorSpace [/DeviceRGB ...]
      if (name.startsWith('[')) {
        final arr = RegExp(r'\[/\w+').firstMatch(name);
        return arr == null ? null : arr.group(0)!.substring(1);
      }
      return name;
    }
    // 无空格形式 /ColorSpace/DeviceCMYK
    final compact = RegExp('/$key/([\\w]+)').firstMatch(body);
    return compact == null ? null : '/${compact.group(1)}';
  }

  /// 从已解压的内容流中收集全部 ToUnicode CMap，建立 CID → Unicode 映射
  static Map<int, int> _collectToUnicodeMaps(List<String> contentStreams) {
    final map = <int, int>{};
    for (final stream in contentStreams) {
      // 只处理包含 CMap 关键字的流，避免重复解析普通内容流
      if (!stream.contains('beginbfchar') && !stream.contains('beginbfrange')) {
        continue;
      }
      _parseCMap(stream, map);
    }
    return map;
  }

  /// 解析单个 ToUnicode CMap 文本（bfchar / bfrange）写入映射表
  static void _parseCMap(String cmap, Map<int, int> map) {
    // bfchar：单字符映射 <src> <dst>
    final charReg = RegExp(r'beginbfchar(.*?)endbfchar', caseSensitive: false, dotAll: true);
    for (final m in charReg.allMatches(cmap)) {
      for (final p in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>').allMatches(m.group(1)!)) {
        final src = int.parse(p.group(1)!, radix: 16);
        map[src] = _hexToCodePoint(p.group(2)!);
      }
    }
    // bfrange：连续范围 <lo> <hi> <dst>（dst 递增）或 <lo> <hi> [<d1> <d2> ...]
    final rangeReg = RegExp(r'beginbfrange(.*?)endbfrange', caseSensitive: false, dotAll: true);
    for (final m in rangeReg.allMatches(cmap)) {
      final body = m.group(1)!;
      // 递增形式
      for (final r in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>').allMatches(body)) {
        final lo = int.parse(r.group(1)!, radix: 16);
        final hi = int.parse(r.group(2)!, radix: 16);
        final base = _hexToCodePoint(r.group(3)!);
        if (hi - lo < 0x10000) {
          for (int i = 0; i <= hi - lo; i++) {
            map[lo + i] = base + i;
          }
        }
      }
      // 数组形式
      for (final r in RegExp(r'<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[([^\]]*)\]').allMatches(body)) {
        final lo = int.parse(r.group(1)!, radix: 16);
        final hi = int.parse(r.group(2)!, radix: 16);
        final dsts = RegExp(r'<([0-9A-Fa-f]+)>')
            .allMatches(r.group(3)!)
            .map((e) => _hexToCodePoint(e.group(1)!))
            .toList();
        for (int i = 0; i <= hi - lo && i < dsts.length; i++) {
          map[lo + i] = dsts[i];
        }
      }
    }
  }

  /// 将 CMap 中的十六进制目标转换为单个 Unicode 码点
  static int _hexToCodePoint(String hex) {
    final len = hex.length;
    if (len <= 4) return int.parse(hex, radix: 16);
    if (len == 8) {
      final hi = int.parse(hex.substring(0, 4), radix: 16);
      final lo = int.parse(hex.substring(4), radix: 16);
      if (hi >= 0xD800 && hi <= 0xDBFF && lo >= 0xDC00 && lo <= 0xDFFF) {
        return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
      }
      return (hi << 16) | lo;
    }
    // 更长序列：按 UTF-16BE 代理对解析，取首个完整码点
    final pairs = <int>[];
    for (int i = 0; i + 4 <= len; i += 4) {
      pairs.add(int.parse(hex.substring(i, i + 4), radix: 16));
    }
    if (pairs.isEmpty) return 0xFFFD;
    if (pairs.length >= 2 &&
        pairs[0] >= 0xD800 && pairs[0] <= 0xDBFF &&
        pairs[1] >= 0xDC00 && pairs[1] <= 0xDFFF) {
      return 0x10000 + ((pairs[0] - 0xD800) << 10) + (pairs[1] - 0xDC00);
    }
    return pairs[0];
  }

  /// 解码十六进制 CID 字符串，用 ToUnicode 映射为 Unicode。
  ///
  /// Type0（CID）字体通常使用 **2 字节 CID**（4 个 hex 字符），优先按 2 字节
  /// 查表；查不到时回退 1 字节 CID（2 个 hex 字符）。无映射的可打印 ASCII 保留，
  /// 其余丢弃避免乱码。
  static String _decodeCidHex(String hexStr, Map<int, int> map) {
    final clean = hexStr.length.isOdd ? '0$hexStr' : hexStr;
    final sb = StringBuffer();
    int i = 0;
    while (i < clean.length) {
      // 优先尝试 2 字节 CID（Type0 字体字形索引）
      if (i + 4 <= clean.length) {
        final cid2 = int.parse(clean.substring(i, i + 4), radix: 16);
        final mapped = map[cid2];
        if (mapped != null) {
          sb.writeCharCode(mapped);
          i += 4;
          continue;
        }
      }
      // 回退 1 字节 CID
      if (i + 2 <= clean.length) {
        final cid1 = int.parse(clean.substring(i, i + 2), radix: 16);
        final mapped1 = map[cid1];
        if (mapped1 != null) {
          sb.writeCharCode(mapped1);
        } else if (cid1 >= 0x20 && cid1 < 0x7F) {
          sb.writeCharCode(cid1);
        }
      }
      i += 2;
    }
    return sb.toString();
  }

  /// 判断路径数据是否包含实际绘制命令（排除仅 M+Z 的零面积占位路径，
  /// 这类路径在 PDF/AI 打开时不可见，却会被渲染为 1×1px 的白色小方块）
  static bool _hasDrawCommand(String d) {
    return RegExp(r'[lchvqsta]', caseSensitive: false).hasMatch(d);
  }

  /// 将 SVG path d 数据中的 y 坐标垂直翻转（y' = pageHeight - y）。
  ///
  /// 用于 clipPath 内部路径：PDF 的裁剪路径坐标是 PDF 用户空间（y 向上），
  /// 而 flutter_svg 不允许 clipPath 内部有任何 transform，因此必须把翻转
  /// 预计算进坐标，使 clip 区域与根翻转 g（matrix(1 0 0 -1 0 H)）下的引用元素
  /// 处于同一屏幕坐标系。
  ///
  /// d 数据格式为 pdf_parser 输出的标准格式：
  /// `M x y L x y C x1 y1 x2 y2 x3 y3 Z`（空格分隔、坐标成对）。
  static String _flipPathY(String d, double pageHeight) {
    final tokens = d.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final buf = StringBuffer();
    int i = 0;
    while (i < tokens.length) {
      final cmd = tokens[i];
      buf.write('$cmd ');
      i++;
      switch (cmd) {
        case 'M':
        case 'L':
        case 'T':
          if (i + 1 < tokens.length) {
            final x = double.parse(tokens[i]);
            final y = double.parse(tokens[i + 1]);
            buf.write('${x.toStringAsFixed(3)} ${(pageHeight - y).toStringAsFixed(3)} ');
            i += 2;
          }
          break;
        case 'H':
          if (i < tokens.length) {
            buf.write('${double.parse(tokens[i]).toStringAsFixed(3)} ');
            i += 1;
          }
          break;
        case 'V':
          if (i < tokens.length) {
            buf.write('${(pageHeight - double.parse(tokens[i])).toStringAsFixed(3)} ');
            i += 1;
          }
          break;
        case 'C':
        case 'S':
        case 'Q':
          if (i + 5 < tokens.length) {
            // C/S/Q 各 6 个数字（3 对坐标），仅 y 翻转
            final x1 = double.parse(tokens[i]);
            final y1 = double.parse(tokens[i + 1]);
            final x2 = double.parse(tokens[i + 2]);
            final y2 = double.parse(tokens[i + 3]);
            final x3 = double.parse(tokens[i + 4]);
            final y3 = double.parse(tokens[i + 5]);
            buf.write('${x1.toStringAsFixed(3)} ${(pageHeight - y1).toStringAsFixed(3)} '
                '${x2.toStringAsFixed(3)} ${(pageHeight - y2).toStringAsFixed(3)} '
                '${x3.toStringAsFixed(3)} ${(pageHeight - y3).toStringAsFixed(3)} ');
            i += 6;
          }
          break;
        case 'Z':
        case 'z':
          // 无参数
          break;
        default:
          // 未知命令：跳过剩余 token，避免卡死
          i = tokens.length;
      }
    }
    return buf.toString().trim();
  }

  /// CMYK → RGB 转换，含灰平衡校正。
  ///
  /// 印刷设计常用"富黑"（Rich Black，如 C40/M30/Y30/K0）表示纯黑，
  /// 简单公式转换会得到偏青的灰蓝（如 #9aaeb7）。对近灰/富黑 CMYK
  /// 校正为纯灰，消除偏青/偏品红（用户反馈"灰色边框导入后偏青"）。
  static List<int> _cmykToRgb(double c, double m, double y, double k) {
    int r = (255 * (1.0 - c) * (1.0 - k)).round().clamp(0, 255);
    int g = (255 * (1.0 - m) * (1.0 - k)).round().clamp(0, 255);
    int b = (255 * (1.0 - y) * (1.0 - k)).round().clamp(0, 255);
    // 色偏较小（近灰/富黑）时校正为纯灰，取三通道最小值保留最暗分量
    final maxDiff = [r, g, b].reduce((a, b2) => a > b2 ? a : b2) -
        [r, g, b].reduce((a, b2) => a < b2 ? a : b2);
    if (maxDiff < 48) {
      final gray = [r, g, b].reduce((a, b2) => a < b2 ? a : b2);
      r = gray;
      g = gray;
      b = gray;
    }
    return [r, g, b];
  }

  /// RGB 三通道 → #rrggbb
  static String _rgbToHex(List<int> rgb) {
    final r = rgb[0];
    final g = rgb[1];
    final b = rgb[2];
    return '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
  }

  /// 解码括号文本：含 Latin-1 高字节（CID 字形字节）时用 ToUnicode 映射修正；
  /// 纯 ASCII 文本原样返回
  static String _decodeParenText(String raw, Map<int, int> map) {
    if (map.isEmpty) return raw;
    final allAscii = raw.codeUnits.every((c) => c >= 0x20 && c < 0x7F);
    if (allAscii) return raw;

    final sb = StringBuffer();
    for (final c in raw.codeUnits) {
      final mapped = map[c];
      if (mapped != null) {
        sb.writeCharCode(mapped);
      } else if (c >= 0x20 && c < 0x7F) {
        sb.writeCharCode(c);
      }
    }
    return sb.toString();
  }

  /// 寻找 PDF 文件头中的 MediaBox 以确定画布物理宽高 [x1, y1, x2, y2]
  static List<double>? _extractMediaBox(Uint8List bytes) {
    try {
      // MediaBox 可能位于 PDF 文件的任何位置（通常在 Pages 对象中），搜索整个文件
      final text = String.fromCharCodes(bytes);
      final reg = RegExp(r'/MediaBox\s*\[\s*([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]');
      final match = reg.firstMatch(text);
      if (match != null) {
        return [
          double.parse(match.group(1)!),
          double.parse(match.group(2)!),
          double.parse(match.group(3)!),
          double.parse(match.group(4)!),
        ];
      }
    } catch (_) {}
    return null;
  }

  /// 提取 PDF 中所有的 Stream 数据，如果有 Flate 压缩则自动解压，并支持 raw deflate 与头部微调等高级容错解密方式
  static List<String> _extractStreams(Uint8List fileBytes) {
    final List<String> streams = [];
    int index = 0;
    
    // 匹配 "stream" 关键字 (115, 116, 114, 101, 97, 109)
    final streamPattern = [115, 116, 114, 101, 97, 109];
    // 匹配 "endstream" 关键字 (101, 110, 100, 115, 116, 114, 101, 97, 109)
    final endPattern = [101, 110, 100, 115, 116, 114, 101, 97, 109];

    while (index < fileBytes.length) {
      final streamIdx = _findBytes(fileBytes, streamPattern, index);
      if (streamIdx == -1) break;

      int start = streamIdx + 6;
      // 兼容跳过 \r\n 或单纯的 \n 换行符
      while (start < fileBytes.length && (fileBytes[start] == 13 || fileBytes[start] == 10)) {
        start++;
      }

      final endIdx = _findBytes(fileBytes, endPattern, start);
      if (endIdx == -1) break;

      // 往前微调，剔除数据流尾部可能掺杂的 \r\n 换行符
      int end = endIdx;
      while (end > start && (fileBytes[end - 1] == 13 || fileBytes[end - 1] == 10)) {
        end--;
      }

      final streamData = fileBytes.sublist(start, end);

      // 判断此流是否在 PDF 字典中被声明为 /FlateDecode (或者缩写 /Fl) 压缩
      // 向前搜索最近的字典起点 "<<"（常见为对象定义起点），保证 dictText 涵盖完整字典
      int dictStart = streamIdx - 1;
      int searchStart = streamIdx - 2000;
      if (searchStart < 0) searchStart = 0;
      int dictOpener = -1;
      for (int i = streamIdx - 1; i > searchStart; i--) {
        if (fileBytes[i] == 60 /* < */ && i + 1 < streamIdx && fileBytes[i + 1] == 60) {
          dictOpener = i;
          break;
        }
      }
      if (dictOpener != -1) {
        dictStart = dictOpener;
      } else {
        dictStart = searchStart;
      }
      final dictBytes = fileBytes.sublist(dictStart, streamIdx);
      final dictText = String.fromCharCodes(dictBytes);

      // 过滤非内容流：字体文件、XMP 元数据、AI 二进制数据等不应被当作 PDF 内容流解析
      if (dictText.contains('/FontFile') || dictText.contains('/FontFile2') || dictText.contains('/FontFile3')) {
        index = endIdx + 9;
        continue;
      }
      // 过滤 TrueType 字体子集（/Length1 是 PDF 字体子集字典的标识）
      if (dictText.contains('/Length1')) {
        index = endIdx + 9;
        continue;
      }
      // 过滤图片 XObject（/Subtype/Image）的像素流：解压后的二进制像素会被 utf8.decode 当作内容流解析，
      // 状态机将其作为 PDF 操作符处理从而生成大量垃圾碎片路径叠加在 logo / 二维码上
      if (dictText.contains('/Subtype/Image')) {
        index = endIdx + 9;
        continue;
      }
      // 过滤无压缩且长度 > 1000 的二进制流（嵌入字体分片、原始位图等）：它们会被 utf8.decode
      // 误当内容流，而二进制中碰巧出现 'BT'/'Tj' 等字符的概率很高（65536B 中约 63%）
      if (!dictText.contains('/FlateDecode') && !dictText.contains('/Fl') &&
          streamData.length > 1000) {
        index = endIdx + 9;
        continue;
      }
      // 只跳过明确的字体对象，不过滤所有 /Type /Font（可能是字体描述符）
      if (dictText.contains('/Subtype') && dictText.contains('/Type1') || dictText.contains('/TrueType') || dictText.contains('/CIDFont')) {
        index = endIdx + 9;
        continue;
      }
      // AI 文件的私有数据流（未压缩且内容不可读）跳过
      if (!dictText.contains('/FlateDecode') && !dictText.contains('/Fl')) {
        final preview = utf8.decode(streamData.sublist(0, streamData.length > 100 ? 100 : streamData.length), allowMalformed: true);
        if (preview.contains('%!PS-Adobe') || preview.contains('%AI') || preview.contains('xpacket')) {
          index = endIdx + 9;
          continue;
        }
      }

      String? decodedText;

      if (dictText.contains('/FlateDecode') || dictText.contains('/Fl')) {
        // 使用 zlib 解压（PDF 标准 FlateDecode 就是 zlib 格式）
        try {
          final decompressed = zlib.decode(streamData);
          decodedText = utf8.decode(decompressed, allowMalformed: true);
        } catch (_) {}
      } else {
        try {
          decodedText = utf8.decode(streamData, allowMalformed: true);
        } catch (_) {}
      }

      // 过滤：解压后的内容如果不包含真正的 PDF 内容流特征，则不是内容流
      // 必须含文本操作符（BT/Tj/Tf）或图像/字体引用（Do /Im /F）或图形状态（q/Q/cm）。
      // 字体二进制（TrueType/CID 子集数据）虽常碰巧含 ' m'/'l'，但不会同时含 'BT' 或 'Tj' 等 PDF 命令特征。
      if (decodedText != null) {
        final hasContentOps = decodedText.contains('BT') || decodedText.contains('Tj') ||
            decodedText.contains('Tf') || decodedText.contains('TJ') ||
            decodedText.contains(' Do') || decodedText.contains('/Im') ||
            decodedText.contains('/F') || decodedText.contains(' rg') ||
            decodedText.contains(' RG') || decodedText.contains(' k') ||
            decodedText.contains(' K') || decodedText.contains(' w') ||
            decodedText.contains(' J') || decodedText.contains(' j') ||
            decodedText.contains(' M') || decodedText.contains(' d') ||
            decodedText.contains(' ri') || decodedText.contains(' gs') ||
            // 路径绘制组合（多坐标后跟 m/l/c，或四元组 + re）—— 排除孤立的 ' m'/'l'
            RegExp(
                    r'\d+\.?\d* \d+\.?\d* [mlc]\b|\d+\.?\d* \d+\.?\d* \d+\.?\d* \d+\.?\d* re\b')
                .hasMatch(decodedText);
        if (!hasContentOps) {
          index = endIdx + 9;
          continue;
        }
        streams.add(decodedText);
      }

      index = endIdx + 9;
    }
    return streams;
  }

  static int _findBytes(Uint8List data, List<int> pattern, int start) {
    for (int i = start; i <= data.length - pattern.length; i++) {
      bool found = true;
      for (int j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }

  /// 核心后缀表达式状态机：将 PDF 内容流翻译成 SVG 的矢量节点
  ///
  /// [toUnicodeMap] 为 CID → Unicode 映射（来自 ToUnicode CMap），
  /// 用于解码 CID 字体文字（十六进制 <xxxx> 与括号文本高字节）。
  /// [images] 为图片 XObject（/ImX → PNG 字节），供 Do 操作嵌入。
  /// [colorSpaces] 为页面资源中的扩展色彩空间（/CSx → Separation 专色），
  /// 供 `cs`/`scn` 命令使用（AI 导出的黑色边框/条形码依赖此支持）。
  static String _translateContentStreamToSvg(
    String contentText,
    double width,
    double height, [
    Map<int, int> toUnicodeMap = const {},
    Map<String, Uint8List> images = const {},
    Map<String, _SeparationSpace> colorSpaces = const {},
  ]) {
    final List<String> paths = [];
    final sbPath = StringBuffer();

    // 文字处理状态（PDF BT/ET 块）
    bool isTextMode = false;
    final textElements = <String>[];
    double textX = 0.0, textY = 0.0;
    double textFontSize = 12.0;
    double textScale = 1.0; // Tm 文本矩阵的 a/d 缩放（决定最终字号）
    // 同一 Tj/TJ 内的连续文本缓冲（括号与十六进制 CID 合并为一个文本节点）
    String pendingText = '';
    // 待绘制的图片 XObject 名（/ImX 后跟 Do）
    String? pendingImageName;
    // 扩展色彩空间状态：/CSx 名称 token → cs/CS 命令 → scn/SCN 取色
    String? pendingColorSpaceName;
    String? fillColorSpaceName;
    String? strokeColorSpaceName;

    // 当前变换层栈：cm 操作符设置的矩阵按出现顺序入栈（外层在前、内层在后），
    // 后续路径/文字的坐标都处于这些变换层构成的坐标系中。
    // q/Q 保存与恢复栈深度，保证 PDF 的图形状态语义正确。
    final List<String> transformLayers = [];
    final List<int> stateStack = [];
    // q/Q 保存与恢复填充/描边颜色（避免 q 组内的颜色设置泄漏到组外，
    // 导致边框等元素颜色错误——如灰蓝边框误渲染）
    final List<({String fill, String stroke, double strokeWidth})> graphicsState = [];
    // BT/ET 文字状态栈：进入文字时保存路径 fill/stroke，退出文字时恢复
    final List<({String fill, String stroke, double strokeWidth})> textGraphicsState = [];

    // PDF 裁剪路径（W n）支持：
    // PDF 中「W」把当前路径设置为裁剪区域（不绘制），后续填充/描边路径被裁剪到该区域内。
    // AI 导出 PDF 的移动闪联 logo = 山丘弧形裁剪路径（W n）+ 多个四边形填充，
    // 若丢失裁剪关系，四边形会以完整形状渲染成"方块"，盖住正常 logo 弧线。
    // clipDefs 收集 <clipPath> 定义；activeClipId 为当前生效裁剪；clipStateStack 随 q/Q 保存恢复。
    final List<String> clipDefs = [];
    int clipCounter = 0;
    String? activeClipId;
    final List<String?> clipStateStack = [];

    // PDF 默认填充色为 DeviceGray 0（黑色）。AI 导出 PDF 中未显式设置颜色的
    // 路径（"移动爱家"二维码圆角底框 L9864、"移动闪联"图标山丘 L10767 等）
    // 经 q/Q 恢复链使用该初始值。PyMuPDF 渲染这些元素为深灰 #232020
    // （ICC profile 转换结果），纯黑 #000000 会显得过深（用户反馈"黑块"）。
    // 用 #232020 深灰模拟 PyMuPDF 视觉。
    String fill = '#232020';
    String stroke = 'none';
    double strokeWidth = 1.0;

    // 将路径/文本包装上当前全部变换层（多个 transform 用空格连接，SVG 最外层最先应用）
    // 注意顺序：clip-path 必须在 transform 外层！clipPath 坐标是全局（根翻转后）坐标系，
    // 引用元素的 clip 坐标系 = 应用 clip 的 g 所在坐标系。若 clip 放在 transform 内层，
    // 会在 cm 局部坐标系中解释 clip_15 的全局坐标 → 裁剪区域错位（方块问题）。
    String wrapWithLayers(String inner) {
      var wrapped = inner;
      if (transformLayers.isNotEmpty) {
        wrapped = '<g transform="${transformLayers.join(' ')}">$wrapped</g>';
      }
      if (activeClipId != null) {
        wrapped = '<g clip-path="url(#$activeClipId)">$wrapped</g>';
      }
      return wrapped;
    }

    // 输出当前缓冲文本并清空（合并同一 Tj/TJ 内的连续字符）
    void emitPendingText() {
      if (pendingText.isEmpty) return;
      // 过滤 AI/PDF 内嵌的私有超长数据（非真实标签文本，如嵌入字体/元数据）
      if (pendingText.length > 200) {
        pendingText = '';
        return;
      }
      final color = (fill != 'none') ? fill : '#000000';
      final escaped = pendingText
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');
      // 外层 <g transform="matrix(1 0 0 -1 0 H)"> 会翻转路径使 Y 轴正确，但文字也会被镜像
      // 导致上下颠倒。修复：文字 y 取负 + 自身 transform="matrix(1 0 0 -1 0 0)" 再镜像一次，
      // 双重镜像后字形正立且位置与路径对齐（F∘T = 恒等 + 平移）。
      textElements.add(
        '<text x="${textX.toStringAsFixed(2)}" y="${(-textY).toStringAsFixed(2)}" '
        'font-size="${(textFontSize * textScale).toStringAsFixed(1)}" '
        'transform="matrix(1 0 0 -1 0 0)" '
        'font-family="sans-serif" fill="$color">$escaped</text>',
      );
      pendingText = '';
    }

    // 强制 flush 缓冲中尚未输出的路径（在 cm / q / Q 之前调用）
    void flushPendingPath() {
      final dStr = sbPath.toString().trim();
      if (dStr.isNotEmpty &&
          (dStr.startsWith('M') || dStr.startsWith('m')) &&
          _hasDrawCommand(dStr)) {
        paths.add(wrapWithLayers(
          '<path d="$dStr" fill="$fill" stroke="$stroke" stroke-width="$strokeWidth" />',
        ));
        sbPath.clear();
      }
    }

    // 采用更精确的分词（包括括号、十六进制、斜杠、操作符与数值的正确提取）
    // 匹配：括号字符串 (string)、十六进制字符串 <0444057D>（CID 字体文字）、
    // 字体引用名 /F1、单词操作符、数值
    final tokenReg = RegExp(r'\([^)]*\)|<[0-9A-Fa-f\s]*>|/[a-zA-Z0-9#]*|[a-zA-Z*#]+|[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?');
    final tokens = tokenReg.allMatches(contentText).map((m) => m.group(0)!).toList();

    final stack = <double>[];

    for (final token in tokens) {
      if (token.isEmpty) continue;

      // 1. 在文字模式下缓冲括号文本，其它模式下跳过
      if (token.startsWith('(') && token.endsWith(')')) {
        if (!isTextMode) continue;
        // 提取括号内的文字内容（不含首尾括号）
        final raw = token.substring(1, token.length - 1);
        // CID 字体括号文本（含 Latin-1 高字节）用 ToUnicode CMap 解码，
        // 纯 ASCII 文本原样保留，避免字形索引乱码
        pendingText += _decodeParenText(raw, toUnicodeMap);
        continue;
      }

      // 1.5 字体/资源引用名 /F1、/Im0 等（字体由 Tf 生效；图片名保留供 Do 使用）
      if (token.startsWith('/')) {
        if (token.startsWith('/Im')) {
          pendingImageName = token.substring(1);
        } else if (RegExp(r'^/CS\d+$').hasMatch(token)) {
          pendingColorSpaceName = token.substring(1);
        }
        continue;
      }

      // 1.6 十六进制编码的 CID 字符串（如 <0444057D0564>）：
      //     用 ToUnicode CMap 解码为可读文字，无映射时丢弃（避免乱码）
      if (token.startsWith('<') && token.endsWith('>') && !token.startsWith('<<')) {
        if (isTextMode) {
          final hexStr = token.substring(1, token.length - 1).replaceAll(RegExp(r'\s+'), '');
          pendingText += _decodeCidHex(hexStr, toUnicodeMap);
        }
        continue;
      }

      // 2. 尝试作为数值解析
      final val = double.tryParse(token);
      if (val != null) {
        stack.add(val);
        continue;
      }

      // 3. 作为操作符处理
      switch (token) {
        // ===== 文字操作符 =====
        case 'BT': // Begin Text
          // BT 进入文字模式：保存当前路径 fill/stroke 到文字状态栈，
          // 避免 BT 内的 k/K/rg/scn 仅作用于文字 fill（PyMuPDF 行为）。
          textGraphicsState.add((fill: fill, stroke: stroke, strokeWidth: strokeWidth));
          isTextMode = true;
          textX = 0.0;
          textY = 0.0;
          pendingText = '';
          stack.clear();
          break;
        case 'ET': // End Text
          // 退出文字模式：恢复 BT 之前的路径 fill/stroke（避免文字 k 污染后续路径）
          if (textGraphicsState.isNotEmpty) {
            final s = textGraphicsState.removeLast();
            fill = s.fill;
            stroke = s.stroke;
            strokeWidth = s.strokeWidth;
          }
          emitPendingText();
          // 将累积的 text SVG 节点合并到 paths（在主路径之前，确保矢量覆盖文字之上）
          // 若当前存在 cm 变换层，则将文字统一包裹在变换层内，保证坐标定位正确
          if (textElements.isNotEmpty) {
            if (transformLayers.isNotEmpty) {
              paths.add(wrapWithLayers(textElements.join()));
            } else {
              paths.addAll(textElements);
            }
            textElements.clear();
          }
          isTextMode = false;
          stack.clear();
          break;
        case 'Tf': // Select font <font> <size> Tf，字体名 /F1 已被上方跳过，栈中剩 fontSize
          emitPendingText();
          if (stack.length >= 1) {
            textFontSize = stack.removeLast();
            if (textFontSize <= 0) textFontSize = 12.0;
          }
          stack.clear();
          break;
        case 'Td': // Move text position <tx> <ty> Td（文本空间偏移，需乘 Tm 缩放换算页面坐标）
          emitPendingText();
          if (stack.length >= 2) {
            final ty = stack.removeLast();
            final tx = stack.removeLast();
            // Td 偏移量是文本空间单位（未缩放），乘 textScale 才是页面位移，
            // 否则多行文本行距被严重压缩导致文字重叠
            textX += tx * textScale;
            textY += ty * textScale;
          }
          stack.clear();
          break;
        case 'TD': // Move text position + set leading <tx> <ty> TD（文本空间偏移）
          emitPendingText();
          if (stack.length >= 2) {
            final ty = stack.removeLast();
            final tx = stack.removeLast();
            textX += tx * textScale;
            textY += ty * textScale;
          }
          stack.clear();
          break;
        case 'Tm': // Set text matrix: full form <a b c d tx ty> 或简写 <tx ty>
          emitPendingText();
          if (stack.length >= 6) {
            final f = stack.removeLast(); // ty
            final e = stack.removeLast(); // tx
            final d = stack.removeLast(); // scaleY
            stack.removeLast(); // skewY（仅弹出以保持栈序）
            stack.removeLast(); // skewX
            final a = stack.removeLast(); // scaleX
            textX = e;
            textY = f;
            // 实际字号 = Tf 字号 × Tm 缩放（a 为 X 方向缩放，d 为 Y 方向缩放）
            final scale = (a.abs() + d.abs()) / 2;
            textScale = scale > 0 ? scale : 1.0;
          } else if (stack.length >= 2) {
            final ty = stack.removeLast();
            final tx = stack.removeLast();
            textX = tx;
            textY = ty;
          }
          stack.clear();
          break;
        case 'Tj': // Show text string
          emitPendingText();
          stack.clear();
          break;
        case 'TJ': // Show text array — 每个元素为一个数字或括号文本
          // 数组格式：[(text1) -100 (text2) 50 (text3)] TJ
          // 数字（kerning）在文本模式下需累加到 textX
          if (isTextMode && stack.isNotEmpty) {
            // 将栈中的数值作为字间距调整累加到 textX（单位千分比 em）。
            // kerning 是文本空间单位，与 Td 一致需乘 textScale 换算为页面坐标，
            // 否则在缩放 Tm 下横向字距会偏移 textScale 倍。
            for (final v in stack) {
              textX -= v / 1000.0 * textFontSize * textScale;
            }
          }
          emitPendingText();
          stack.clear();
          break;

        // ===== 路径操作符（已有）=====
        // 注意：PDF 规范的 m/l/c/v/y 路径操作符坐标是【绝对】的
        // （当前 user space 坐标，相对于当前变换层原点），
        // 而 SVG 的小写命令才是相对语义。因此这里必须用大写 M/L/C 绝对命令，
        // 不得把 PDF 相对解释为 SVG 相对，否则路径形状会错误（如移动闪联四边形被渲染成方块）。
        case 'm': // moveto (x y m)
          if (stack.length >= 2) {
            final y = stack.removeLast();
            final x = stack.removeLast();
            sbPath.write('M $x $y ');
          }
          stack.clear();
          break;
        case 'l': // lineto (x y l)
          if (stack.length >= 2) {
            final y = stack.removeLast();
            final x = stack.removeLast();
            sbPath.write('L $x $y ');
          }
          stack.clear();
          break;
        case 'c': // curveto (x1 y1 x2 y2 x3 y3 c)
          if (stack.length >= 6) {
            final y3 = stack.removeLast();
            final x3 = stack.removeLast();
            final y2 = stack.removeLast();
            final x2 = stack.removeLast();
            final y1 = stack.removeLast();
            final x1 = stack.removeLast();
            sbPath.write('C $x1 $y1 $x2 $y2 $x3 $y3 ');
          }
          stack.clear();
          break;
        case 'v': // curveto, initial point replicated (x2 y2 x3 y3 v)
          if (stack.length >= 4) {
            final y3 = stack.removeLast();
            final x3 = stack.removeLast();
            final y2 = stack.removeLast();
            final x2 = stack.removeLast();
            sbPath.write('S $x2 $y2 $x3 $y3 ');
          }
          stack.clear();
          break;
        case 'y': // curveto, final point replicated (x1 y1 x3 y3 y)
          if (stack.length >= 4) {
            final y3 = stack.removeLast();
            final x3 = stack.removeLast();
            final y1 = stack.removeLast();
            final x1 = stack.removeLast();
            sbPath.write('C $x1 $y1 $x3 $y3 $x3 $y3 ');
          }
          stack.clear();
          break;
        case 're': // rectangle (x y w h re)
          if (stack.length >= 4) {
            final h = stack.removeLast();
            final w = stack.removeLast();
            final y = stack.removeLast();
            final x = stack.removeLast();
            sbPath.write('M $x $y L ${x + w} $y L ${x + w} ${y + h} L $x ${y + h} Z ');
          }
          stack.clear();
          break;
        case 'h': // closepath
          sbPath.write('Z ');
          break;
        case 'rg': // fill RGB (r g b rg)
          if (stack.length >= 3) {
            final b = (stack.removeLast() * 255).round().clamp(0, 255);
            final g = (stack.removeLast() * 255).round().clamp(0, 255);
            final r = (stack.removeLast() * 255).round().clamp(0, 255);
            fill = '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'RG': // stroke RGB (r g b RG)
          if (stack.length >= 3) {
            final b = (stack.removeLast() * 255).round().clamp(0, 255);
            final g = (stack.removeLast() * 255).round().clamp(0, 255);
            final r = (stack.removeLast() * 255).round().clamp(0, 255);
            stroke = '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'g': // grayscale fill (gray g)
          if (stack.isNotEmpty) {
            final grayVal = (stack.removeLast() * 255).round().clamp(0, 255);
            fill = '#${grayVal.toRadixString(16).padLeft(2, '0')}${grayVal.toRadixString(16).padLeft(2, '0')}${grayVal.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'G': // grayscale stroke (gray G)
          if (stack.isNotEmpty) {
            final grayVal = (stack.removeLast() * 255).round().clamp(0, 255);
            stroke = '#${grayVal.toRadixString(16).padLeft(2, '0')}${grayVal.toRadixString(16).padLeft(2, '0')}${grayVal.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'k': // CMYK fill (c m y k k)
          if (stack.length >= 4) {
            final kVal = stack.removeLast();
            final yVal = stack.removeLast();
            final mVal = stack.removeLast();
            final cVal = stack.removeLast();
            fill = _rgbToHex(_cmykToRgb(cVal, mVal, yVal, kVal));
          }
          stack.clear();
          break;
        case 'K': // CMYK stroke (c m y k K)
          if (stack.length >= 4) {
            final kVal = stack.removeLast();
            final yVal = stack.removeLast();
            final mVal = stack.removeLast();
            final cVal = stack.removeLast();
            stroke = _rgbToHex(_cmykToRgb(cVal, mVal, yVal, kVal));
          }
          stack.clear();
          break;
        case 'scn': // fill 扩展颜色（Separation 专色 / 4 参数 CMYK / 3 参数 RGB / 1 参数灰）
        case 'sc':
          if (fillColorSpaceName != null &&
              colorSpaces.containsKey(fillColorSpaceName) &&
              stack.isNotEmpty) {
            // /CSx cs 1 scn：按 Separation 专色浓度取色（1 scn = 满浓度）
            fill = _hexFromSeparation(colorSpaces[fillColorSpaceName]!, stack.last);
          } else if (stack.length == 4) {
            final kVal = stack.removeLast();
            final yVal = stack.removeLast();
            final mVal = stack.removeLast();
            final cVal = stack.removeLast();
            fill = _rgbToHex(_cmykToRgb(cVal, mVal, yVal, kVal));
          } else if (stack.length >= 3) {
            final b = (stack.removeLast() * 255).round().clamp(0, 255);
            final g = (stack.removeLast() * 255).round().clamp(0, 255);
            final r = (stack.removeLast() * 255).round().clamp(0, 255);
            fill = '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
          } else if (stack.isNotEmpty) {
            final v = (stack.removeLast() * 255).round().clamp(0, 255);
            fill = '#${v.toRadixString(16).padLeft(2, '0')}${v.toRadixString(16).padLeft(2, '0')}${v.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'SCN': // stroke 扩展颜色（Separation 专色 / 4 参数 CMYK / 3 参数 RGB / 1 参数灰）
        case 'SC':
          if (strokeColorSpaceName != null &&
              colorSpaces.containsKey(strokeColorSpaceName) &&
              stack.isNotEmpty) {
            stroke =
                _hexFromSeparation(colorSpaces[strokeColorSpaceName]!, stack.last);
          } else if (stack.length == 4) {
            final kVal = stack.removeLast();
            final yVal = stack.removeLast();
            final mVal = stack.removeLast();
            final cVal = stack.removeLast();
            stroke = _rgbToHex(_cmykToRgb(cVal, mVal, yVal, kVal));
          } else if (stack.length >= 3) {
            final b = (stack.removeLast() * 255).round().clamp(0, 255);
            final g = (stack.removeLast() * 255).round().clamp(0, 255);
            final r = (stack.removeLast() * 255).round().clamp(0, 255);
            stroke = '#${r.toRadixString(16).padLeft(2, '0')}${g.toRadixString(16).padLeft(2, '0')}${b.toRadixString(16).padLeft(2, '0')}';
          } else if (stack.isNotEmpty) {
            final v = (stack.removeLast() * 255).round().clamp(0, 255);
            stroke = '#${v.toRadixString(16).padLeft(2, '0')}${v.toRadixString(16).padLeft(2, '0')}${v.toRadixString(16).padLeft(2, '0')}';
          }
          stack.clear();
          break;
        case 'cs': // fill color space setting（/CS2 cs 1 scn）
          fillColorSpaceName = pendingColorSpaceName;
          stack.clear();
          break;
        case 'CS': // stroke color space setting（/CS2 CS 1 SCN）
          strokeColorSpaceName = pendingColorSpaceName;
          stack.clear();
          break;
        case 'w': // linewidth
          if (stack.isNotEmpty) {
            strokeWidth = stack.removeLast();
          }
          stack.clear();
          break;
        case 'q': // Save graphics state (PDF 图形状态保存：变换层 + 填充/描边颜色)
          // q 操作符保存当前图形状态（变换矩阵与颜色），后续 Q 恢复
          flushPendingPath();
          stateStack.add(transformLayers.length);
          graphicsState.add((fill: fill, stroke: stroke, strokeWidth: strokeWidth));
          // 裁剪路径是 PDF 图形状态的一部分，q/Q 需保存与恢复
          clipStateStack.add(activeClipId);
          stack.clear();
          break;
        case 'Q': // Restore graphics state (PDF 图形状态恢复)
          // Q 恢复 q 保存的图形状态：flush 当前路径后回退变换层与填充/描边颜色。
          // 注意：PDF 内容流可能存在 q/Q 不平衡（多余的 Q），此时 stateStack 为空，
          // Q 应被忽略，否则会错误地把 graphicsState 深处的颜色恢复到当前路径
          // （如 AI 导出的 PDF 中 BT 文字黑色污染后续边框/logo 的 fill）。
          flushPendingPath();
          if (stateStack.isNotEmpty) {
            final depth = stateStack.removeLast();
            while (transformLayers.length > depth) {
              transformLayers.removeLast();
            }
            if (graphicsState.isNotEmpty) {
              final s = graphicsState.removeLast();
              fill = s.fill;
              stroke = s.stroke;
              strokeWidth = s.strokeWidth;
            }
            if (clipStateStack.isNotEmpty) {
              activeClipId = clipStateStack.removeLast();
            }
          } else {
            transformLayers.clear();
            // 多余的 Q（stateStack 已空）：忽略，保持当前 fill/stroke 状态
          }
          stack.clear();
          break;
        case 'cm': // Concatenate matrix to current transformation matrix (a b c d e f cm)
          // cm 是 PDF 中最关键的坐标变换操作符，它改变后续所有绘图的坐标系。
          // 格式: a b c d e f cm，对应矩阵 [a b 0; c d 0; e f 1]
          // e, f 是平移分量，a, d 是缩放，b, c 是旋转/倾斜。
          // PDF 中 cm 通常出现在路径绘制之前（先设置坐标系再画图），
          // 此时 sbPath 为空，旧实现直接丢弃该变换导致后续坐标全部错乱。
          // 修复：无论 sbPath 是否为空，都把 cm 作为新的 SVG 变换层入栈，
          // 后续所有路径与文字坐标都会自动处于该变换层坐标系内。
          if (stack.length >= 6) {
            final f = stack.removeLast(); // ty
            final e = stack.removeLast(); // tx
            final d = stack.removeLast(); // scaleY
            final c = stack.removeLast(); // skewY
            final b = stack.removeLast(); // skewX
            final a = stack.removeLast(); // scaleX
            // flush 属于旧坐标系（cm 之前）的路径缓冲
            flushPendingPath();
            transformLayers.add('matrix($a $b $c $d $e $f)');
          }
          stack.clear();
          break;
        // 路径生成/渲染算子
        case 'S': // Stroke
        case 's':
          final dStr = sbPath.toString().trim();
          if (dStr.isNotEmpty &&
              (dStr.startsWith('M') || dStr.startsWith('m')) &&
              _hasDrawCommand(dStr)) {
            paths.add(wrapWithLayers(
              '<path d="$dStr" fill="none" stroke="$stroke" stroke-width="$strokeWidth" />',
            ));
          }
          sbPath.clear();
          stack.clear();
          break;
        case 'f': // Fill
        case 'f*':
        case 'F':
          final dStr = sbPath.toString().trim();
          if (dStr.isNotEmpty &&
              (dStr.startsWith('M') || dStr.startsWith('m')) &&
              _hasDrawCommand(dStr)) {
            paths.add(wrapWithLayers(
              '<path d="$dStr" fill="$fill" stroke="none" />',
            ));
          }
          sbPath.clear();
          stack.clear();
          break;
        case 'B': // Fill & Stroke
        case 'B*':
        case 'b':
        case 'b*':
          final dStr = sbPath.toString().trim();
          if (dStr.isNotEmpty &&
              (dStr.startsWith('M') || dStr.startsWith('m')) &&
              _hasDrawCommand(dStr)) {
            paths.add(wrapWithLayers(
              '<path d="$dStr" fill="$fill" stroke="$stroke" stroke-width="$strokeWidth" />',
            ));
          }
          sbPath.clear();
          stack.clear();
          break;
        case 'W': // 建立裁剪路径（Set clipping path，不渲染路径本身）
        case 'W*':
          // 当前缓冲的路径作为裁剪区域（如移动闪联 logo 的山丘弧形裁剪），
          // 后续所有填充/描边路径都被裁剪到该区域内。
          final clipDStr = sbPath.toString().trim();
          if (clipDStr.isNotEmpty &&
              (clipDStr.startsWith('M') || clipDStr.startsWith('m')) &&
              _hasDrawCommand(clipDStr)) {
            clipCounter++;
            final clipId = 'clip_$clipCounter';
            // flutter_svg 对 clipPath 内部的任何 transform（<g transform> 或
            // <path transform>）支持异常（渲染空白/卡死）。因此必须把 PDF 垂直翻转
            // （y' = H - y_pdf）预计算到 d 数据坐标中，clipPath 内只保留纯 <path>。
            // 注意：此时 transformLayers 为空（W 前 cm 已经 flush 且 q 内无额外 cm），
            // clip 的 d 数据是 PDF 用户空间全局坐标，翻转后即与根翻转 g 下的引用元素同坐标系。
            final flippedD = _flipPathY(clipDStr, height);
            clipDefs.add('<clipPath id="$clipId"><path d="$flippedD" /></clipPath>');
            activeClipId = clipId;
          }
          sbPath.clear();
          stack.clear();
          break;
        case 'n': // End path without rendering（不改变当前裁剪状态）
          sbPath.clear();
          stack.clear();
          break;
        case 'Do': // Draw image XObject（/ImX Do，位置由当前 cm 变换层定位）
          if (pendingImageName != null && images.isNotEmpty) {
            final png = images[pendingImageName];
            if (png != null) {
              final layer = transformLayers.isNotEmpty ? transformLayers.last : '';
              final mm = RegExp(r'matrix\(([^)]+)\)').firstMatch(layer);
              double tx = 0, ty = 0, sx = 1, sy = 1;
              if (mm != null) {
                final parts = mm.group(1)!.split(RegExp(r'[\s,]+'));
                if (parts.length >= 6) {
                  sx = double.tryParse(parts[0]) ?? 1;
                  sy = double.tryParse(parts[3]) ?? 1;
                  tx = double.tryParse(parts[4]) ?? 0;
                  ty = double.tryParse(parts[5]) ?? 0;
                }
              }
              final w = sx.abs();
              final h = sy.abs();
              // 跳过整页覆盖位图（页面预览/背景图，如 AI 的 /Im13、PDF 的 ipgname），
              // 面积超过页面 50% 的图片会遮挡所有矢量内容
              if (width > 0 && height > 0 && w * h > width * height * 0.5) {
                pendingImageName = null;
                stack.clear();
                break;
              }
              final b64 = base64Encode(png);
              // 图片实际显示位置：cm 的 (tx, ty) 是图片 (0,0) 在翻转坐标系中的位置，
              // 外层翻转矩阵 matrix(1 0 0 -1 0 H) 将其还原到 SVG 坐标系。
              // 正确计算图片顶边 y = H - ty - h（之前错误地用 H - ty 作 y，导致整体下移一个图片高度）。
              // 同时去掉图片自身的 mirror transform（外层 g 已完成翻转）。
              // 图片最终屏幕坐标 y_top = H - ty - h，y_bottom = H - ty。
              // SVG 根 g 的 matrix(1 0 0 -1 0 H) 会翻转 y（y_screen = H - y_svg）。
              // 设 SVG 内 y_svg = ty，矩形向上延伸到 ty + h，则翻转后 y 范围 [H - (ty + h), H - ty] = [y_top, y_bottom] ✓
              final imgY = ty;
              paths.add(
                '<image x="${tx.toStringAsFixed(2)}" y="${imgY.toStringAsFixed(2)}" '
                'width="${w.toStringAsFixed(2)}" height="${h.toStringAsFixed(2)}" '
                'href="data:image/png;base64,$b64" />',
              );
            }
            pendingImageName = null;
          }
          stack.clear();
          break;
        default:
          // 忽略未知和多余的操作符以实现高防错降级
          stack.clear();
          break;
      }
    }

    // 4. 打包为带垂直翻转变换矩阵的 SVG，使坐标完美向自顶向下的屏幕空间靠拢
    final sb = StringBuffer();
    sb.writeln('<svg version="1.1" xmlns="http://www.w3.org/2000/svg" '
        'width="${width}px" height="${height}px" viewBox="0 0 $width $height">');
    if (clipDefs.isNotEmpty) {
      sb.writeln('  <defs>');
      for (final cd in clipDefs) {
        sb.writeln('    $cd');
      }
      sb.writeln('  </defs>');
    }
    sb.writeln('  <g transform="matrix(1 0 0 -1 0 $height)">');
    for (final p in paths) {
      sb.writeln('    $p');
    }
    sb.writeln('  </g>');
    sb.writeln('</svg>');

    return sb.toString();
  }
}
