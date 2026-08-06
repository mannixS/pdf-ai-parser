import 'dart:math' as math;
import 'dart:ui';
import 'package:xml/xml.dart' as xml;
import 'models/parsed_element.dart';
import 'utils/id_generator.dart';

class SvgParserService {
  /// 将 SVG 的 CSS 样式规则内联化，以解决失去样式表上下文引发的“黑色方块”渲染瑕疵
  static String inlineSvgStyles(String svgContent) {
    try {
      final document = xml.XmlDocument.parse(svgContent);
      final root = document.rootElement;

      // 1. 提取所有 <style> 内的样式规则
      final styleNodes = document.findAllElements('style');
      final cssRules = <String, Map<String, String>>{};
      for (final styleNode in styleNodes) {
        cssRules.addAll(_parseCssRules(styleNode.innerText));
      }

      // 2. 递归将类选择器及父级继承属性合并并写入各个元素节点的 Inline 属性中
      _inlineNode(root, cssRules, {}, Offset.zero);

      // 3. 安全移除 XML 树中的所有 <style> 节点
      final stylesList = List<xml.XmlNode>.from(styleNodes);
      for (final node in stylesList) {
        node.parent?.children.remove(node);
      }

      return document.toXmlString();
    } catch (_) {
      return svgContent; // 降级处理：解析失败返回原始字符串
    }
  }

  /// 递归解析、样式继承与 Inlining 行内化逻辑
  static void _inlineNode(
    xml.XmlElement element,
    Map<String, Map<String, String>> cssRules,
    Map<String, String> inheritedStyles,
    Offset offset,
  ) {
    // 处理 transform 的简易位移累加 (translate)
    Offset currentOffset = offset;
    final transformAttr = element.getAttribute('transform');
    if (transformAttr != null) {
      final match = RegExp(r'translate\s*\(\s*([-+]?\d*\.?\d+)\s*,\s*([-+]?\d*\.?\d+)\s*\)').firstMatch(transformAttr);
      if (match != null) {
        final dx = double.parse(match.group(1)!);
        final dy = double.parse(match.group(2)!);
        currentOffset += Offset(dx, dy);
      }
    }

    // 收集当前的 class 样式表规则
    final classAttr = element.getAttribute('class');
    final Map<String, String> classStyles = {};
    if (classAttr != null) {
      final classes = classAttr.split(RegExp(r'\s+'));
      for (final cls in classes) {
        final rule = cssRules[cls.trim()];
        if (rule != null) {
          classStyles.addAll(rule);
        }
      }
    }

    // 合并继承、类和当前节点的行内属性 (优先级：行内 > 类 > 继承)
    final Map<String, String> resolvedStyles = Map.from(inheritedStyles);
    classStyles.forEach((k, v) => resolvedStyles[k] = v);

    for (final attr in ['fill', 'stroke', 'stroke-width', 'font-size', 'font-family']) {
      final val = element.getAttribute(attr);
      if (val != null) {
        resolvedStyles[attr] = val;
      }
    }

    // 写回当前的内联属性，使子元素具有完整行内样式
    resolvedStyles.forEach((key, value) {
      if (element.getAttribute(key) == null) {
        element.setAttribute(key, value);
      }
    });

    // 递归处理子元素
    for (final child in element.children.whereType<xml.XmlElement>()) {
      _inlineNode(child, cssRules, resolvedStyles, currentOffset);
    }
  }

  static Map<String, Map<String, String>> _parseCssRules(String cssText) {
    final rules = <String, Map<String, String>>{};
    
    // 移除所有 CSS 注释
    final cleanCss = cssText.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    
    // 匹配: 选择器块 { 属性声明 }
    final blockRegex = RegExp(r'([^{]+)\{([^}]+)\}');
    
    for (final blockMatch in blockRegex.allMatches(cleanCss)) {
      final selectorsText = blockMatch.group(1)!;
      final declarationsText = blockMatch.group(2)!;
      
      // 解析声明体中的属性
      final styleMap = <String, String>{};
      final properties = declarationsText.split(';');
      for (final prop in properties) {
        if (prop.trim().isEmpty) continue;
        final parts = prop.split(':');
        if (parts.length >= 2) {
          final name = parts[0].trim().toLowerCase();
          final value = parts.sublist(1).join(':').trim();
          styleMap[name] = value;
        }
      }
      
      // 分解逗号分隔的选择器
      final selectors = selectorsText.split(',');
      for (final selector in selectors) {
        final cleanSelector = selector.trim();
        if (cleanSelector.startsWith('.')) {
          final className = cleanSelector.substring(1).trim();
          if (className.isNotEmpty) {
            if (rules.containsKey(className)) {
              rules[className]!.addAll(styleMap);
            } else {
              rules[className] = Map.from(styleMap);
            }
          }
        }
      }
    }
    return rules;
  }

  /// 将 SVG 拆解/打散为轻量矢量元素列表（ParsedElement），并做视口等比缩放。
  ///
  /// [maxImportSize] 最长边目标尺寸（导入后等比缩放到该尺寸）。
  /// [startX]/[startY] 元素在目标画布中的起始偏移。
  static List<ParsedElement> parseSvgToElements(
    String svgContent, {
    double maxImportSize = 200.0,
    double startX = 50.0,
    double startY = 50.0,
  }) {
    final List<ParsedElement> elements = [];

    try {
      // 1. 进行内联样式防黑块净化并解析 XML
      final document = xml.XmlDocument.parse(inlineSvgStyles(svgContent));
      final root = document.rootElement;

      // 2. 获取视口 viewBox 大小，如果缺失则尝试从 width/height 中提取
      double viewBoxX = 0;
      double viewBoxY = 0;
      double viewBoxW = 800;
      double viewBoxH = 600;

      final viewBoxAttr = root.getAttribute('viewBox');
      if (viewBoxAttr != null) {
        final parts = viewBoxAttr.split(RegExp(r'[\s,]+')).map(double.tryParse).toList();
        if (parts.length >= 4 && parts[0] != null && parts[1] != null && parts[2] != null && parts[3] != null) {
          viewBoxX = parts[0]!;
          viewBoxY = parts[1]!;
          viewBoxW = parts[2]!;
          viewBoxH = parts[3]!;
        }
      } else {
        final wAttr = root.getAttribute('width');
        final hAttr = root.getAttribute('height');
        if (wAttr != null) {
          viewBoxW = double.tryParse(wAttr.replaceAll(RegExp(r'[a-zA-Z]'), '')) ?? 800;
        }
        if (hAttr != null) {
          viewBoxH = double.tryParse(hAttr.replaceAll(RegExp(r'[a-zA-Z]'), '')) ?? 600;
        }
      }
      if (viewBoxW <= 0) viewBoxW = 800;
      if (viewBoxH <= 0) viewBoxH = 600;

      // 3. 计算自适应比例尺：如果有显式的特定限制（比如 maxImportSize 小于 200），或者大图纸（大于 1000）
      double scale = 1.0;
      if (maxImportSize < 200.0) {
        scale = math.min(maxImportSize / viewBoxW, maxImportSize / viewBoxH);
      } else if (viewBoxW > 1000 || viewBoxH > 1000) {
        scale = math.min(600.0 / viewBoxW, 600.0 / viewBoxH);
      }

      int zIndex = 0;

      // 导入元素全局序号：为每个导入的元素在名称前加上 #N，
      // 宿主项目可据此定位/调试元素
      int importSeq = 0;
      void addElement(ParsedElement el) {
        importSeq++;
        elements.add(el.rename('#$importSeq ${el.name}'));
      }

      // 判断是否属于定义块、裁剪区、样式或元数据模板（defs, clipPath, mask, symbol等），这些图元不应当直接在画布上被渲染
      bool shouldSkipElement(xml.XmlElement el) {
        final t = el.name.local.toLowerCase();
        return t == 'defs' || t == 'clippath' || t == 'mask' || t == 'symbol' || t == 'style' || t == 'metadata';
      }

      // 预提取文档中全部 <defs> 定义模板字符串（只遍历一次，供所有子图元复用），
      // 避免 _createSubSvg 对每个 path 都全文档查找 defs 造成 O(n²) 级解析卡顿
      final List<String> precomputedDefs = [];
      try {
        for (final defs in root.document!.findAllElements('defs')) {
          precomputedDefs.add(defs.toXmlString());
        }
      } catch (_) {}

      // 提取分隔符列表中的第一个浮点数
      double parseFirstNumber(String? str, double defaultVal) {
        if (str == null || str.trim().isEmpty) return defaultVal;
        final match = RegExp(r'[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?').firstMatch(str);
        if (match != null) {
          return double.tryParse(match.group(0)!) ?? defaultVal;
        }
        return defaultVal;
      }

      // 递归处理节点，显式级联传递 parentTransforms 仿射变换链
      void processElement(
          xml.XmlElement el, List<String> parentTransforms, List<String> parentClips) {
        if (shouldSkipElement(el)) return;
        final tag = el.name.local.toLowerCase();

        // 将元素自身的 transform 并入变换链：自身 bounds 计算与子元素递归都必须包含它。
        // 否则形如 <text transform="matrix(1 0 0 1 tx ty)"> 的无 x/y 属性文本会全部丢失定位而堆叠在左上角。
        final List<String> selfTransforms = List.from(parentTransforms);
        final selfTransAttr = el.getAttribute('transform');
        if (selfTransAttr != null && selfTransAttr.trim().isNotEmpty) {
          selfTransforms.add(selfTransAttr.trim());
        }

        // 级联收集父级 g 的 clip-path 引用（如 PDF 导出的"山丘弧形裁剪"），
        // 最终传递到 _createSubSvg 的子 SVG 最外层，保证被裁剪路径与裁剪区域同坐标系。
        final List<String> selfClips = List.from(parentClips);
        final selfClipAttr = el.getAttribute('clip-path');
        if (selfClipAttr != null && selfClipAttr.trim().isNotEmpty) {
          selfClips.add(selfClipAttr.trim());
        }

        // 1. 如果是 <use> 元素，寻找引用的源模板并进行实例化克隆，同时级联 translate 位移与变换
        if (tag == 'use') {
          final href = el.getAttribute('href') ?? el.getAttribute('xlink:href');
          if (href != null && href.startsWith('#')) {
            final targetId = href.substring(1);
            final doc = el.document;
            if (doc != null) {
              xml.XmlElement? targetElement;
              try {
                final matched = doc.findAllElements('*').where((node) => node.getAttribute('id') == targetId);
                if (matched.isNotEmpty) {
                  targetElement = matched.first;
                }
              } catch (_) {}

              if (targetElement != null) {
                // 克隆模板，附带 use 身上的平移属性
                final clonedTarget = targetElement.copy();
                
                final useX = parseFirstNumber(el.getAttribute('x'), 0.0);
                final useY = parseFirstNumber(el.getAttribute('y'), 0.0);

                final List<String> useTransforms = List.from(parentTransforms);
                if (useX != 0.0 || useY != 0.0) {
                  useTransforms.add('translate($useX, $useY)');
                }
                final useTransAttr = el.getAttribute('transform');
                if (useTransAttr != null && useTransAttr.trim().isNotEmpty) {
                  useTransforms.add(useTransAttr.trim());
                }

                // 深度遍历克隆体并带入其级联变换
                processElement(clonedTarget, useTransforms, selfClips);
              }
            }
          }
          return; // use 已经被展开解析并加入了 elements，直接返回
        }

        // 提取并解析该节点的 fill/stroke 样式属性
        final fillStr = el.getAttribute('fill');
        final strokeStr = el.getAttribute('stroke');
        final strokeWStr = el.getAttribute('stroke-width');

        final fillColor = parseSvgColor(fillStr);
        final strokeColor = parseSvgColor(strokeStr);
        final double strokeWidthVal = double.tryParse(strokeWStr ?? '1') ?? 1.0;

        ParsedElement? canvasElement;

        if (tag == 'rect') {
          final rxVal = double.tryParse(el.getAttribute('rx') ?? '0') ?? 0.0;
          final x = double.tryParse(el.getAttribute('x') ?? '0') ?? 0.0;
          final y = double.tryParse(el.getAttribute('y') ?? '0') ?? 0.0;
          final w = double.tryParse(el.getAttribute('width') ?? '0') ?? 0.0;
          final h = double.tryParse(el.getAttribute('height') ?? '0') ?? 0.0;
          
          final raw = Rect.fromLTWH(x, y, w, h);
          final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

          canvasElement = ParsedShapeElement(
            id: IdGenerator.generate(),
            name: '矩形图层',
            x: startX + (localBounds.left - viewBoxX) * scale,
            y: startY + (localBounds.top - viewBoxY) * scale,
            width: localBounds.width * scale,
            height: localBounds.height * scale,
            zIndex: zIndex++,
            shapeType: ParsedShapeType.rectangle,
            cornerRadius: rxVal * scale,
            strokeColor: strokeColor,
            strokeWidth: strokeWidthVal * scale,
            fillColor: fillColor,
          );
        } else if (tag == 'circle') {
          final cx = double.tryParse(el.getAttribute('cx') ?? '0') ?? 0.0;
          final cy = double.tryParse(el.getAttribute('cy') ?? '0') ?? 0.0;
          final r = double.tryParse(el.getAttribute('r') ?? '0') ?? 0.0;
          
          final raw = Rect.fromLTWH(cx - r, cy - r, r * 2, r * 2);
          final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

          canvasElement = ParsedShapeElement(
            id: IdGenerator.generate(),
            name: '圆形图层',
            x: startX + (localBounds.left - viewBoxX) * scale,
            y: startY + (localBounds.top - viewBoxY) * scale,
            width: localBounds.width * scale,
            height: localBounds.height * scale,
            zIndex: zIndex++,
            shapeType: ParsedShapeType.circle,
            strokeColor: strokeColor,
            strokeWidth: strokeWidthVal * scale,
            fillColor: fillColor,
          );
        } else if (tag == 'ellipse') {
          final cx = double.tryParse(el.getAttribute('cx') ?? '0') ?? 0.0;
          final cy = double.tryParse(el.getAttribute('cy') ?? '0') ?? 0.0;
          final rx = double.tryParse(el.getAttribute('rx') ?? '0') ?? 0.0;
          final ry = double.tryParse(el.getAttribute('ry') ?? '0') ?? 0.0;
          
          final raw = Rect.fromLTWH(cx - rx, cy - ry, rx * 2, ry * 2);
          final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

          canvasElement = ParsedShapeElement(
            id: IdGenerator.generate(),
            name: '椭圆图层',
            x: startX + (localBounds.left - viewBoxX) * scale,
            y: startY + (localBounds.top - viewBoxY) * scale,
            width: localBounds.width * scale,
            height: localBounds.height * scale,
            zIndex: zIndex++,
            shapeType: ParsedShapeType.ellipse,
            strokeColor: strokeColor,
            strokeWidth: strokeWidthVal * scale,
            fillColor: fillColor,
          );
        } else if (tag == 'line') {
          final x1 = double.tryParse(el.getAttribute('x1') ?? '0') ?? 0.0;
          final y1 = double.tryParse(el.getAttribute('y1') ?? '0') ?? 0.0;
          final x2 = double.tryParse(el.getAttribute('x2') ?? '0') ?? 0.0;
          final y2 = double.tryParse(el.getAttribute('y2') ?? '0') ?? 0.0;

          final double minX = math.min(x1, x2);
          final double maxX = math.max(x1, x2);
          final double minY = math.min(y1, y2);
          final double maxY = math.max(y1, y2);
          
          final raw = Rect.fromLTRB(minX, minY, maxX, maxY);
          final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

          canvasElement = ParsedShapeElement(
            id: IdGenerator.generate(),
            name: '线段图层',
            x: startX + (localBounds.left - viewBoxX) * scale,
            y: startY + (localBounds.top - viewBoxY) * scale,
            width: localBounds.width * scale,
            height: localBounds.height * scale,
            zIndex: zIndex++,
            shapeType: ParsedShapeType.line,
            strokeColor: strokeColor,
            strokeWidth: strokeWidthVal * scale,
            fillColor: null,
          );
        } else if (tag == 'text') {
          // 1. 递归收集全部后代 tspan，并仅保留不含 tspan 子级的“叶子”片段。
          // Illustrator 常见 <tspan class="..."><tspan x=".." y="..">文字</tspan></tspan> 双层嵌套：
          // 坐标位于内层叶子节点上，若只取直接子级会拿到无坐标的外层容器，
          // 导致多行文字全部堆在同一位置且无法换行。
          final tspans = el.findAllElements('tspan').where((t) {
            return !t.children.whereType<xml.XmlElement>().any((c) => c.name.local.toLowerCase() == 'tspan');
          }).toList();
          if (tspans.isNotEmpty) {
            for (final tspan in tspans) {
              final textContent = tspan.innerText.trim();
              if (textContent.isNotEmpty) {
                double x = parseFirstNumber(tspan.getAttribute('x'), 0.0);
                double y = parseFirstNumber(tspan.getAttribute('y'), 0.0);
                if (tspan.getAttribute('x') == null) {
                  x = parseFirstNumber(el.getAttribute('x'), 0.0);
                }
                if (tspan.getAttribute('y') == null) {
                  y = parseFirstNumber(el.getAttribute('y'), 0.0);
                }

                final fsStr = tspan.getAttribute('font-size') ?? el.getAttribute('font-size');
                final fontSizeVal = double.tryParse(fsStr?.replaceAll(RegExp(r'[a-zA-Z]'), '') ?? '14') ?? 14.0;
                final fontFamily = tspan.getAttribute('font-family') ?? el.getAttribute('font-family') ?? 'Microsoft YaHei';

                final textW = estimateTextWidth(textContent, fontSizeVal);
                final textH = fontSizeVal * 1.2;
                
                final raw = Rect.fromLTWH(x, y - fontSizeVal, textW, textH);
                final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

                final fillStr = tspan.getAttribute('fill') ?? el.getAttribute('fill');
                final tspanColor = parseSvgColor(fillStr);

                final tspanElement = ParsedTextElement(
                  id: IdGenerator.generate(),
                  name: '文本图层',
                  x: startX + (localBounds.left - viewBoxX) * scale,
                  y: startY + (localBounds.top - viewBoxY) * scale,
                  width: localBounds.width * scale,
                  height: localBounds.height * scale,
                  zIndex: zIndex++,
                  text: textContent,
                  fontSize: fontSizeVal * scale,
                  color: tspanColor ?? const Color(0xFF000000),
                  fontFamily: fontFamily,
                );
                addElement(tspanElement);
              }
            }
            canvasElement = null; // 子节点独立导出，不重复导出 parent text
          } else {
            // 2. 没有子 tspan，直接处理 text 节点自身
            final textContent = el.innerText.trim();
            if (textContent.isNotEmpty) {
              final x = parseFirstNumber(el.getAttribute('x'), 0.0);
              final y = parseFirstNumber(el.getAttribute('y'), 0.0);
              
              final fsStr = el.getAttribute('font-size');
              final fontSizeVal = double.tryParse(fsStr?.replaceAll(RegExp(r'[a-zA-Z]'), '') ?? '14') ?? 14.0;
              final fontFamily = el.getAttribute('font-family') ?? 'Microsoft YaHei';

              final textW = estimateTextWidth(textContent, fontSizeVal);
              final textH = fontSizeVal * 1.2;
              
              final raw = Rect.fromLTWH(x, y - fontSizeVal, textW, textH);
              final localBounds = applyTransformsToBounds(raw, selfTransforms, viewBoxH);

              canvasElement = ParsedTextElement(
                id: IdGenerator.generate(),
                name: '文本图层',
                x: startX + (localBounds.left - viewBoxX) * scale,
                y: startY + (localBounds.top - viewBoxY) * scale,
                width: localBounds.width * scale,
                height: localBounds.height * scale,
                zIndex: zIndex++,
                text: textContent,
                fontSize: fontSizeVal * scale,
                color: fillColor ?? const Color(0xFF000000),
                fontFamily: fontFamily,
              );
            }
          }
        } else if (tag == 'path') {
          final d = el.getAttribute('d');
          if (d != null && d.trim().isNotEmpty) {
            final cleanD = d.trim();
            // 只有当路径是以 M/m 开头时，才视为合法矢量路径进行解析打散，防止 Expected to find moveTo command 崩溃
            if (cleanD.startsWith('M') || cleanD.startsWith('m')) {
              final rawBounds = estimatePathBounds(cleanD);
              final localBounds = applyTransformsToBounds(rawBounds, selfTransforms, viewBoxH);
              // 合并同一 <g> 容器内的所有 path/polygon 兄弟到同一 SVG 文档：
              // PyMuPDF 把它们渲染在同一个 picture 中（连贯图标），而我们原本每个独立
              // 路径一个 picture → 16 个独立形状看起来像"4 个方块"挡住正常 logo。
              // 只合并第一个 path 兄弟时调用 _createSubSvg（避免重复）。
              final allGChildren = _collectGChildren(el);
              // 注意：不过滤面积过小的路径——二维码/条码的模块可能仅 1-2px，
              // 过滤会误删二维码导致"二维码消失"。仅零面积占位路径
              // （M+Z 空路径，已在 pdf_parser 层通过 _hasDrawCommand 过滤）。
              final subSvg = _createSubSvg(el, rawBounds, parentTransforms, localBounds, precomputedDefs, allGChildren, selfClips);

              canvasElement = ParsedSvgElement(
                id: IdGenerator.generate(),
                name: '路径图层',
                x: startX + (localBounds.left - viewBoxX) * scale,
                y: startY + (localBounds.top - viewBoxY) * scale,
                width: localBounds.width * scale,
                height: localBounds.height * scale,
                zIndex: zIndex++,
                svgContent: subSvg,
              );
            }
          }
        } else if (tag == 'polygon') {
          final ptsStr = el.getAttribute('points');
          if (ptsStr != null && ptsStr.trim().isNotEmpty) {
            final rawBounds = _estimatePolygonBounds(ptsStr);
            final localBounds = applyTransformsToBounds(rawBounds, selfTransforms, viewBoxH);
            final allGChildren = _collectGChildren(el);
            final subSvg = _createSubSvg(el, rawBounds, parentTransforms, localBounds, precomputedDefs, allGChildren, selfClips);

            canvasElement = ParsedSvgElement(
              id: IdGenerator.generate(),
              name: '多边形图层',
              x: startX + (localBounds.left - viewBoxX) * scale,
              y: startY + (localBounds.top - viewBoxY) * scale,
              width: localBounds.width * scale,
              height: localBounds.height * scale,
              zIndex: zIndex++,
              svgContent: subSvg,
            );
          }
        } else if (tag == 'image') {
          // PDF/AI 导入的位图（data:image/png;base64,...）解析为图片图层
          final href = el.getAttribute('href') ?? el.getAttribute('xlink:href');
          if (href != null && href.contains(';base64,')) {
            final base64Data = href.split(';base64,').last.trim();
            if (base64Data.isNotEmpty) {
              final x = parseFirstNumber(el.getAttribute('x'), 0.0);
              final y = parseFirstNumber(el.getAttribute('y'), 0.0);
              final w = parseFirstNumber(el.getAttribute('width'), 0.0);
              final h = parseFirstNumber(el.getAttribute('height'), 0.0);
              if (w > 0 && h > 0) {
                final raw = Rect.fromLTWH(x, y, w, h);
                final localBounds =
                    applyTransformsToBounds(raw, selfTransforms, viewBoxH);
                canvasElement = ParsedImageElement(
                  id: IdGenerator.generate(),
                  name: '图片图层',
                  x: startX + (localBounds.left - viewBoxX) * scale,
                  y: startY + (localBounds.top - viewBoxY) * scale,
                  width: localBounds.width * scale,
                  height: localBounds.height * scale,
                  zIndex: zIndex++,
                  base64: base64Data,
                );
              }
            }
          }
        }

        if (canvasElement != null) {
          addElement(canvasElement);
        }

        // 递归处理子元素，直接传递已含当前节点 transform 的 selfTransforms
        for (final child in el.children.whereType<xml.XmlElement>()) {
          processElement(child, selfTransforms, selfClips);
        }
      }

      // 5. 触发递归首层遍历，包含根 svg 的 transform（如果存在的话）
      final List<String> rootTransforms = [];
      final rootTrans = root.getAttribute('transform');
      if (rootTrans != null && rootTrans.trim().isNotEmpty) {
        rootTransforms.add(rootTrans.trim());
      }
      for (final child in root.children.whereType<xml.XmlElement>()) {
        processElement(child, rootTransforms, const []);
      }
    } catch (_) {}

    return elements;
  }

  /// 逐字符精确估算文本宽度：全角字符（CJK、全角标点）按 1.0 倍字号，半角字符按 0.7 倍字号。
  /// 统一按 length × 0.7 会严重低估中文宽度，导致画布 TextPainter 排版换行后末尾文字被 clip 裁剪而"缺失"。
  /// 半角取 0.7 是为大写字母（W/M/B 等约 0.7~0.9em）预留余量——框偏宽无害，偏窄会被裁剪。
  static double estimateTextWidth(String text, double fontSize) {
    double width = 0;
    for (final rune in text.runes) {
      width += rune > 0x2E7F ? fontSize : fontSize * 0.7;
    }
    return width;
  }

  /// 纯 Dart 状态机高精 SVG 路径包围框测算（零外部 package 依赖）
  static Rect estimatePathBounds(String d) {
    double minX = double.infinity;
    double maxX = double.negativeInfinity;
    double minY = double.infinity;
    double maxY = double.negativeInfinity;

    // 分词匹配指令和数值（支持负数、小数点和科学计数法）
    final RegExp tokenRegex = RegExp(r'([a-df-zADF-Z])|([-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)');
    final matches = tokenRegex.allMatches(d).map((m) => m.group(0)!).toList();

    double currentX = 0.0;
    double currentY = 0.0;

    int i = 0;
    String cmd = '';
    while (i < matches.length) {
      final token = matches[i];
      final isCmd = RegExp(r'[a-df-zADF-Z]').hasMatch(token);
      if (isCmd) {
        cmd = token;
        i++;
      } else {
        final cleanCmd = cmd.toLowerCase();
        if (cleanCmd == 'm' || cleanCmd == 'l' || cleanCmd == 't') {
          if (i + 1 < matches.length) {
            final x = double.tryParse(matches[i]) ?? 0.0;
            final y = double.tryParse(matches[i + 1]) ?? 0.0;
            if (cmd == cleanCmd) { // 相对位移
              currentX += x;
              currentY += y;
            } else { // 绝对坐标
              currentX = x;
              currentY = y;
            }
            if (currentX < minX) minX = currentX;
            if (currentX > maxX) maxX = currentX;
            if (currentY < minY) minY = currentY;
            if (currentY > maxY) maxY = currentY;
            i += 2;
          } else {
            i++;
          }
        } else if (cleanCmd == 'h') {
          final x = double.tryParse(matches[i]) ?? 0.0;
          if (cmd == 'h') {
            currentX += x;
          } else {
            currentX = x;
          }
          if (currentX < minX) minX = currentX;
          if (currentX > maxX) maxX = currentX;
          i++;
        } else if (cleanCmd == 'v') {
          final y = double.tryParse(matches[i]) ?? 0.0;
          if (cmd == 'v') {
            currentY += y;
          } else {
            currentY = y;
          }
          if (currentY < minY) minY = currentY;
          if (currentY > maxY) maxY = currentY;
          i++;
        } else if (cleanCmd == 'c') {
          // 三次贝塞尔曲线: c dx1 dy1, dx2 dy2, dx3 dy3 (6个参数)
          if (i + 5 < matches.length) {
            final x1 = double.tryParse(matches[i]) ?? 0.0;
            final y1 = double.tryParse(matches[i + 1]) ?? 0.0;
            final x2 = double.tryParse(matches[i + 2]) ?? 0.0;
            final y2 = double.tryParse(matches[i + 3]) ?? 0.0;
            final x3 = double.tryParse(matches[i + 4]) ?? 0.0;
            final y3 = double.tryParse(matches[i + 5]) ?? 0.0;

            double px1, py1, px2, py2, px3, py3;
            if (cmd == 'c') {
              px1 = currentX + x1;
              py1 = currentY + y1;
              px2 = currentX + x2;
              py2 = currentY + y2;
              px3 = currentX + x3;
              py3 = currentY + y3;
              currentX += x3;
              currentY += y3;
            } else {
              px1 = x1;
              py1 = y1;
              px2 = x2;
              py2 = y2;
              px3 = x3;
              py3 = y3;
              currentX = x3;
              currentY = y3;
            }
            // 扫描控制点与端点以包络真实的曲线区间
            for (final cx in [px1, px2, px3]) {
              if (cx < minX) minX = cx;
              if (cx > maxX) maxX = cx;
            }
            for (final cy in [py1, py2, py3]) {
              if (cy < minY) minY = cy;
              if (cy > maxY) maxY = cy;
            }
            i += 6;
          } else {
            i++;
          }
        } else if (cleanCmd == 's' || cleanCmd == 'q') {
          // 简写三次/二次曲线: s dx2 dy2, dx3 dy3 或 q dx1 dy1, dx2 dy2 (4个参数)
          if (i + 3 < matches.length) {
            final x1 = double.tryParse(matches[i]) ?? 0.0;
            final y1 = double.tryParse(matches[i + 1]) ?? 0.0;
            final x2 = double.tryParse(matches[i + 2]) ?? 0.0;
            final y2 = double.tryParse(matches[i + 3]) ?? 0.0;

            double px1, py1, px2, py2;
            if (cmd == cleanCmd) {
              px1 = currentX + x1;
              py1 = currentY + y1;
              px2 = currentX + x2;
              py2 = currentY + y2;
              currentX += x2;
              currentY += y2;
            } else {
              px1 = x1;
              py1 = y1;
              px2 = x2;
              py2 = y2;
              currentX = x2;
              currentY = y2;
            }
            for (final cx in [px1, px2]) {
              if (cx < minX) minX = cx;
              if (cx > maxX) maxX = cx;
            }
            for (final cy in [py1, py2]) {
              if (cy < minY) minY = cy;
              if (cy > maxY) maxY = cy;
            }
            i += 4;
          } else {
            i++;
          }
        } else if (cleanCmd == 'a') {
          // 弧线: a rx ry x-axis-rotation large-arc-flag sweep-flag x y (7个参数，最后两位是坐标)
          if (i + 6 < matches.length) {
            final x = double.tryParse(matches[i + 5]) ?? 0.0;
            final y = double.tryParse(matches[i + 6]) ?? 0.0;
            if (cmd == 'a') {
              currentX += x;
              currentY += y;
            } else {
              currentX = x;
              currentY = y;
            }
            if (currentX < minX) minX = currentX;
            if (currentX > maxX) maxX = currentX;
            if (currentY < minY) minY = currentY;
            if (currentY > maxY) maxY = currentY;
            i += 7;
          } else {
            i++;
          }
        } else {
          i++;
        }
      }
    }

    if (minX == double.infinity || maxX == double.negativeInfinity ||
        minY == double.infinity || maxY == double.negativeInfinity) {
      return const Rect.fromLTWH(0, 0, 100, 100);
    }

    double w = maxX - minX;
    double h = maxY - minY;
    if (w <= 0) w = 1.0;
    if (h <= 0) h = 1.0;
    return Rect.fromLTWH(minX, minY, w, h);
  }

  /// 利用 Path 原生测量多边形边界框
  static Rect _estimatePolygonBounds(String pointsStr) {
    try {
      final numberRegex = RegExp(r'[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?');
      final matches = numberRegex.allMatches(pointsStr).map((m) => double.parse(m.group(0)!)).toList();
      if (matches.length < 2) return const Rect.fromLTWH(0, 0, 100, 100);
      
      final path = Path();
      path.moveTo(matches[0], matches[1]);
      for (int i = 2; i < matches.length - 1; i += 2) {
        path.lineTo(matches[i], matches[i + 1]);
      }
      path.close();
      
      final bounds = path.getBounds();
      double w = bounds.width;
      double h = bounds.height;
      if (w <= 0) w = 1.0;
      if (h <= 0) h = 1.0;
      return Rect.fromLTWH(bounds.left, bounds.top, w, h);
    } catch (_) {
      return const Rect.fromLTWH(0, 0, 100, 100);
    }
  }

  /// 物理应用祖先节点累计的全部平移、缩放与仿射矩阵（如 matrix 或 translate）变换，算出屏幕坐标系下的绝对 Bounds
  static Rect applyTransformsToBounds(Rect rawBounds, List<String> transforms, double viewBoxH) {
    Rect current = rawBounds;
    // SVG 参数模式：数字支持负数/小数/科学计数；参数间允许逗号、空格或混合分隔（SVG 规范）
    const numPat = r'[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?';
    const sep = r'(?:\s*,\s*|\s+)';

    // 变换链列表按"祖先在前、自身在尾"排列；SVG 规范中自身 transform 位于最内层，
    // 必须逆序应用（screen = T_root ∘ ... ∘ T_parent ∘ T_self(p)），否则父级平移叠加自身缩放 matrix 时坐标错位。
    for (final trans in transforms.reversed) {
      // 1. 处理通用的仿射矩阵变换 matrix(a b c d tx ty)，兼容逗号/空格/混合分隔
      final matrixReg = RegExp('matrix\\s*\\(\\s*($numPat)$sep($numPat)$sep($numPat)$sep($numPat)$sep($numPat)$sep($numPat)\\s*\\)');
      final matrixMatch = matrixReg.firstMatch(trans);
      if (matrixMatch != null) {
        final a = double.parse(matrixMatch.group(1)!);
        final b = double.parse(matrixMatch.group(2)!);
        final c = double.parse(matrixMatch.group(3)!);
        final d = double.parse(matrixMatch.group(4)!);
        final tx = double.parse(matrixMatch.group(5)!);
        final ty = double.parse(matrixMatch.group(6)!);

        // 利用仿射矩阵变换公式变换矩形的四个端角点，提取极值重新闭包 Bounds
        final points = [
          Offset(current.left, current.top),
          Offset(current.right, current.top),
          Offset(current.left, current.bottom),
          Offset(current.right, current.bottom),
        ];

        double minX = double.infinity;
        double maxX = double.negativeInfinity;
        double minY = double.infinity;
        double maxY = double.negativeInfinity;

        for (final pt in points) {
          final nx = a * pt.dx + c * pt.dy + tx;
          final ny = b * pt.dx + d * pt.dy + ty;
          if (nx < minX) minX = nx;
          if (nx > maxX) maxX = nx;
          if (ny < minY) minY = ny;
          if (ny > maxY) maxY = ny;
        }

        current = Rect.fromLTRB(minX, minY, maxX, maxY);
        continue;
      }
      
      // 2. 处理常规平移位移 translate(dx, dy)，兼容空格分隔（Illustrator 风格）与单参数形式 translate(dx)
      final transMatch = RegExp('translate\\s*\\(\\s*($numPat)(?:$sep($numPat))?\\s*\\)').firstMatch(trans);
      if (transMatch != null) {
        final dx = double.parse(transMatch.group(1)!);
        final dy = double.tryParse(transMatch.group(2) ?? '') ?? 0.0;
        current = current.shift(Offset(dx, dy));
      }
    }
    return current;
  }

  /// 收集同一 <g> 容器内所有可合并的图形兄弟（含 element 自身），
  /// 用于 _createSubSvg 合并到同一 SVG 文档以保持图标的连贯性
  /// （避免每个 path 独立 picture 渲染造成的"4 个方块挡住 logo"问题）
  static List<xml.XmlElement> _collectGChildren(xml.XmlElement el) {
    final result = <xml.XmlElement>[el];
    final parent = el.parent;
    if (parent == null) return result;
    for (final sibling in parent.children.whereType<xml.XmlElement>()) {
      if (identical(sibling, el)) continue;
      final n = sibling.localName.toLowerCase();
      if (n == 'path' || n == 'polygon' || n == 'circle' ||
          n == 'ellipse' || n == 'line' || n == 'rect') {
        result.add(sibling);
      }
    }
    return result;
  }

  /// 对子图元进行内联并包裹其全部累计的祖先 transform 变换，并自动注入原始的 <defs> 渐变与裁剪模板，确保渲染绝对完整
  static String _createSubSvg(
    xml.XmlElement element,
    Rect rawBounds,
    List<String> parentTransforms,
    Rect finalBounds, [
    List<String>? precomputedDefs,
    List<xml.XmlElement>? siblings,
    List<String>? parentClips,
  ]) {
    // 同一 <g> 容器内的所有 path/polygon 兄弟合并到同一个 SVG 文档：
    // PyMuPDF 把它们渲染在同一个 picture 中（连贯图标），
    // 而我们原本每个 SvgElement 独立 picture → 多个独立形状看起来像"4 个方块"。
    // siblings 包含同组的所有 path 兄弟（包含 element 自身）。
    final elementsToMerge = siblings ?? <xml.XmlElement>[element];

    final List<String> defsStrings;
    if (precomputedDefs != null) {
      defsStrings = precomputedDefs;
    } else {
      defsStrings = [];
      final doc = element.document;
      if (doc != null) {
        final defsElements = doc.findAllElements('defs');
        for (final defs in defsElements) {
          defsStrings.add(defs.toXmlString());
        }
      }
    }

    final sb = StringBuffer();
    sb.writeln('<?xml version="1.0" encoding="utf-8"?>');
    sb.writeln('<svg version="1.1" xmlns="http://www.w3.org/2000/svg" ');
    sb.writeln('  width="${finalBounds.width}px" height="${finalBounds.height}px" ');
    sb.writeln('  viewBox="${finalBounds.left} ${finalBounds.top} ${finalBounds.width} ${finalBounds.height}">');

    // 注意：clipPath 内部不允许任何 transform（flutter_svg 对 clipPath 内
    // 的 <g transform> / <path transform> 支持异常，会卡死或渲染空白）。
    // 因此 pdf_parser 在生成 clip 时已把 PDF 垂直翻转预计算到 d 数据坐标中
    // （y' = H - y_pdf），clipPath 内只有纯 <path>，无需在此转换。
    // 子 SVG 的 viewBox 是元素绝对坐标范围，clip 的绝对坐标天然落在其中。
    for (final defsStr in defsStrings) {
      sb.writeln('  $defsStr');
    }

    final childrenXml = elementsToMerge.map((e) => e.toXmlString()).join('\n    ');

    // 最外层 clip g：clip 坐标（PDF 全局翻转后）与子 SVG viewBox 同坐标系，
    // 必须包在 transform g 外层，使裁剪区域与 path 最终渲染位置一致。
    final clips = parentClips ?? const <String>[];
    if (clips.isNotEmpty) {
      final clipAttrs = clips.map((c) => 'clip-path="$c"').join(' ');
      sb.writeln('  <g $clipAttrs>');
    }
    if (parentTransforms.isNotEmpty) {
      final combined = parentTransforms.join(' ');
      sb.writeln('  <g transform="$combined">');
      sb.writeln('    $childrenXml');
      sb.writeln('  </g>');
    } else {
      sb.writeln('  $childrenXml');
    }
    if (clips.isNotEmpty) {
      sb.writeln('  </g>');
    }
    sb.writeln('</svg>');
    return sb.toString();
  }

  /// 将 SVG 常见颜色格式翻译为 Flutter 的 Color
  static Color? parseSvgColor(String? colorStr) {
    if (colorStr == null) return null;
    final clean = colorStr.trim().toLowerCase();
    if (clean == 'none' || clean.isEmpty) return null;

    if (clean.startsWith('#')) {
      final hex = clean.substring(1);
      if (hex.length == 3) {
        final r = hex[0] * 2;
        final g = hex[1] * 2;
        final b = hex[2] * 2;
        return Color(int.parse('FF$r$g$b', radix: 16));
      } else if (hex.length == 6) {
        return Color(int.parse('FF$hex', radix: 16));
      } else if (hex.length == 8) {
        return Color(int.parse(hex, radix: 16));
      }
    }

    if (clean.startsWith('rgb')) {
      final match = RegExp(r'rgb\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)').firstMatch(clean);
      if (match != null) {
        final r = int.parse(match.group(1)!);
        final g = int.parse(match.group(2)!);
        final b = int.parse(match.group(3)!);
        return Color.fromARGB(255, r, g, b);
      }
    }

    const named = {
      'red': Color(0xFFFF0000),
      'green': Color(0xFF008000),
      'blue': Color(0xFF0000FF),
      'white': Color(0xFFFFFFFF),
      'black': Color(0xFF000000),
      'yellow': Color(0xFFFFFF00),
      'cyan': Color(0xFF00FFFF),
      'magenta': Color(0xFFFF00FF),
      'gray': Color(0xFF808080),
      'grey': Color(0xFF808080),
      'orange': Color(0xFFFFA500),
      'purple': Color(0xFF800080),
      'pink': Color(0xFFFFC0CB),
    };
    return named[clean];
  }
}
