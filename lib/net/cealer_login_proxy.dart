import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/net/cealer_certs.dart';

class CealerLoginProxy {
  static ServerSocket? _server;
  static ServerSocket? _pixivRelay;
  static ServerSocket? _pximgRelay;
  static int _port = 0;

  static bool _isIp(String s) => RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(s);

  static String _pixivIp() {
    final v = Hoster.api();
    return _isIp(v) ? v : '210.140.139.155';
  }

  static String _pximgIp() {
    final v = Hoster.iPximgNet();
    return _isIp(v) ? v : '210.140.139.133';
  }

  static Future<ServerSocket> _startTlsRelay(SecurityContext ctx, String targetIp) async {
    final relay = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    relay.listen((Socket untouchedClient) async {
      try {
        final tlsClient = await SecureSocket.secureServer(untouchedClient, ctx);
        final rawUp = await Socket.connect(targetIp, 443, timeout: Duration(seconds: 10));
        final tlsUp = await SecureSocket.secure(rawUp, onBadCertificate: (_) => true);
        _pipe(tlsClient, tlsUp);
        _pipe(tlsUp, tlsClient);
      } catch (_) {
        try {
          untouchedClient.destroy();
        } catch (_) {}
      }
    });
    return relay;
  }

  static Future<int> start() async {
    if (_server != null) return _port;
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cealerCertPem))
      ..usePrivateKeyBytes(utf8.encode(cealerKeyPem));

    _pixivRelay = await _startTlsRelay(ctx, _pixivIp());
    _pximgRelay = await _startTlsRelay(ctx, _pximgIp());

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen((Socket client) {
      _handleClient(client);
    });
    return _port;
  }

  static Future<void> stop() async {
    await _server?.close();
    await _pixivRelay?.close();
    await _pximgRelay?.close();
    _server = null;
    _pixivRelay = null;
    _pximgRelay = null;
    _port = 0;
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

      final Socket upstream;
      if (host == 'pixiv.net' || host.endsWith('.pixiv.net') || host.endsWith('.fanbox.cc')) {
        upstream = await Socket.connect(InternetAddress.loopbackIPv4, _pixivRelay!.port);
      } else if (host == 'pximg.net' || host.endsWith('.pximg.net')) {
        upstream = await Socket.connect(InternetAddress.loopbackIPv4, _pximgRelay!.port);
      } else {
        upstream = await Socket.connect(host, port, timeout: Duration(seconds: 10));
      }

      client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await client.flush();

      if (remaining.isNotEmpty) {
        upstream.add(remaining);
      }

      sub.onData((data) {
        try {
          upstream.add(data);
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
      _pipe(upstream, client);
    } catch (_) {
      try {
        client.destroy();
      } catch (_) {}
    }
  }

  static void _pipe(Socket src, Socket dst) {
    src.listen(
      (data) {
        try {
          dst.add(data);
        } catch (_) {}
      },
      onDone: () {
        try {
          dst.destroy();
        } catch (_) {}
      },
      onError: (_) {
        try {
          dst.destroy();
        } catch (_) {}
      },
      cancelOnError: true,
    );
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
