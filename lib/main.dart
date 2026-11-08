import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

typedef Doc = DocumentReference<Map<String, dynamic>>;
final db = FirebaseFirestore.instance;
String get myUid => FirebaseAuth.instance.currentUser!.uid;
const rtcConfig = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {
      'urls': 'turn:openrelay.metered.ca:80',
      'username': 'openrelayproject',
      'credential': 'openrelayproject'
    },
    {
      'urls': 'turn:openrelay.metered.ca:443',
      'username': 'openrelayproject',
      'credential': 'openrelayproject'
    },
  ]
};

Future<void> wipeIce(Doc pair, String sid) async {
  final docs = await pair.collection('ice').where('sid', isEqualTo: sid).get();
  for (final d in docs.docs) {
    d.reference.delete();
  }
}
Doc pairDoc(String code) => db.collection('pairs').doc(code);

StreamSubscription listenIce(Doc pair, String sid, RTCPeerConnection pc, String other) {
  return pair.collection('ice').where('sid', isEqualTo: sid).snapshots().listen((s) {
    for (final ch in s.docChanges) {
      final d = ch.doc.data();
      if (ch.type == DocumentChangeType.added && d != null && d['from'] == other) {
        final c = Map<String, dynamic>.from(d['c']);
        try {
          pc.addCandidate(RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']));
        } catch (_) {}
      }
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'syl_service',
      channelName: 'SYL',
      channelDescription: 'Shows that SYL is available to your partner',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
      enableVibration: true,
      playSound: false,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 60000, autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true),
  );
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  runApp(const SylApp());
}

class SylApp extends StatelessWidget {
  const SylApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SYL',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.pinkAccent, brightness: Brightness.dark),
            useMaterial3: true),
        home: const Gate(),
      );
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> with WidgetsBindingObserver {
  bool? cam;
  String? code, name;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) check();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    code = p.getString('code');
    name = p.getString('name');
    await check();
  }

  Future<void> check() async {
    final st = await Permission.camera.status;
    if (mounted) setState(() => cam = st.isGranted);
  }

  Future<void> ask() async {
    final st = await Permission.camera.request();
    if (st.isPermanentlyDenied) await openAppSettings();
    await check();
  }

  Future<void> save(String n, String c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('name', n);
    await p.setString('code', c);
    setState(() {
      name = n;
      code = c;
    });
  }

  Future<void> leave() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('code');
    setState(() => code = null);
  }

  @override
  Widget build(BuildContext context) {
    if (cam == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (cam == false) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('SYL', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.pinkAccent)),
              const SizedBox(height: 16),
              const Text(
                  'SYL needs camera permission to work. Your camera is only used while this app is open on your screen, and you are always notified when someone looks.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(onPressed: ask, child: const Text('Allow camera')),
            ]),
          ),
        ),
      );
    }
    if (code == null) return Setup(onSave: save, initialName: name);
    return Home(code: code!, name: name!, onLeave: leave);
  }
}

class Setup extends StatefulWidget {
  final Future<void> Function(String, String) onSave;
  final String? initialName;
  const Setup({super.key, required this.onSave, this.initialName});
  @override
  State<Setup> createState() => _SetupState();
}

class _SetupState extends State<Setup> {
  late final n = TextEditingController(text: widget.initialName);
  final c = TextEditingController();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('SYL', style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.pinkAccent)),
              const SizedBox(height: 20),
              TextField(controller: n, decoration: const InputDecoration(labelText: 'Your name')),
              const SizedBox(height: 12),
              TextField(
                  controller: c,
                  decoration: const InputDecoration(
                      labelText: 'Secret code (same on both phones)', helperText: 'Use something long and private')),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: () {
                    if (n.text.trim().isNotEmpty && c.text.trim().length >= 6) {
                      widget.onSave(n.text.trim(), c.text.trim());
                    }
                  },
                  child: const Text('Continue')),
            ]),
          ),
        ),
      );
}

class Home extends StatefulWidget {
  final String code, name;
  final VoidCallback onLeave;
  const Home({super.key, required this.code, required this.name, required this.onLeave});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  late final Doc pair = pairDoc(widget.code);
  Timer? beat;
  StreamSubscription? sessionSub, iceSub;
  RTCPeerConnection? pc;
  MediaStream? local;
  String? sid, viewer;
  bool fg = true;
  bool bg = false;
  bool talking = false;

  Future<void> startFg() async {
    await FlutterForegroundTask.startService(
        notificationTitle: 'SYL is on',
        notificationText: 'Your partner can look when they tap your name. Open SYL to turn off.');
  }

  Future<void> setBg(bool on) async {
    if (on) {
      await Permission.notification.request();
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      await startFg();
    } else {
      await FlutterForegroundTask.stopService();
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool('bg', on);
    if (mounted) setState(() => bg = on);
  }

  Future<void> setOnline(bool on) => pair
      .collection('members')
      .doc(myUid)
      .set({'name': widget.name, 'online': on, 'ts': FieldValue.serverTimestamp()}, SetOptions(merge: true));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    start();
    SharedPreferences.getInstance().then((p) {
      if (p.getBool('bg') == true) {
        startFg();
        if (mounted) setState(() => bg = true);
      }
    });
  }

  void start() {
    setOnline(true);
    beat?.cancel();
    beat = Timer.periodic(const Duration(seconds: 20), (_) => setOnline(true));
    sessionSub?.cancel();
    sessionSub = pair.collection('sessions').doc(myUid).snapshots().listen(onSession);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      fg = true;
      start();
    } else if (s == AppLifecycleState.paused && !bg) {
      fg = false;
      beat?.cancel();
      sessionSub?.cancel();
      stopShare(deleteDoc: true);
      setOnline(false);
    }
  }

  Future<void> onSession(DocumentSnapshot<Map<String, dynamic>> snap) async {
    if (!snap.exists) {
      await stopShare();
      return;
    }
    final d = snap.data()!;
    if (d['sid'] == sid) {
      final m = d['mic'] == true;
      if (m != talking) {
        if (mounted) setState(() => talking = m);
        if (bg) {
          FlutterForegroundTask.updateService(
              notificationTitle: '💗 $viewer is looking at you${m ? ' · 🎤 speaking' : ''}',
              notificationText: 'Open SYL to stop.');
        }
        if (m) HapticFeedback.mediumImpact();
      }
      return;
    }
    if (!fg || d['answer'] != null) return;
    await startShare(d);
  }

  Future<void> startShare(Map<String, dynamic> d) async {
    await stopShare();
    sid = d['sid'];
    if (mounted) setState(() => viewer = d['viewerName']);
    HapticFeedback.heavyImpact();
    if (bg) {
      FlutterForegroundTask.updateService(
          notificationTitle: '💗 ${d['viewerName']} is looking at you', notificationText: 'Open SYL to stop.');
    }
    final mySid = sid!;
    local = await navigator.mediaDevices.getUserMedia({'audio': false, 'video': {'facingMode': 'user'}});
    final conn = await createPeerConnection(rtcConfig);
    pc = conn;
    await Helper.setSpeakerphoneOn(true);
    for (final t in local!.getTracks()) {
      conn.addTrack(t, local!);
    }
    conn.onIceCandidate = (c) {
      if (c.candidate != null) pair.collection('ice').add({'sid': mySid, 'from': 'target', 'c': c.toMap()});
    };
    final o = Map<String, dynamic>.from(d['offer']);
    await conn.setRemoteDescription(RTCSessionDescription(o['sdp'], o['type']));
    iceSub = listenIce(pair, mySid, conn, 'viewer');
    final a = await conn.createAnswer();
    await conn.setLocalDescription(a);
    await pair.collection('sessions').doc(myUid).update({
      'answer': {'sdp': a.sdp, 'type': a.type}
    });
  }

  Future<void> stopShare({bool deleteDoc = false}) async {
    iceSub?.cancel();
    iceSub = null;
    for (final t in local?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    await local?.dispose();
    await pc?.close();
    local = null;
    pc = null;
    if (sid != null) wipeIce(pair, sid!);
    sid = null;
    talking = false;
    if (deleteDoc) pair.collection('sessions').doc(myUid).delete();
    if (viewer != null && bg) {
      FlutterForegroundTask.updateService(
          notificationTitle: 'SYL is on',
          notificationText: 'Your partner can look when they tap your name. Open SYL to turn off.');
    }
    if (mounted && viewer != null) setState(() => viewer = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    beat?.cancel();
    sessionSub?.cancel();
    stopShare(deleteDoc: true);
    setOnline(false);
    super.dispose();
  }

  Widget tag(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data();
    final ts = (m['ts'] as Timestamp?)?.toDate();
    final on = m['online'] == true && ts != null && DateTime.now().difference(ts).inSeconds < 70;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(18),
        leading: Icon(Icons.circle, size: 14, color: on ? Colors.greenAccent : Colors.grey),
        title: Text(m['name'] ?? '?', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        subtitle: Text(on ? 'Tap to look' : 'App not open right now'),
        trailing: const Icon(Icons.videocam),
        onTap: on
            ? () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => ViewScreen(pair: pair, targetUid: d.id, targetName: m['name'] ?? '?', myName: widget.name)))
            : () => ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Their SYL app is not open right now.'))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('SYL', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.pinkAccent)),
                const Spacer(),
                IconButton(
                    icon: const Icon(Icons.logout),
                    onPressed: () {
                      FlutterForegroundTask.stopService();
                      SharedPreferences.getInstance().then((p) => p.setBool('bg', false));
                      setOnline(false);
                      widget.onLeave();
                    }),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Stay available in background'),
                subtitle: const Text(
                    'Shows a permanent notification and keeps working even after you close the app. Turn it off, force-stop SYL in Android Settings, or restart the phone to end it.'),
                value: bg,
                onChanged: setBg,
              ),
              if (viewer != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.pinkAccent, borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    Expanded(
                        child: Text('💗 $viewer is looking at you${talking ? ' · 🎤 speaking' : ''}',
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white))),
                    TextButton(
                        onPressed: () async {
                          await pair.collection('sessions').doc(myUid).delete();
                          await stopShare();
                        },
                        child: const Text('Stop', style: TextStyle(color: Colors.white))),
                  ]),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: pair.collection('members').snapshots(),
                  builder: (c, s) {
                    final docs = (s.data?.docs ?? []).where((d) => d.id != myUid).toList();
                    if (docs.isEmpty) {
                      return const Center(
                          child: Text('Waiting for your person to join with the same code.', textAlign: TextAlign.center));
                    }
                    return ListView(children: docs.map(tag).toList());
                  },
                ),
              ),
              Text('Signed in as ${widget.name}', style: const TextStyle(color: Colors.grey)),
            ]),
          ),
        ),
      );
}

class ViewScreen extends StatefulWidget {
  final Doc pair;
  final String targetUid, targetName, myName;
  const ViewScreen(
      {super.key, required this.pair, required this.targetUid, required this.targetName, required this.myName});
  @override
  State<ViewScreen> createState() => _ViewScreenState();
}

class _ViewScreenState extends State<ViewScreen> {
  final renderer = RTCVideoRenderer();
  RTCPeerConnection? pc;
  StreamSubscription? sessSub, iceSub;
  Timer? timeout;
  late final Doc ref = widget.pair.collection('sessions').doc(widget.targetUid);
  String status = 'Connecting…';
  bool live = false, answered = false, mic = false;
  RTCRtpSender? micSender;
  MediaStream? micStream;

  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    try {
      await renderer.initialize();
      final conn = await createPeerConnection(rtcConfig);
      pc = conn;
      await conn.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
      final at = await conn.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly));
      micSender = at.sender;
      conn.onTrack = (e) {
        if (e.streams.isNotEmpty && mounted) {
          renderer.srcObject = e.streams[0];
          setState(() => live = true);
        }
      };
      final sid = DateTime.now().microsecondsSinceEpoch.toString();
      mySid = sid;
      conn.onIceCandidate = (c) {
        if (c.candidate != null) widget.pair.collection('ice').add({'sid': sid, 'from': 'viewer', 'c': c.toMap()});
      };
      final offer = await conn.createOffer();
      await conn.setLocalDescription(offer);
      await ref.set({
        'sid': sid,
        'viewerName': widget.myName,
        'offer': {'sdp': offer.sdp, 'type': offer.type},
        'ts': FieldValue.serverTimestamp(),
      });
      sessSub = ref.snapshots().listen((s) async {
        if (!s.exists) {
          if (mounted) setState(() {
            live = false;
            status = '${widget.targetName} stopped sharing.';
          });
          return;
        }
        final a = s.data()!['answer'];
        if (a != null && !answered) {
          answered = true;
          timeout?.cancel();
          await conn.setRemoteDescription(RTCSessionDescription(a['sdp'], a['type']));
          iceSub = listenIce(widget.pair, sid, conn, 'target');
        }
      });
      timeout = Timer(const Duration(seconds: 20), () {
        if (!answered && mounted) setState(() => status = 'No response. Their app may have closed.');
      });
    } catch (e) {
      if (mounted) setState(() => status = 'Could not connect: $e');
    }
  }

  Future<void> stopMic() async {
    for (final t in micStream?.getTracks() ?? <MediaStreamTrack>[]) {
      t.stop();
    }
    await micStream?.dispose();
    micStream = null;
  }

  Future<void> toggleMic() async {
    if (micSender == null) return;
    final next = !mic;
    if (next) {
      final st = await Permission.microphone.request();
      if (!st.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Microphone permission is needed to speak.')));
        }
        return;
      }
      micStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
      await micSender!.replaceTrack(micStream!.getAudioTracks().first);
    } else {
      await micSender!.replaceTrack(null);
      await stopMic();
    }
    if (mounted) setState(() => mic = next);
    try {
      await ref.update({'mic': next});
    } catch (_) {}
  }

  String? mySid;

  @override
  void dispose() {
    stopMic();
    timeout?.cancel();
    sessSub?.cancel();
    iceSub?.cancel();
    ref.delete();
    if (mySid != null) wipeIce(widget.pair, mySid!);
    pc?.close();
    renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.targetName)),
        floatingActionButton: live
            ? FloatingActionButton.extended(
                onPressed: toggleMic,
                backgroundColor: mic ? Colors.pinkAccent : null,
                icon: Icon(mic ? Icons.mic : Icons.mic_off),
                label: Text(mic ? 'Mic ON · tap to mute' : 'Mic off · tap to speak'),
              )
            : null,
        body: live
            ? RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover, mirror: true)
            : Center(child: Text(status, textAlign: TextAlign.center)),
      );
}
