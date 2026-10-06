import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

const discoveryPort = 40404;
const transferPort = 40405;

void main() => runApp(const PaliaShareApp());

class PaliaShareApp extends StatelessWidget {
  const PaliaShareApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Palia Share',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xff63c9b2), scaffoldBackgroundColor: const Color(0xfff7fbfa)),
    home: const HomePage(),
  );
}

class DeviceInfo {
  final String name;
  final String address;
  DeviceInfo(this.name, this.address);
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _timer;
  final devices = <String, DeviceInfo>{};
  String status = 'Ready to share';
  double progress = 0;
  bool receiving = false;

  @override
  void initState() { super.initState(); _start(); }
  Future<void> _start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, transferPort, shared: true);
      _server!.listen(_handleConnection);
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true, reusePort: true);
      _udp!.broadcastEnabled = true;
      _udp!.listen((event) {
        if (event == RawSocketEvent.read) {
          final d = _udp!.receive();
          if (d == null) return;
          try {
            final m = jsonDecode(utf8.decode(d.data));
            if (m['type'] == 'palia_discovery' && m['name'] != null && m['port'] == transferPort) {
              final ip = d.address.address;
              if (ip != _localIp()) setState(() => devices[ip] = DeviceInfo(m['name'], ip));
            }
          } catch (_) {}
        }
      });
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _announce());
      _announce();
      setState(() => status = 'Nearby devices are ready');
    } catch (e) { setState(() => status = 'Network unavailable: $e'); }
  }
  String _localIp() {
    for (final n in NetworkInterface.listSync(includeLoopback: false, type: InternetAddressType.IPv4)) {
      if (n.addresses.isNotEmpty) return n.addresses.first.address;
    }
    return '';
  }
  void _announce() {
    if (_udp == null) return;
    final msg = utf8.encode(jsonEncode({'type':'palia_discovery','name':Platform.localHostname,'port':transferPort}));
    _udp!.send(msg, InternetAddress('255.255.255.255'), discoveryPort);
  }
  Future<void> _pickAndSend(DeviceInfo device) async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true, withData: false);
    if (result == null || result.files.isEmpty) return;
    try {
      setState(() { status = 'Connecting to ${device.name}…'; progress = 0; });
      final socket = await Socket.connect(device.address, transferPort, timeout: const Duration(seconds: 8));
      final files = result.files.where((f) => f.path != null).toList();
      final header = jsonEncode({'type':'files','files':files.map((f)=>{'name':f.name,'size':File(f.path!).lengthSync()}).toList()}) + '\n';
      socket.write(header); await socket.flush();
      var sent = 0;
      for (final f in files) {
        final file = File(f.path!); final size = await file.length(); var done = 0;
        await for (final chunk in file.openRead()) {
          socket.add(chunk); done += chunk.length; sent += chunk.length;
          setState(() { progress = sent / files.fold<int>(0, (s, x) => s + File(x.path!).lengthSync()); status = 'Sending ${f.name}… ${(done / size * 100).toStringAsFixed(0)}%'; });
        }
      }
      await socket.flush(); await socket.close();
      setState(() { progress = 1; status = 'Transfer complete'; });
    } catch (e) { setState(() => status = 'Transfer failed: $e'); }
  }
  Future<void> _handleConnection(Socket socket) async {
    receiving = true; final chunks = <int>[]; final completer = Completer<void>();
    socket.listen((data) { chunks.addAll(data); if (String.fromCharCodes(chunks.take(2)) == '{\"') {} }, onDone: () async {
      try { await _saveIncoming(Uint8List.fromList(chunks)); } catch (_) {}
      completer.complete();
    }, onError: (_) { if (!completer.isCompleted) completer.complete(); });
    setState(() => status = 'Receiving file…');
    await completer.future;
  }
  Future<void> _saveIncoming(Uint8List data) async {
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save received file', fileName: 'PaliaShare-Received');
    if (path != null) await File(path).writeAsBytes(data);
    if (mounted) setState(() { receiving = false; progress = 1; status = path == null ? 'Transfer cancelled' : 'File received'; });
  }
  @override void dispose() { _timer?.cancel(); _udp?.close(); _server?.close(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Palia Share', style: TextStyle(fontWeight: FontWeight.bold)), actions: [IconButton(onPressed: _announce, icon: const Icon(Icons.refresh)), const SizedBox(width: 8)]),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Padding(padding: const EdgeInsets.all(28), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Palia Share', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4), const Text('Palia Share by PaliaWin Store  •  Developer by Shanpalia'),
      const SizedBox(height: 24),
      Card(child: Padding(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.wifi_tethering, size: 28), const SizedBox(width: 12), Expanded(child: Text(status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))), if (progress > 0 && progress < 1) SizedBox(width: 220, child: LinearProgressIndicator(value: progress))]),
        const SizedBox(height: 20),
        if (devices.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 35), child: Center(child: Text('No nearby Palia Share device found.\nKeep both PCs on the same Wi-Fi network.', textAlign: TextAlign.center)))
        else ...devices.values.map((d) => ListTile(leading: const CircleAvatar(child: Icon(Icons.computer)), title: Text(d.name), subtitle: Text(d.address), trailing: FilledButton.icon(onPressed: () => _pickAndSend(d), icon: const Icon(Icons.send), label: const Text('Send')))),
      ]))),
      const Spacer(),
      const Center(child: Text('Fast local transfer • No manual IP required')),
    ])))),
  );
}
