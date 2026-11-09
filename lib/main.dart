import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:usb_serial/usb_serial.dart';

const bool kSendChecksum = false;

const List<int> kSrc = [0x7F, 0xF0, 0x00, 0x00, 0x00, 0x01];
const List<int> kBcast = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF];

const int lRdmReq = 7, lRdmDisc = 11, lRdmTimeout = 12;

String _h(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
String uidStr(List<int> u) => u.sublist(0, 2).map(_h).join() + ':' + u.sublist(2).map(_h).join();
List<int> u48(int v) => List.generate(6, (i) => (v >> (8 * (5 - i))) & 0xFF);
int toInt(List<int> u) => u.fold(0, (a, b) => (a << 8) | b);

class Fixture {
  final List<int> uid;
  int addr = 0, footprint = 0;
  String mfr = '', model = '', label = '';
  bool identify = false;
  Fixture(this.uid);
}

class Frame {
  final int label;
  final Uint8List data;
  Frame(this.label, this.data);
}

class RdmResp {
  final int type, cc, pid;
  final Uint8List pd;
  RdmResp(this.type, this.cc, this.pid, this.pd);
  bool get ok => type == 0 || type == 1;
}

RdmResp? parseRdm(List<int> d) {
  var s = -1;
  for (var i = 0; i + 1 < d.length; i++) {
    if (d[i] == 0xCC && d[i + 1] == 0x01) {
      s = i;
      break;
    }
  }
  List<int> p;
  if (s >= 0) {
    p = d.sublist(s);
  } else if (d.isNotEmpty && d[0] == 0x01) {
    p = [0xCC, ...d];
  } else {
    return null;
  }
  if (p.length < 24) return null;
  final pdl = p[23];
  if (p.length < 24 + pdl) return null;
  return RdmResp(p[16], p[20], (p[21] << 8) | p[22], Uint8List.fromList(p.sublist(24, 24 + pdl)));
}

List<int>? decodeDub(List<int> d) {
  var i = 0;
  while (i < d.length && d[i] == 0xFE) i++;
  if (i < d.length && d[i] == 0xAA) i++;
  if (d.length - i < 16) return null;
  final e = d.sublist(i, i + 16);
  final uid = List.generate(6, (k) => e[2 * k] & e[2 * k + 1]);
  final cs = ((e[12] & e[13]) << 8) | (e[14] & e[15]);
  var sum = 0;
  for (var k = 0; k < 12; k++) sum += e[k];
  return (sum & 0xFFFF) == cs ? uid : null;
}

class Enttec {
  UsbPort? _port;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _buf = [];
  final _frames = StreamController<Frame>.broadcast();
  int _tn = 0;

  Future<bool> open(UsbDevice d) async {
    await close();
    final p = await d.create();
    if (p == null || !await p.open()) return false;
    await p.setDTR(true);
    await p.setRTS(true);
    await p.setPortParameters(57600, UsbPort.DATABITS_8, UsbPort.STOPBITS_1, UsbPort.PARITY_NONE);
    _port = p;
    _sub = p.inputStream!.listen(_onData);
    return true;
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _port?.close();
    _sub = null;
    _port = null;
    _buf.clear();
  }

  void _onData(Uint8List d) {
    _buf.addAll(d);
    while (true) {
      final s = _buf.indexOf(0x7E);
      if (s < 0) {
        _buf.clear();
        return;
      }
      if (s > 0) _buf.removeRange(0, s);
      if (_buf.length < 5) return;
      final len = _buf[2] | (_buf[3] << 8);
      if (_buf.length < len + 5) return;
      if (_buf[len + 4] != 0xE7) {
        _buf.removeAt(0);
        continue;
      }
      _frames.add(Frame(_buf[1], Uint8List.fromList(_buf.sublist(4, 4 + len))));
      _buf.removeRange(0, len + 5);
    }
  }

  Uint8List _pkt(List<int> dst, int cc, int pid, List<int> pd) {
    final b = <int>[
      0xCC, 0x01, 24 + pd.length, ...dst, ...kSrc, (_tn++) & 0xFF,
      1, 0, 0, 0, cc, pid >> 8, pid & 0xFF, pd.length, ...pd,
    ];
    if (kSendChecksum) {
      final s = b.fold<int>(0, (a, x) => a + x);
      b..add((s >> 8) & 0xFF)..add(s & 0xFF);
    }
    return Uint8List.fromList(b);
  }

  Future<Frame?> _txn(int label, Uint8List data, Set<int> expect, {int ms = 1000}) async {
    final c = Completer<Frame?>();
    final s = _frames.stream.listen((f) {
      if (expect.contains(f.label) && !c.isCompleted) c.complete(f);
    });
    await _port!.write(Uint8List.fromList([0x7E, label, data.length & 0xFF, data.length >> 8, ...data, 0xE7]));
    final r = await c.future.timeout(Duration(milliseconds: ms), onTimeout: () => null);
    await s.cancel();
    return r;
  }

  Future<RdmResp?> get(List<int> uid, int pid) async {
    final f = await _txn(lRdmReq, _pkt(uid, 0x20, pid, []), {lRdmReq, lRdmTimeout});
    if (f == null || f.label == lRdmTimeout) return null;
    final r = parseRdm(f.data);
    return (r != null && r.ok) ? r : null;
  }

  Future<bool> _set(List<int> uid, int pid, List<int> pd) async {
    final f = await _txn(lRdmReq, _pkt(uid, 0x30, pid, pd), {lRdmReq, lRdmTimeout});
    if (f == null || f.label == lRdmTimeout) return false;
    final r = parseRdm(f.data);
    return r != null && r.ok;
  }

  Future<bool> setAddr(List<int> uid, int a) => _set(uid, 0x00F0, [a >> 8, a & 0xFF]);
  Future<bool> identify(List<int> uid, bool on) => _set(uid, 0x1000, [on ? 1 : 0]);

  Future<String> _str(List<int> uid, int pid) async {
    final r = await get(uid, pid);
    if (r == null) return '';
    return ascii.decode(r.pd.where((b) => b >= 32 && b < 127).toList());
  }

  Future<void> readInfo(Fixture f) async {
    final di = await get(f.uid, 0x0060);
    if (di != null && di.pd.length >= 16) {
      f.footprint = (di.pd[10] << 8) | di.pd[11];
      f.addr = (di.pd[14] << 8) | di.pd[15];
    }
    f.mfr = await _str(f.uid, 0x0081);
    f.model = await _str(f.uid, 0x0080);
    f.label = await _str(f.uid, 0x0082);
  }

  Future<List<List<int>>> discover() async {
    final found = <int>[];
    for (var i = 0; i < 2; i++) {
      await _txn(lRdmReq, _pkt(kBcast, 0x10, 0x0003, []), {lRdmReq, lRdmDisc, lRdmTimeout}, ms: 500);
    }
    await _branch(0, 0xFFFFFFFFFFFE, found);
    return found.map(u48).toList();
  }

  Future<void> _branch(int lo, int hi, List<int> out) async {
    final pd = [...u48(lo), ...u48(hi)];
    while (true) {
      final f = await _txn(lRdmDisc, _pkt(kBcast, 0x10, 0x0001, pd), {lRdmDisc, lRdmReq, lRdmTimeout}, ms: 800);
      if (f == null || f.label == lRdmTimeout || f.data.isEmpty) return;
      final uid = decodeDub(f.data);
      if (uid != null) {
        final v = toInt(uid);
        if (out.contains(v)) return;
        await _txn(lRdmReq, _pkt(uid, 0x10, 0x0002, []), {lRdmReq, lRdmTimeout}, ms: 600);
        out.add(v);
        continue;
      }
      if (lo == hi) return;
      final mid = (lo + hi) >> 1;
      await _branch(lo, mid, out);
      await _branch(mid + 1, hi, out);
      return;
    }
  }
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'DMX адрес',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepOrange, brightness: Brightness.dark),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final w = Enttec();
  bool connected = false, busy = false;
  String status = 'USB-DMX интерфейсни OTG орқали уланг ва юқоридаги USB тугмасини босинг';
  List<Fixture> fx = [];

  @override
  void dispose() {
    w.close();
    super.dispose();
  }

  Future<void> _run(String msg, Future<void> Function() job) async {
    setState(() {
      busy = true;
      status = msg;
    });
    try {
      await job();
    } catch (e) {
      status = 'Хато: $e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _connect() => _run('Уланилмоқда...', () async {
        final devs = await UsbSerial.listDevices();
        if (devs.isEmpty) {
          connected = false;
          status = 'USB қурилма топилмади (OTG кабелни текширинг)';
          return;
        }
        connected = await w.open(devs.first);
        status = connected ? 'Уланди: ${devs.first.productName ?? "USB"}' : 'Уланмади (рухсат берилдими?)';
      });

  Future<void> _scan() async {
    if (!connected) {
      setState(() => status = 'Аввал USB\'ни улаш керак');
      return;
    }
    await _run('Скан қилинмоқда... (10–30 сония)', () async {
      fx = [];
      final uids = await w.discover();
      final list = <Fixture>[];
      for (final u in uids) {
        final f = Fixture(u);
        await w.readInfo(f);
        list.add(f);
        if (mounted) setState(() => fx = List.of(list));
      }
      status = list.isEmpty
          ? 'Ҳеч нима топилмади: RDM, кабель, терминатор, интерфейсни текширинг'
          : '${list.length} та светилник топилди';
    });
  }

  Future<int?> _askNum(String title, int init) {
    final c = TextEditingController(text: '$init');
    return showDialog<int>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Бекор')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(c.text)), child: const Text('OK')),
        ],
      ),
    );
  }

  int _fp(Fixture f) => f.footprint < 1 ? 1 : f.footprint;

  Future<void> _edit(Fixture f) async {
    final a = await _askNum('Янги адрес (1–512)', f.addr);
    if (a == null) return;
    if (a < 1 || a + _fp(f) - 1 > 512) {
      setState(() => status = 'Адрес нотўғри: 1–512, каналлар сиғиши керак');
      return;
    }
    await _run('Ёзилмоқда...', () async {
      await w.setAddr(f.uid, a);
      await w.readInfo(f);
      status = f.addr == a ? 'OK: адрес $a' : 'Хато: ҳозирги адрес ${f.addr}';
    });
  }

  Future<void> _setAll() async {
    if (fx.isEmpty) return;
    final start = await _askNum('Бошланғич адрес (кетма-кет берилади)', 1);
    if (start == null || start < 1) return;
    await _run('Ёзилмоқда...', () async {
      var a = start;
      var n = 0;
      for (final f in fx) {
        if (a + _fp(f) - 1 > 512) {
          status = '512 дан ошди, $n та ёзилди';
          return;
        }
        await w.setAddr(f.uid, a);
        await w.readInfo(f);
        a += _fp(f);
        n++;
        if (mounted) setState(() {});
      }
      status = '$n та светилникка адрес ёзилди';
    });
  }

  Future<void> _identify(Fixture f) async {
    final on = !f.identify;
    final ok = await w.identify(f.uid, on);
    setState(() {
      if (ok) f.identify = on;
      status = ok ? (on ? 'Identify ЁНИҚ: ${uidStr(f.uid)}' : 'Identify ўчди') : 'Identify жавоби йўқ';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DMX адрес (RDM)'),
        actions: [
          IconButton(
            icon: Icon(connected ? Icons.usb : Icons.usb_off),
            tooltip: 'Уланиш',
            onPressed: busy ? null : _connect,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: Text(status)),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: fx.isEmpty
                ? const Center(child: Text('Рўйхат бўш. «Скан» ни босинг'))
                : ListView.builder(
                    itemCount: fx.length,
                    itemBuilder: (_, i) {
                      final f = fx[i];
                      final title = f.label.isNotEmpty ? f.label : (f.model.isNotEmpty ? f.model : 'Светилник ${i + 1}');
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: ListTile(
                          isThreeLine: true,
                          leading: CircleAvatar(radius: 26, child: Text('${f.addr}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
                          title: Text(title),
                          subtitle: Text('${f.mfr} ${f.model}\nUID ${uidStr(f.uid)} · ${f.footprint} канал'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                              icon: Icon(f.identify ? Icons.lightbulb : Icons.lightbulb_outline),
                              tooltip: 'Identify',
                              onPressed: busy ? null : () => _identify(f),
                            ),
                            IconButton(icon: const Icon(Icons.edit), tooltip: 'Адрес ёзиш', onPressed: busy ? null : () => _edit(f)),
                          ]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: FilledButton.icon(onPressed: busy ? null : _scan, icon: const Icon(Icons.search), label: const Text('Скан'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: busy || fx.isEmpty ? null : _setAll, icon: const Icon(Icons.format_list_numbered), label: const Text('Кетма-кет'))),
          ]),
        ),
      ),
    );
  }
}
