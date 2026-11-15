import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/models/illust.dart';

class EoVaultHelper {
  static var _buffer = {};
  static var _expectedCounts = {};
  static var _completedQueue = [];

  static int get pendingCount => _completedQueue.length;

  static void prepareExpected(Illusts illusts, {int? singleIndex, int? customCount}) {
    if (!_buffer.containsKey(illusts.id)) {
      _buffer[illusts.id] = [];
    }
    if (customCount != null && customCount > 0) {
      _buffer.remove(illusts.id);
      _expectedCounts[illusts.id] = customCount;
    } else if (illusts.pageCount == 1 || singleIndex != null) {
      if (!_expectedCounts.containsKey(illusts.id)) {
        _expectedCounts[illusts.id] = 1;
      }
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
    list.add({
      "name": fileName,
      "data": base64Encode(uint8list),
    });
    _buffer[illusts.id] = list;

    int expected = _expectedCounts[illusts.id] ?? illusts.pageCount;
    if (list.length >= expected) {
      List pages = List.from(list);
      _buffer.remove(illusts.id);
      _expectedCounts.remove(illusts.id);

      String category =
          (illusts.type == "manga" || illusts.pageCount > 1) ? "漫画" : "插画";
      String title = "${illusts.title.toLegal()}_${illusts.id}";
      _completedQueue.add({
        "category": category,
        "title": title,
        "pages": pages,
      });

      _showSilentQueueToast(illusts.title);
    }
  }

  static void _showSilentQueueToast(String lastTitle) {
    BotToast.showCustomText(
      onlyOne: true,
      duration: Duration(seconds: 5),
      toastBuilder: (cancelFunc) => Align(
        alignment: Alignment(0, 0.82),
        child: Card(
          elevation: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text("已暂存「$lastTitle」(共 ${_completedQueue.length} 部)"),
                SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    cancelFunc();
                    flushToEoReader();
                  },
                  child: Text("全部发给 Eo"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Future<void> flushToEoReader() async {
    if (_completedQueue.isEmpty) return;
    List batch = List.from(_completedQueue);
    _completedQueue.clear();

    var tempFile = File(
      '${Directory.systemTemp.path}/batch_${DateTime.now().millisecondsSinceEpoch}.eovault',
    );
    await tempFile.writeAsString(jsonEncode(batch));
    const channel = MethodChannel('pixez/ios_share');
    await channel.invokeMethod('shareFile', {'path': tempFile.path});
  }
}
