import 'dart:ui';

/// 解析出的元素类型枚举
enum ParsedElementType { shape, text, svg, image }

/// 解析出的形状类型
enum ParsedShapeType { rectangle, circle, ellipse, line, polygon, path, other }

/// PDF/AI 解析出的矢量元素轻量基类。
///
/// 不依赖宿主项目的元素模型（如 LabelElement），是中性、可分享的 DTO。
/// 宿主项目可自行映射为自己的元素体系。
abstract class ParsedElement {
  final String id;
  final String name;
  final double x;
  final double y;
  final double width;
  final double height;
  final int zIndex;

  const ParsedElement({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.zIndex,
  });

  /// 元素类型
  ParsedElementType get type;

  /// 返回一个仅名称改变的新元素（用于导入编号）
  ParsedElement rename(String newName);

  /// 序列化为 JSON（便于调试与持久化）
  Map<String, dynamic> toJson();
}

/// 形状元素（矩形/圆形/椭圆/线段/多边形/路径）
class ParsedShapeElement extends ParsedElement {
  final ParsedShapeType shapeType;
  final Color? fillColor;
  final Color? strokeColor;
  final double strokeWidth;
  final double cornerRadius;
  /// 路径数据（shapeType == path 时有值）
  final String? pathData;

  @override
  ParsedElementType get type => ParsedElementType.shape;

  const ParsedShapeElement({
    required super.id,
    required super.name,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required super.zIndex,
    required this.shapeType,
    this.fillColor,
    this.strokeColor,
    this.strokeWidth = 0.0,
    this.cornerRadius = 0.0,
    this.pathData,
  });

  @override
  ParsedShapeElement rename(String newName) => ParsedShapeElement(
    id: id,
    name: newName,
    x: x,
    y: y,
    width: width,
    height: height,
    zIndex: zIndex,
    shapeType: shapeType,
    fillColor: fillColor,
    strokeColor: strokeColor,
    strokeWidth: strokeWidth,
    cornerRadius: cornerRadius,
    pathData: pathData,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'shape',
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'zIndex': zIndex,
    'shapeType': shapeType.name,
    'fillColor': fillColor?.toARGB32(),
    'strokeColor': strokeColor?.toARGB32(),
    'strokeWidth': strokeWidth,
    'cornerRadius': cornerRadius,
    'pathData': pathData,
  };
}

/// 文本元素
class ParsedTextElement extends ParsedElement {
  final String text;
  final double fontSize;
  final Color color;
  final String fontFamily;

  @override
  ParsedElementType get type => ParsedElementType.text;

  const ParsedTextElement({
    required super.id,
    required super.name,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required super.zIndex,
    required this.text,
    required this.fontSize,
    required this.color,
    required this.fontFamily,
  });

  @override
  ParsedTextElement rename(String newName) => ParsedTextElement(
    id: id,
    name: newName,
    x: x,
    y: y,
    width: width,
    height: height,
    zIndex: zIndex,
    text: text,
    fontSize: fontSize,
    color: color,
    fontFamily: fontFamily,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'zIndex': zIndex,
    'text': text,
    'fontSize': fontSize,
    'color': color.toARGB32(),
    'fontFamily': fontFamily,
  };
}

/// SVG 矢量块元素（路径/多边形被打散为独立 SVG 文档片段）
class ParsedSvgElement extends ParsedElement {
  final String svgContent;

  @override
  ParsedElementType get type => ParsedElementType.svg;

  const ParsedSvgElement({
    required super.id,
    required super.name,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required super.zIndex,
    required this.svgContent,
  });

  @override
  ParsedSvgElement rename(String newName) => ParsedSvgElement(
    id: id,
    name: newName,
    x: x,
    y: y,
    width: width,
    height: height,
    zIndex: zIndex,
    svgContent: svgContent,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'svg',
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'zIndex': zIndex,
    'svgContentLength': svgContent.length,
  };
}

/// 位图图片元素（内嵌 base64）
class ParsedImageElement extends ParsedElement {
  final String base64;
  final String? imagePath;

  @override
  ParsedElementType get type => ParsedElementType.image;

  const ParsedImageElement({
    required super.id,
    required super.name,
    required super.x,
    required super.y,
    required super.width,
    required super.height,
    required super.zIndex,
    required this.base64,
    this.imagePath,
  });

  @override
  ParsedImageElement rename(String newName) => ParsedImageElement(
    id: id,
    name: newName,
    x: x,
    y: y,
    width: width,
    height: height,
    zIndex: zIndex,
    base64: base64,
    imagePath: imagePath,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'zIndex': zIndex,
    'base64Length': base64.length,
    'imagePath': imagePath,
  };
}
