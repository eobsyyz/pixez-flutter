import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pixez/er/hoster.dart';

class CealerLoginProxy {
  static ServerSocket? _server;
  static int _port = 0;

  static String _bestCfIp = '104.18.42.239';
  static String _bestPximgIp = '210.140.139.133';

  static final List<String> _cfCandidates = [
    '104.18.42.239',
    '172.64.145.17',
    '104.18.30.199',
    '172.64.157.57',
  ];

  static bool _isIp(String s) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(s);

  static Future<String> _pickFastestIp(List<String> candidates, String fallback) async {
    final completer = Completer<String>();
    int remaining = candidates.length;
    for (final ip in candidates) {
      Socket.connect(ip, 443, timeout: Duration(seconds: 3)).then((sock) {
        sock.destroy();
        if (!completer.isCompleted) completer.complete(ip);
      }).catchError((_) {
        remaining--;
        if (remaining <= 0 && !completer.isCompleted) {
          completer.complete(fallback);
        }
      });
    }
    return completer.future;
  }

  static Future<int> start() async {
    if (_server != null) return _port;

    final hosterImg = Hoster.iPximgNet();
    final pximgCandidates = <String>[
      if (_isIp(hosterImg)) hosterImg,
      '210.140.139.133',
      '210.140.139.136',
      '210.140.139.130',
    ];

    final picked = await Future.wait([
      _pickFastestIp(_cfCandidates, _cfCandidates.first),
      _pickFastestIp(pximgCandidates, '210.140.139.133'),
    ]);
    _bestCfIp = picked[0];
    _bestPximgIp = picked[1];

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen((Socket client) {
      _handleClient(client);
    });
    return _port;
  }

  static Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = 0;
  }

  static int _indexOfBytes(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || haystack.length < needle.length) return -1;
    for (int i = 0; i <= haystack.length - needle.length; i++) {
      bool ok = true;
      for (int j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  static Future<void> _sendTwoPartClientHello(Socket upstream, List<int> data) async {
    if (data.length >= 5 && data[0] == 0x16 && data[1] == 0x03) {
      final recLen = (data[3] << 8) | data[4];
      if (data.length >= 5 + recLen && recLen > 10) {
        final payload = data.sublist(5, 5 + recLen);
        final tail = data.sublist(5 + recLen);

        int splitAt = payload.length ~/ 2;
        for (final kw in ['pixiv', 'pximg', 'fanbox']) {
          final pos = _indexOfBytes(payload, ascii.encode(kw));
          if (pos > 0 && pos + 2 < payload.length) {
            splitAt = pos + 2;
            break;
          }
        }

        final part1 = payload.sublist(0, splitAt);
        final part2 = payload.sublist(splitAt);

        upstream.add(<int>[0x16, 0x03, 0x01, (part1.length >> 8) & 0xff, part1.length & 0xff, ...part1]);
        await upstream.flush();
        await Future.delayed(Duration(milliseconds: 10));
        upstream.add(<int>[0x16, 0x03, 0x01, (part2.length >> 8) & 0xff, part2.length & 0xff, ...part2]);
        await upstream.flush();

        if (tail.isNotEmpty) {
          upstream.add(tail);
          await upstream.flush();
        }
        return;
      }
    }
    upstream.add(data);
    await upstream.flush();
  }

  static Future<void> _handleClient(Socket client) async {
    try {
      final headerBytes = <int>[];
      final completer = Completer<void>();
      late StreamSubscription<List<int>> sub;
      final helloBuf = <int>[];

      sub = client.listen((chunk) {
        if (!completer.isCompleted) {
          headerBytes.addAll(chunk);
          final text = latin1.decode(headerBytes);
          final idx = text.indexOf('\r\n\r\n');
          if (idx != -1) {
            if (headerBytes.length > idx + 4) {
              helloBuf.addAll(headerBytes.sublist(idx + 4));
            }
            sub.pause();
            completer.complete();
          }
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.completeError('err');
      }, onDone: () {
        if (!completer.isCompleted) completer.completeError('eof');
      });

      await completer.future;
      final firstLine = latin1.decode(headerBytes).split('\r\n').first;
      final parts = firstLine.split(' ');
      if (parts.length < 2 || parts[0].toUpperCase() != 'CONNECT') {
        await sub.cancel();
        client.destroy();
        return;
      }

      final targetParts = parts[1].split(':');
      final host = targetParts[0].toLowerCase();
      final port = targetParts.length > 1 ? int.tryParse(targetParts[1]) ?? 443 : 443;

      bool needSplit = false;
      String connectHost = host;
      if (host == 'pixiv.net' || host.endsWith('.pixiv.net') || host.endsWith('.fanbox.cc')) {
        connectHost = _bestCfIp;
        needSplit = true;
      } else if (host == 'pximg.net' || host.endsWith('.pximg.net')) {
        connectHost = _bestPximgIp;
        needSplit = true;
      }

      final upstream = await Socket.connect(connectHost, port, timeout: Duration(seconds: 10));
      upstream.setOption(SocketOption.tcpNoDelay, true);

      client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await client.flush();

      bool helloDone = !needSplit;
      Future<void> processHelloIfReady() async {
        if (helloDone || helloBuf.isEmpty) return;
        if (helloBuf[0] != 0x16) {
          helloDone = true;
          upstream.add(List<int>.from(helloBuf));
          helloBuf.clear();
          return;
        }
        if (helloBuf.length < 5) return;
        final expectedTotal = 5 + ((helloBuf[3] << 8) | helloBuf[4]);
        if (helloBuf.length >= expectedTotal || expectedTotal > 16384) {
          helloDone = true;
          final fullHello = List<int>.from(helloBuf);
          helloBuf.clear();
          sub.pause();
          await _sendTwoPartClientHello(upstream, fullHello);
          sub.resume();
        }
      }

      if (helloBuf.isNotEmpty) {
        if (helloDone) {
          upstream.add(List<int>.from(helloBuf));
          helloBuf.clear();
        } else {
          await processHelloIfReady();
        }
      }

      sub.onData((data) async {
        try {
          if (!helloDone) {
            helloBuf.addAll(data);
            await processHelloIfReady();
          } else {
            upstream.add(data);
          }
        } catch (_) {}
      });
      sub.onDone(() {
        try {
          upstream.destroy();
        } catch (_) {}
      });
      sub.onError((_) {
        try {
          upstream.destroy();
        } catch (_) {}
      });
      sub.resume();

      upstream.listen(
        (data) {
          try {
            client.add(data);
          } catch (_) {}
        },
        onDone: () {
          try {
            client.destroy();
          } catch (_) {}
        },
        onError: (_) {
          try {
            client.destroy();
          } catch (_) {}
        },
        cancelOnError: true,
      );
    } catch (_) {
      try {
        client.destroy();
      } catch (_) {}
    }
  }

  /// 一键呼出内置免翻登录/注册窗口，返回 pixiv://account/login?code=... 回调链接
  static Future<String?> openDirectAuthWebView(String authUrl) async {
    final port = await start();
    try {
      const channel = MethodChannel('pixez/ios_share');
      final callbackUrl = await channel.invokeMethod<String>('openCealerLogin', {
        'port': port,
        'url': authUrl,
      });
      return callbackUrl;
    } finally {
      await stop();
    }
  }
}
