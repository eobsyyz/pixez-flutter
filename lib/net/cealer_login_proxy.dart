import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:pixez/er/hoster.dart';
import 'package:pixez/net/cealer_certs.dart';

class CealerLoginProxy {
  static ServerSocket? _server;
  static int _port = 0;

  static Future<int> start() async {
    if (_server != null) return _port;
    final ctx = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cealerCertPem))
      ..usePrivateKeyBytes(utf8.encode(cealerKeyPem));

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen((Socket client) {
      _handleClient(client, ctx);
    });
    return _port;
  }

  static Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = 0;
  }

  static String? _resolveCealingIp(String host) {
    final h = host.toLowerCase();
    if (h == 'pixiv.net' || h.endsWith('.pixiv.net') || h.endsWith('.fanbox.cc')) {
      return Hoster.api();
    }
    if (h == 'pximg.net' || h.endsWith('.pximg.net')) {
      return Hoster.iPximgNet();
    }
    return null;
  }

  static Future<void> _handleClient(Socket client, SecurityContext serverCtx) async {
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
        client.destroy();
        return;
      }

      final targetParts = parts[1].split(':');
      final host = targetParts[0];
      final port = targetParts.length > 1 ? int.tryParse(targetParts[1]) ?? 443 : 443;
      final cealingIp = _resolveCealingIp(host);

      client.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await client.flush();
      await sub.cancel();

      if (cealingIp != null) {
        // 剥离 SNI 直连 Pixiv / Pximg 官方 IP
        final tlsClient = await SecureSocket.secureServer(client, serverCtx);
        final rawUp = await Socket.connect(cealingIp, port, timeout: Duration(seconds: 10));
        final tlsUp = await SecureSocket.secure(rawUp, onBadCertificate: (_) => true);
        if (remaining.isNotEmpty) tlsUp.add(remaining);
        _pipe(tlsClient, tlsUp);
        _pipe(tlsUp, tlsClient);
      } else {
        // 其余域名（如 recaptcha.net / gstatic）直接透明转发
        final up = await Socket.connect(host, port, timeout: Duration(seconds: 10));
        if (remaining.isNotEmpty) up.add(remaining);
        _pipe(client, up);
        _pipe(up, client);
      }
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
