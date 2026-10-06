import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const discoveryPort = 8766;
const transferPort = 8765;

void main() => runApp(const PaliaShareApp());

class PaliaShareApp extends StatelessWidget {
  const PaliaShareApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Palia Share',
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff18b78a),
          scaffoldBackgroundColor: Colors.white,
        ),
        home: const HomePage(),
      );
}

class DeviceInfo {
  final String id;
  final String name;
  final String address;
  final int port;
  DateTime lastSeen;

  DeviceInfo({required this.id, required this.name, required this.address, required this.port}) : lastSeen = DateTime.now();
}

class IncomingTransfer {
  final String id;
  final String senderName;
  final String senderIp;
  final List<Map<String, dynamic>> files;
  final HttpRequest request;
  final Completer<bool> decision = Completer<bool>();

  IncomingTransfer({required this.id, required this.senderName, required this.senderIp, required this.files, required this.request});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  RawDatagramSocket? _discovery;
  HttpServer? _server;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  final Map<String, DeviceInfo> devices = {};
  IncomingTransfer? incoming;
  String status = 'Starting nearby sharing…';
  double progress = 0;
  String? receivingName;

  String get deviceName => Platform.localHostname.trim().isEmpty ? 'Palia Share PC' : Platform.localHostname.trim();

  String get deviceId => deviceName;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, transferPort, shared: true);
      _server!.listen(_handleHttpRequest);

      _discovery = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _discovery!.broadcastEnabled = true;
      _discovery!.listen((event) {
        if (event != RawSocketEvent.read) return;
        Datagram? packet;
        while ((packet = _discovery!.receive()) != null) {
          _handleDiscovery(packet!);
        }
      });

      _announceTimer = Timer.periodic(const Duration(seconds: 2), (_) => _announce());
      _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        final now = DateTime.now();
        devices.removeWhere((_, d) => now.difference(d.lastSeen).inSeconds > 7);
        if (mounted) setState(() {});
      });
      _announce();
      if (mounted) setState(() => status = 'Nearby devices are ready');
    } catch (e) {
      if (mounted) setState(() => status = 'Network unavailable: $e');
    }
  }

  void _handleDiscovery(Datagram packet) {
    try {
      final data = jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
      if (data['type'] != 'palia-share') return;
      final id = '${data['id'] ?? ''}';
      if (id.isEmpty || id == deviceId) return;
      final port = int.tryParse('${data['port'] ?? transferPort}') ?? transferPort;
      final name = '${data['name'] ?? 'Palia Share'}';
      final existing = devices[id];
      if (existing == null) {
        devices[id] = DeviceInfo(id: id, name: name, address: packet.address.address, port: port);
      } else {
        existing.lastSeen = DateTime.now();
      }
      if (mounted) setState(() => status = '${devices.length} nearby device${devices.length == 1 ? '' : 's'} found');
    } catch (_) {}
  }

  void _announce() {
    final socket = _discovery;
    if (socket == null) return;
    final data = utf8.encode(jsonEncode({
      'type': 'palia-share',
      'id': deviceId,
      'name': deviceName,
      'port': transferPort,
    }));
    try {
      socket.send(data, InternetAddress('255.255.255.255'), discoveryPort);
    } catch (_) {}
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/request') {
        final body = await utf8.decoder.bind(request).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final files = ((data['files'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final req = IncomingTransfer(
          id: '${data['id'] ?? DateTime.now().millisecondsSinceEpoch}',
          senderName: '${data['senderName'] ?? 'Palia Share'}',
          senderIp: request.connectionInfo?.remoteAddress.address ?? '',
          files: files,
          request: request,
        );
        incoming = req;
        if (mounted) {
          setState(() => status = '${req.senderName} wants to send ${files.length} file${files.length == 1 ? '' : 's'}');
          _showIncomingDialog(req);
        }
        final accepted = await req.decision.future;
        request.response.statusCode = accepted ? HttpStatus.ok : HttpStatus.forbidden;
        await request.response.close();
        if (incoming == req) incoming = null;
        return;
      }

      if (request.method == 'PUT' && request.uri.path == '/upload') {
        await _receiveUpload(request);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      if (mounted) setState(() => status = 'Transfer error: $e');
    }
  }

  Future<void> _receiveUpload(HttpRequest request) async {
    final rawName = Uri.decodeComponent(request.headers.value('x-file-name') ?? 'received.bin');
    final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final base = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.current.path;
    final dir = Directory('$base\\Downloads\\Palia Share');
    await dir.create(recursive: true);
    var target = File('${dir.path}\\$safeName');
    var index = 1;
    while (await target.exists()) {
      final dot = safeName.lastIndexOf('.');
      final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
      final ext = dot > 0 ? safeName.substring(dot) : '';
      target = File('${dir.path}\\$stem ($index)$ext');
      index++;
    }

    final sink = target.openWrite();
    var received = 0;
    final total = request.contentLength;
    receivingName = safeName;
    if (mounted) setState(() => progress = 0);
    await for (final chunk in request) {
      sink.add(chunk);
      received += chunk.length;
      if (mounted && total > 0) {
        setState(() {
          progress = received / total;
          status = 'Receiving $safeName… ${(progress * 100).toStringAsFixed(0)}%';
        });
      }
    }
    await sink.close();
    receivingName = null;
    if (mounted) {
      setState(() {
        progress = 1;
        status = 'Received: $safeName';
      });
    }
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> _showIncomingDialog(IncomingTransfer req) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Incoming files'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${req.senderName} wants to send ${req.files.length} file${req.files.length == 1 ? '' : 's'}.', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            ...req.files.take(5).map((f) => Text('• ${f['name']}')),
            if (req.files.length > 5) Text('• +${req.files.length - 5} more'),
            const SizedBox(height: 10),
            const Text('Files will be saved in Downloads\\Palia Share.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (!req.decision.isCompleted) req.decision.complete(false);
              Navigator.pop(context);
            },
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () {
              if (!req.decision.isCompleted) req.decision.complete(true);
              Navigator.pop(context);
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndSend(DeviceInfo device) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (result == null || result.files.isEmpty) return;
    final files = result.files.where((f) => f.path != null).toList();
    if (files.isEmpty) return;

    try {
      setState(() {
        status = 'Requesting permission from ${device.name}…';
        progress = 0;
      });
      final client = HttpClient();
      final request = await client.postUrl(Uri.parse('http://${device.address}:${device.port}/request'));
      final payload = {
        'id': '${DateTime.now().millisecondsSinceEpoch}-$deviceId',
        'senderName': deviceName,
        'files': files.map((f) => {'name': f.name, 'size': f.size}).toList(),
      };
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(const Duration(minutes: 10));
      if (response.statusCode != HttpStatus.ok) {
        client.close(force: true);
        if (mounted) setState(() => status = 'Transfer rejected');
        return;
      }

      var completedBytes = 0;
      var totalBytes = 0;
      for (final f in files) {
        totalBytes += await File(f.path!).length();
      }

      for (final f in files) {
        final file = File(f.path!);
        final length = await file.length();
        final upload = await client.openUrl('PUT', Uri.parse('http://${device.address}:${device.port}/upload'));
        upload.headers.set('x-file-name', Uri.encodeComponent(f.name));
        upload.headers.contentType = ContentType.binary;
        upload.contentLength = length;
        var fileBytes = 0;
        await for (final chunk in file.openRead()) {
          upload.add(chunk);
          fileBytes += chunk.length;
          completedBytes += chunk.length;
          if (mounted) {
            setState(() {
              progress = totalBytes == 0 ? 0 : completedBytes / totalBytes;
              status = 'Sending ${f.name}… ${(fileBytes / length * 100).toStringAsFixed(0)}%';
            });
          }
        }
        final uploadResponse = await upload.close();
        await uploadResponse.drain<void>();
        if (uploadResponse.statusCode != HttpStatus.ok) throw Exception('Upload failed: HTTP ${uploadResponse.statusCode}');
      }
      client.close(force: true);
      if (mounted) setState(() { progress = 1; status = 'Transfer complete'; });
    } catch (e) {
      if (mounted) setState(() => status = 'Transfer failed: $e');
    }
  }

  @override
  void dispose() {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    _discovery?.close();
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Palia Share', style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [IconButton(onPressed: _announce, icon: const Icon(Icons.refresh)), const SizedBox(width: 8)],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Palia Share', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  const Text('Palia Share by PaliaWin Store  •  Developer by Shanpalia'),
                  const SizedBox(height: 24),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            const Icon(Icons.wifi_tethering, size: 28),
                            const SizedBox(width: 12),
                            Expanded(child: Text(status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                            if (progress > 0 && progress < 1) SizedBox(width: 220, child: LinearProgressIndicator(value: progress)),
                          ]),
                          const SizedBox(height: 20),
                          if (devices.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 35),
                              child: Center(child: Text('No nearby Palia Share device found.\nKeep both devices on the same Wi-Fi network.', textAlign: TextAlign.center)),
                            )
                          else
                            ...devices.values.map((d) => ListTile(
                                  leading: const CircleAvatar(child: Icon(Icons.devices_other)),
                                  title: Text(d.name),
                                  subtitle: Text(d.address),
                                  trailing: FilledButton.icon(onPressed: () => _pickAndSend(d), icon: const Icon(Icons.send), label: const Text('Send')),
                                )),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  const Center(child: Text('Fast local transfer • No manual IP required')),
                ],
              ),
            ),
          ),
        ),
      );
}
