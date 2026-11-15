import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/models/illust.dart';

class EoVaultHelper {
  static final Map<int, List>> _buffer = {};
  static final Map<int, int> _expectedCounts = {};

  static void prepareExpected(Illusts illusts, {int? singleIndex, int? customCount}) {
    _buffer.putIfAbsent(illusts.id, () => []);
    if (customCount != null && customCount > 0) {
      _buffer.remove(illusts.id);
      _expectedCounts[illusts.id] = customCount;
    } else if (illusts.pageCount == 1 || singleIndex != null) {
      _expectedCounts.putIfAbsent(illusts.id, () => 1);
    } else {
      _expectedCounts[illusts.id] = illusts.pageCount;
    }
  }

  static Future<void> handleSave(
    Uint8List uint8list,
    Illusts illusts,
    String fileName,
  ) async {
    final list = _buffer.putIfAbsent(illusts.id, () => []);
    list.add({
      "name": fileName,
      "data": base64Encode(uint8list),
    });
    final expected = _expectedCounts[illusts.id] ?? illusts.pageCount;
    if (list.length >= expected) {
      final pages = List>.from(list);
      _buffer.remove(illusts.id);
      _expectedCounts.remove(illusts.id);

      final String category =
          (illusts.type == "manga" || illusts.pageCount > 1) ? "漫画" : "插画";
      final String title = "${illusts.title.toLegal()}_${illusts.id}";
      final payload = {
        "category": category,
        "title": title,
        "pages": pages,
      };

      final tempFile = File('${Directory.systemTemp.path}/${illusts.id}.eovault');
      await tempFile.writeAsString(jsonEncode(payload));
      const channel = MethodChannel('pixez/ios_share');
      await channel.invokeMethod('shareFile', {'path': tempFile.path});
    }
  }
}
