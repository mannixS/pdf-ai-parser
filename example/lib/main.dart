import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf_ai_parser/pdf_ai_parser.dart';

void main() => runApp(const PdfAiParserExampleApp());

class PdfAiParserExampleApp extends StatelessWidget {
  const PdfAiParserExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'pdf_ai_parser 示例',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _pathController =
      TextEditingController(text: 'example/assets/sample.pdf');
  List<ParsedElement>? _elements;
  String? _error;

  Future<void> _parse() async {
    setState(() {
      _error = null;
      _elements = null;
    });
    try {
      final file = File(_pathController.text.trim());
      if (!file.existsSync()) {
        throw Exception('文件不存在: ${file.path}');
      }
      final Uint8List bytes = file.readAsBytesSync();
      // 两段式解析
      final svg = PdfParserService.convertPdfToSvg(bytes);
      final elements = SvgParserService.parseSvgToElements(svg);
      setState(() => _elements = elements);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('pdf_ai_parser 示例')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathController,
                    decoration: const InputDecoration(
                      labelText: 'PDF/AI 文件路径',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: _parse, child: const Text('解析')),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: const TextStyle(color: Colors.red)),
                ),
              ),
            if (_elements != null) ...[
              Text('解析出 ${_elements!.length} 个元素：'),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: _elements!.length,
                  itemBuilder: (context, index) {
                    final el = _elements![index];
                    final desc = switch (el.type) {
                      ParsedElementType.shape =>
                        '形状 ${(el as ParsedShapeElement).shapeType.name}',
                      ParsedElementType.text =>
                        '文本 "${(el as ParsedTextElement).text}"',
                      ParsedElementType.svg => 'SVG 块',
                      ParsedElementType.image => '图片',
                    };
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        switch (el.type) {
                          ParsedElementType.shape => Icons.category,
                          ParsedElementType.text => Icons.text_fields,
                          ParsedElementType.svg => Icons.gesture,
                          ParsedElementType.image => Icons.image,
                        },
                        size: 20,
                      ),
                      title: Text(el.name),
                      subtitle: Text(
                        '$desc  x=${el.x.toStringAsFixed(1)} y=${el.y.toStringAsFixed(1)} '
                        'w=${el.width.toStringAsFixed(1)} h=${el.height.toStringAsFixed(1)}',
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
