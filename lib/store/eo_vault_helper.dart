import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/models/illust.dart';

class EoVaultHelper {
  static var _buffer = {};
  static var _expectedCounts = {};
  static OverlayEntry? _floatingEntry;
  static final ValueNotifier<int> pendingCountNotifier = ValueNotifier<int>(0);

  static Future<Directory> _pendingDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory('${doc.path}/eo_pending');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> refreshPendingCount() async {
    final dir = await _pendingDir();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.eovault')).toList();
    pendingCountNotifier.value = files.length;
  }

  static void ensureFloatingButton(BuildContext context) {
    refreshPendingCount();
    if (_floatingEntry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _floatingEntry = OverlayEntry(
      builder: (ctx) => ValueListenableBuilder<int>(
        valueListenable: pendingCountNotifier,
        builder: (_, count, __) {
          if (count <= 0) return SizedBox.shrink();
          return Positioned(
            right: 16,
            bottom: 96,
            child: Material(
              color: Colors.transparent,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  shape: StadiumBorder(),
                  elevation: 6,
                ),
                icon: Icon(Icons.send_to_mobile, size: 18),
                label: Text("待传Eo ($count)"),
                onPressed: () {
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(builder: (_) => EoQueuePage()),
                  );
                },
              ),
            ),
          );
        },
      ),
    );
    overlay.insert(_floatingEntry!);
  }

  static void prepareExpected(Illusts illusts, {int? singleIndex, int? customCount}) {
    if (!_buffer.containsKey(illusts.id)) _buffer[illusts.id] = [];
    if (customCount != null && customCount > 0) {
      _buffer.remove(illusts.id);
      _expectedCounts[illusts.id] = customCount;
    } else if (illusts.pageCount == 1 || singleIndex != null) {
      if (!_expectedCounts.containsKey(illusts.id)) _expectedCounts[illusts.id] = 1;
    } else {
      _expectedCounts[illusts.id] = illusts.pageCount;
    }
  }

  static Future<void> handleSave(
    Uint8List uint8list,
    Illusts illusts,
    String fileName,
  ) async {
    List list = _buffer[illusts.id] ?? [];
    list.add({"name": fileName, "data": base64Encode(uint8list)});
    _buffer[illusts.id] = list;

    int expected = _expectedCounts[illusts.id] ?? illusts.pageCount;
    if (list.length >= expected) {
      List pages = List.from(list);
      _buffer.remove(illusts.id);
      _expectedCounts.remove(illusts.id);

      String category = (illusts.type == "manga" || illusts.pageCount > 1) ? "漫画" : "插画";
      String title = "${illusts.title.toLegal()}_${illusts.id}";
      var payload = {"category": category, "title": title, "pages": pages};

      final dir = await _pendingDir();
      final file = File('${dir.path}/${illusts.id}_${DateTime.now().millisecondsSinceEpoch}.eovault');
      await file.writeAsString(jsonEncode(payload));
      await refreshPendingCount();
    }
  }

  static Future<List<File>> listPendingFiles() async {
    final dir = await _pendingDir();
    final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.eovault')).toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static Future<void> sendFilesDirectly(List<File> files) async {
    if (files.isEmpty) return;
    List batch = [];
    for (var f in files) {
      try {
        batch.add(jsonDecode(await f.readAsString()));
      } catch (_) {}
    }
    if (batch.isEmpty) return;

    final bytes = utf8.encode(jsonEncode(batch));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    server.listen((HttpRequest req) async {
      if (req.uri.path == '/batch.eovault') {
        req.response.headers.contentType = ContentType.json;
        req.response.add(bytes);
        await req.response.close();
      } else if (req.uri.path == '/ack') {
        for (var f in files) {
          if (await f.exists()) await f.delete();
        }
        await refreshPendingCount();
        req.response.write('ok');
        await req.response.close();
        await server.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });

    Future.delayed(Duration(seconds: 30), () {
      server.close(force: true);
    });

    const channel = MethodChannel('pixez/ios_share');
    await channel.invokeMethod('openEoReader', {'port': port});
  }
}

class EoQueuePage extends StatefulWidget {
  @override
  State<EoQueuePage> createState() => _EoQueuePageState();
}

class _EoQueuePageState extends State<EoQueuePage> {
  List<File> _files = [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await EoVaultHelper.listPendingFiles();
    await EoVaultHelper.refreshPendingCount();
    if (mounted) setState(() => _files = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("待传至 Eo阅读器 (${_files.length})"),
        actions: [
          if (_files.isNotEmpty)
            TextButton.icon(
              onPressed: _sending
                  ? null
                  : () async {
                      setState(() => _sending = true);
                      await EoVaultHelper.sendFilesDirectly(_files);
                      await Future.delayed(Duration(seconds: 2));
                      await _load();
                      if (mounted) setState(() => _sending = false);
                    },
              icon: Icon(Icons.send),
              label: Text("全部直传"),
            ),
        ],
      ),
      body: _files.isEmpty
          ? Center(child: Text("暂无待发送的漫画或插画"))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (_, idx) {
                final f = _files[idx];
                final name = f.path.split('/').last;
                final sizeKB = (f.lengthSync() / 1024).toStringAsFixed(0);
                return ListTile(
                  leading: Icon(Icons.book),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text("$sizeKB KB"),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(Icons.send, color: Colors.blue),
                        onPressed: () async {
                          await EoVaultHelper.sendFilesDirectly([f]);
                          await Future.delayed(Duration(seconds: 2));
                          await _load();
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () async {
                          await f.delete();
                          await _load();
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
