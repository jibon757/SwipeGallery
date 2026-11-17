import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:just_audio/just_audio.dart';

const port = 8080;
const leadMs = 400; // প্লে চাপার পর সবাই একসাথে ধরার জন্য এটুকু অপেক্ষা
int nowUs() => DateTime.now().microsecondsSinceEpoch;
Duration ms(int v) => Duration(milliseconds: v < 0 ? 0 : v);

void main() => runApp(MaterialApp(
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const Home(),
    ));

class Home extends StatelessWidget {
  const Home({super.key});
  void go(BuildContext c, bool host) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => Room(host: host)));
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Hotspot Music')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(onPressed: () => go(c, true), child: const Text('Host — আমি গান চালাব')),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: () => go(c, false), child: const Text('Join — গান শুনব')),
          ]),
        ),
      );
}

class Peer {
  final WebSocket ws;
  final String ip;
  String name;
  Peer(this.ws, this.ip) : name = 'ফোন ${ip.split('.').last}';
}

class Room extends StatefulWidget {
  final bool host;
  const Room({super.key, required this.host});
  @override
  State<Room> createState() => _RoomState();
}

class _RoomState extends State<Room> {
  final player = AudioPlayer();
  final ipCtl = TextEditingController();
  final nameCtl = TextEditingController();
  final peers = <Peer>[];
  final ready = <Peer>{};
  final offByIp = <String, int>{}; // হোস্ট প্রতিটি ফোনের জন্য যে ms ঠিক করেছে (+ = এগিয়ে)
  HttpServer? server;
  WebSocket? ws;
  String? path, name, haveName;
  int? haveSize;
  String status = '', hostIp = '';
  int offset = 0, best = 1 << 60; // hostTime = localTime + offset (microseconds)
  int hostOff = 0; // হোস্টের নিজের ফোনের অ্যাডজাস্ট (+ এগিয়ে, − দেরিতে)
  int adv = 0; // ক্লায়েন্ট: হোস্ট যা ঠিক করে দিয়েছে
  bool busy = false, up = false;
  bool get host => widget.host;

  void say(String s) {
    if (mounted) setState(() => status = s);
  }

  @override
  void initState() {
    super.initState();
    if (host) {
      startHost();
    } else {
      guessIp().then((v) => ipCtl.text = v);
    }
  }

  @override
  void dispose() {
    FlutterForegroundTask.stopService();
    server?.close(force: true);
    ws?.close();
    player.dispose();
    super.dispose();
  }

  // স্ক্রিন অফ/লক হলেও যাতে অ্যাপ, গান ও কানেকশন চালু থাকে
  Future<void> keepAlive() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'hotspot_music',
        channelName: 'Hotspot Music',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    await FlutterForegroundTask.requestNotificationPermission();
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Hotspot Music',
      notificationText: host ? 'হোস্ট চলছে' : 'হোস্টের সাথে যুক্ত',
    );
  }

  Future<List<String>> myIps() async {
    final l = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [for (final i in l) for (final a in i.addresses) a.address];
  }

  Future<String> guessIp() async {
    for (final a in await myIps()) {
      if (a.startsWith('192.168.')) return '${a.substring(0, a.lastIndexOf('.'))}.1';
    }
    return '192.168.43.1';
  }

  void send(Map m) {
    final s = jsonEncode(m);
    for (final p in peers) {
      try {
        p.ws.add(s);
      } catch (_) {}
    }
  }

  Map fileMap() => {'t': 'file', 'name': name, 'size': File(path!).lengthSync()};

  // ---------------- HOST ----------------
  Future<void> startHost() async {
    await keepAlive();
    server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final ips = await myIps();
    say('হটস্পট অন রাখো। বন্ধুরা এই IP দিয়ে Join করবে: ${ips.join(', ')}');
    Timer.periodic(const Duration(seconds: 3), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (player.playing && !busy) {
        // রেফারেন্স পজিশন = হোস্টের পজিশন − হোস্টের নিজের অ্যাডজাস্ট
        send({'t': 'sync', 'at': nowUs(), 'pos': refPos()});
      }
    });
    server!.listen((req) async {
      final p = req.uri.path;
      if (p == '/ws') {
        final ip = req.connectionInfo?.remoteAddress.address ?? '?';
        final s = await WebSocketTransformer.upgrade(req);
        final peer = Peer(s, ip);
        peers.add(peer);
        s.add(jsonEncode({'t': 'adv', 'v': offByIp[ip] ?? 0}));
        if (path != null) s.add(jsonEncode(fileMap()));
        s.listen((raw) {
          final m = jsonDecode(raw as String) as Map;
          if (m['t'] == 'ping') {
            s.add(jsonEncode({'t': 'pong', 'c': m['c'], 'h': nowUs()}));
          } else if (m['t'] == 'ready') {
            if (mounted) {
              setState(() {
                ready.add(peer);
              });
            }
          } else if (m['t'] == 'hello') {
            final n = (m['name'] as String).trim();
            if (n.isNotEmpty && mounted) {
              setState(() {
                peer.name = n;
              });
            }
          }
        }, onDone: () {
          peers.remove(peer);
          if (mounted) {
            setState(() {
              ready.remove(peer);
            });
          }
        });
        if (mounted) setState(() {});
      } else if (p == '/file' && path != null) {
        final f = File(path!);
        req.response.contentLength = await f.length();
        await req.response.addStream(f.openRead());
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  }

  int refPos() => player.position.inMilliseconds - hostOff;

  Future<void> pick() async {
    final r = await FilePicker.platform.pickFiles();
    final f = r?.files.single;
    if (f?.path == null) return;
    hostPause();
    path = f!.path;
    name = f.name;
    ready.clear();
    await player.setFilePath(path!);
    say('ফাইল: $name — বন্ধুদের ফোনে যাচ্ছে');
    send(fileMap());
  }

  void hostPlay({int? pos}) {
    final p = pos ?? refPos();
    final at = nowUs() + leadMs * 1000;
    send({'t': 'play', 'at': at, 'pos': p});
    startAt(at, p + hostOff);
    say('চলছে');
  }

  void hostPause() {
    player.pause();
    send({'t': 'pause'});
  }

  void jump(int s) => hostPlay(pos: refPos() + s * 1000);

  void setHostOff(int v) {
    final d = v - hostOff;
    setState(() => hostOff = v);
    if (player.playing) player.seek(ms(player.position.inMilliseconds + d));
  }

  void setPeer(Peer p, int v) {
    setState(() => offByIp[p.ip] = v);
    try {
      p.ws.add(jsonEncode({'t': 'adv', 'v': v}));
    } catch (_) {}
  }

  // ---------------- CLIENT ----------------
  Future<void> join() async {
    hostIp = ipCtl.text.trim();
    await keepAlive();
    await connect();
  }

  Future<void> connect() async {
    if (!mounted) return;
    try {
      final s = await WebSocket.connect('ws://$hostIp:$port/ws').timeout(const Duration(seconds: 5));
      ws = s;
      up = true;
      s.listen(onMsg, onError: (_) {}, onDone: () {
        say('কানেকশন কেটে গেছে, আবার চেষ্টা হচ্ছে...');
        Future.delayed(const Duration(seconds: 2), connect);
      });
      s.add(jsonEncode({'t': 'hello', 'name': nameCtl.text}));
      say('কানেক্ট হয়েছে। হোস্টের গানের অপেক্ষা...');
      syncClock();
    } catch (e) {
      if (up) {
        Future.delayed(const Duration(seconds: 2), connect);
      } else {
        say('কানেক্ট হয়নি। IP ঠিক আছে? হটস্পটে কানেক্টেড আছ?');
      }
    }
  }

  Future<void> syncClock() async {
    best = 1 << 60;
    for (var i = 0; i < 10; i++) {
      ws?.add(jsonEncode({'t': 'ping', 'c': nowUs()}));
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  void onMsg(dynamic raw) {
    final m = jsonDecode(raw as String) as Map;
    final t = m['t'];
    if (t == 'pong') {
      final c1 = nowUs();
      final rtt = c1 - (m['c'] as int);
      if (rtt < best) {
        best = rtt;
        offset = (m['h'] as int) + rtt ~/ 2 - c1;
      }
    } else if (t == 'adv') {
      setAdv(m['v'] as int);
    } else if (t == 'file') {
      if (path != null && m['name'] == haveName && m['size'] == haveSize) {
        ws?.add(jsonEncode({'t': 'ready'}));
      } else {
        download(m['name'] as String, m['size'] as int);
      }
    } else if (t == 'play') {
      syncClock();
      startAt(m['at'] as int, (m['pos'] as int) + adv);
    } else if (t == 'pause') {
      player.pause();
    } else if (t == 'sync') {
      onSync(m);
    }
  }

  void setAdv(int v) {
    if (!mounted) return;
    final d = v - adv;
    setState(() => adv = v);
    if (player.playing) player.seek(ms(player.position.inMilliseconds + d));
  }

  Future<void> download(String fname, int size) async {
    try {
      path = null;
      final ext = fname.contains('.') ? fname.substring(fname.lastIndexOf('.')) : '';
      final f = File('${Directory.systemTemp.path}/track${DateTime.now().millisecondsSinceEpoch}$ext');
      final req = await HttpClient().getUrl(Uri.parse('http://$hostIp:$port/file'));
      final res = await req.close();
      final sink = f.openWrite();
      var got = 0;
      await for (final c in res) {
        sink.add(c);
        got += c.length;
        say('ডাউনলোড হচ্ছে ${got * 100 ~/ (size == 0 ? 1 : size)}%');
      }
      await sink.close();
      await player.setFilePath(f.path);
      path = f.path;
      haveName = fname;
      haveSize = size;
      ws?.add(jsonEncode({'t': 'ready'}));
      say('তৈরি ✔ — হোস্টের প্লে চাপার অপেক্ষা');
    } catch (e) {
      say('ডাউনলোডে সমস্যা: $e');
    }
  }

  // দেরিতে জয়েন করলে বা সরে গেলে নিজে ঠিক করে নেয়
  Future<void> onSync(Map m) async {
    if (busy || path == null) return;
    final want = (m['pos'] as int) + (nowUs() + offset - (m['at'] as int)) ~/ 1000 + adv;
    if (!player.playing) {
      await player.seek(ms(want));
      player.play();
    } else if ((player.position.inMilliseconds - want).abs() > 60) {
      await player.seek(ms(want));
    }
  }

  // ---------------- SHARED: নির্দিষ্ট সময়ে একসাথে প্লে ----------------
  Future<void> startAt(int atHost, int posMs) async {
    if (path == null) return;
    if (posMs < 0) {
      atHost -= posMs * 1000; // গানের শুরুর আগের অংশ = একটু দেরিতে শুরু
      posMs = 0;
    }
    busy = true;
    await player.pause();
    var left = atHost - offset - nowUs();
    await player.seek(ms(posMs + (left < 0 ? -left ~/ 1000 : 0)));
    for (;;) {
      left = atHost - offset - nowUs();
      if (left <= 0) break;
      if (left > 40000) await Future.delayed(const Duration(milliseconds: 10));
    }
    player.play();
    busy = false;
  }

  Widget slider(String label, int v, void Function(int) set) => Column(children: [
        Text('$label: ${v > 0 ? '+' : ''}$v ms'),
        Slider(
          value: v.toDouble(),
          min: -1000,
          max: 1000,
          divisions: 40,
          label: '${v > 0 ? '+' : ''}$v ms',
          onChanged: (x) => set(x.round()),
        ),
      ]);

  @override
  Widget build(BuildContext c) {
    final ok = path != null;
    return Scaffold(
      appBar: AppBar(title: Text(host ? 'Host' : 'Join')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(children: [
          Text(status),
          const SizedBox(height: 16),
          if (host) ...[
            FilledButton(onPressed: pick, child: const Text('গান / ভিডিও বাছো')),
            const SizedBox(height: 8),
            Text('কানেক্টেড: ${peers.length}   তৈরি: ${ready.length}'),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: ok ? () => jump(-10) : null, icon: const Icon(Icons.replay_10)),
              IconButton.filled(onPressed: ok ? hostPlay : null, icon: const Icon(Icons.play_arrow)),
              IconButton.filled(onPressed: ok ? hostPause : null, icon: const Icon(Icons.pause)),
              IconButton(onPressed: ok ? () => jump(10) : null, icon: const Icon(Icons.forward_10)),
            ]),
            const SizedBox(height: 12),
            const Text('+ মানে ওই ফোন এগিয়ে (আগে) বাজবে, − মানে দেরিতে বাজবে'),
            slider('আমার (হোস্ট) ফোন', hostOff, setHostOff),
            for (final p in peers) slider(p.name, offByIp[p.ip] ?? 0, (v) => setPeer(p, v)),
          ] else if (!up) ...[
            TextField(controller: nameCtl, decoration: const InputDecoration(labelText: 'তোমার নাম (ঐচ্ছিক)')),
            TextField(controller: ipCtl, decoration: const InputDecoration(labelText: 'হোস্টের IP')),
            const SizedBox(height: 8),
            FilledButton(onPressed: join, child: const Text('Connect')),
          ] else
            Text('হোস্ট তোমার ফোনের সময় ঠিক করে দেবে। এখন: ${adv > 0 ? '+' : ''}$adv ms'),
        ]),
      ),
    );
  }
}
