import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';

class CealerLoginProxy {
  static ServerSocket? _server;
  static int _port = 0;

  // Pixiv Cloudflare 边缘节点 (accounts.pixiv.net / app-api.pixiv.net / www.pixiv.net)
  static const String _cfPixivIp = '104.18.42.239';
  static const String _pximgIp = '210.140.139.133';

  static Future<int> start() async {
    if (_server != null) return _port;
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

  static Future<void> _sendFragmentedClientHello(Socket upstream, List<int> data) async {
    // 识别 TLS Handshake (0x16) 记录，按 20 字节进行 TLS 记录层分片绕过 SNI 嗅探
    if (data.length > 25 && data[0] == 0x16 && data[1] == 0x03) {
      final recLen = (data[3] << 8) | data[4];
      if (data.length >= 5 + recLen && recLen > 20) {
        final payload = data.sublist(5, 5 + recLen);
        final tail = data.sublist(5 + recLen);
        const chunkSize = 20;
        for (int offset = 0; offset < payload.length; offset += chunkSize) {
          final end = min(offset + chunkSize, payload.length);
          final slice = payload.sublist(offset, end);
          final record = <int>[
            0x16,
            0x03,
            0x01,
            (slice.length >> 8) & 0xff,
            slice.length & 0xff,
            ...slice,
          ];
          upstream.add(record);
          await upstream.flush();
          await Future.delayed(Duration(milliseconds: 5));
        }
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
      final remaining = <int>[];

      sub = client.listen((chunk) {
        if (!completer.isCompleted) {
          headerBytes.addAll(chunk);
          final text = latin1.decode(headerBytes);
          final idx = text.indexOf('\r\n\r\n');
          if (idx != -1) {
            if (headerBytes.length > idx + 4) {
              remaining.addAll(headerBytes.sublist(idx + 4));
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

      bool needFragment = false;
      String connectHost = host;
      if (host == 'pixiv.net' || host.endsWith('.pixiv.net') || host.endsWith('.fanbox.cc')) {
        connectHost = _cfPixivIp;
        needFragment = true;
      } else if (host == 'pximg.net' || host.endsWith('.pximg.net')) {
        connectHost = _pximgIp;
        needFragment = true;
      }

      final upstream = await Socket.connect(connectHost, port, timeout: Duration(seconds: 10));
      upstream.setOption(SocketOption.tcpNoDelay, true);

      client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await client.flush();

      bool firstPacketSent = false;
      if (remaining.isNotEmpty) {
        firstPacketSent = true;
        if (needFragment) {
          await _sendFragmentedClientHello(upstream, remaining);
        } else {
          upstream.add(remaining);
        }
      }

      sub.onData((data) async {
        try {
          if (!firstPacketSent && needFragment) {
            firstPacketSent = true;
            sub.pause();
            await _sendFragmentedClientHello(upstream, data);
            sub.resume();
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
