import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/models/illust.dart';

class EoVaultHelper {
  static var _buffer = {};
  static var _expectedCounts = {};

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
      var payload = {
        "category": category,
        "title": title,
        "pages": pages,
      };

      var tempFile = File('${Directory.systemTemp.path}/${illusts.id}.eovault');
      await tempFile.writeAsString(jsonEncode(payload));
      const channel = MethodChannel('pixez/ios_share');
      await channel.invokeMethod('shareFile', {'path': tempFile.path});
    }
  }
}
