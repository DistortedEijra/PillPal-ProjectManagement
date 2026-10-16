import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'bluetooth_service.dart';

class DebugBluetoothPage extends StatefulWidget {
  const DebugBluetoothPage({super.key});

  @override
  State<DebugBluetoothPage> createState() => _DebugBluetoothPageState();
}

class _DebugBluetoothPageState extends State<DebugBluetoothPage> {
  final List<String> _logs = <String>[];
  late StreamSubscription<String> _dataSub;
  late StreamSubscription<bool> _connSub;
  bool _isConnected = false;
  final TextEditingController _customCmd = TextEditingController();

  final List<String> _sampleMedicines = ['Paracetamol', 'Alaxan', 'Eskelan', 'Biotin', 'Planax'];

  @override
  void initState() {
    super.initState();
    _isConnected = BluetoothService().isConnected;
    _dataSub = BluetoothService().dataStream.listen((raw) {
      // Split by newlines to show line-oriented logs
      final chunks = LineSplitter.split(raw);
      for (final line in chunks) {
        _appendLog("RX: $line");
      }
    });
    _connSub = BluetoothService().isConnectedStream.listen((v) {
      if (!mounted) return;
      setState(() {
        _isConnected = v;
      });
      _appendLog(v ? "EVENT: Connected" : "EVENT: Disconnected");
    });
  }

  @override
  void dispose() {
    _dataSub.cancel();
    _connSub.cancel();
    _customCmd.dispose();
    super.dispose();
  }

  void _appendLog(String line) {
    final ts = TimeOfDay.now().format(context);
    setState(() {
      _logs.add("[$ts] $line");
      if (_logs.length > 500) {
        _logs.removeRange(0, _logs.length - 500);
      }
    });
  }

  bool _isSingleCharCmd(String s) {
    if (s.length != 1) return false;
    final ch = s.codeUnitAt(0);
    return (ch >= 65 && ch <= 70) || // A-F
        (ch >= 97 && ch <= 102) ||   // a-f
        ch == 48 || // '0'
        ch == 33 || // '!'
        ch == 63 || // '?'
        ch == 84;   // 'T'
  }

  Future<void> _send(String s) async {
    final bool single = _isSingleCharCmd(s);
    final ok = await BluetoothService().sendSignal(s, appendNewline: !single);
    _appendLog(ok ? "TX: $s" : "TX FAILED: $s");
  }

  Future<void> _ensureConnected() async {
    if (_isConnected) return;
    _appendLog("ACTION: Connecting...");
    final ok = await BluetoothService().connect();
    _appendLog(ok ? "ACTION: Connect OK" : "ACTION: Connect FAILED");
  }

  Future<void> _ensureSampleSchedules(String userId) async {
    final schedulesRef = FirebaseFirestore.instance.collection('users').doc(userId).collection('schedules');
    final batch = FirebaseFirestore.instance.batch();

    for (final medName in _sampleMedicines) {
      final newScheduleRef = schedulesRef.doc();
      batch.set(newScheduleRef, {
        'name': medName,
        'dosage': '1 pill',
        'schedules': [
          {'hour': 8, 'minute': 0}, // 8:00 AM
          {'hour': 20, 'minute': 0}, // 8:00 PM
        ],
        'repeatDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
    _appendLog("ACTION: Created sample schedules for ${_sampleMedicines.join(', ')}");
  }


  Future<void> _injectLogSample(String status) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _appendLog("ERROR: Not logged in");
      return;
    }
    
    _appendLog("ACTION: Ensuring sample schedules exist...");
    // This will create sample schedules if they don't exist, without wiping anything.
    final schedulesRef = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('schedules');
    for (final medName in _sampleMedicines) {
      final query = await schedulesRef.where('name', isEqualTo: medName).limit(1).get();
      if (query.docs.isEmpty) {
        await schedulesRef.add({
          'name': medName, 'dosage': '1 pill', 'schedules': [{'hour': 8, 'minute': 0}],
          'repeatDays': ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'], 'isActive': true, 'createdAt': FieldValue.serverTimestamp(),
        });
      }
    }

    final random = Random();
    final medicineName = _sampleMedicines[random.nextInt(_sampleMedicines.length)];
    
    // Pick a random time from that medicine's schedule (8 AM or 8 PM)
    final hour = random.nextBool() ? 8 : 20;
    final time = TimeOfDay(hour: hour, minute: 0);
    final period = time.hour >= 12 ? 'PM' : 'AM';
    final displayHour = time.hour == 0 ? 12 : time.hour > 12 ? time.hour - 12 : time.hour;
    final timeStr = '$displayHour:00 $period';

    // Inject the log for today
    final now = DateTime.now();
    final dateStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

    try {
      final docRef = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('logs').doc(dateStr);
      await docRef.set({
        'intakes': FieldValue.arrayUnion([{'medicine': medicineName, 'time': timeStr, 'status': status}])
      }, SetOptions(merge: true));
      _appendLog("SUCCESS: Injected '$status' log for $medicineName at $timeStr for today. Please refresh dashboard.");
    } catch (e) {
      _appendLog("ERROR: Log injection failed: $e");
    }
  }

  Future<void> _injectPastData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _appendLog("ERROR: Not logged in");
      return;
    }

    _appendLog("ACTION: Wiping all existing schedules and logs...");
    final schedulesRef = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('schedules');
    final logsRef = FirebaseFirestore.instance.collection('users').doc(user.uid).collection('logs');
    
    // Batch delete all schedules
    WriteBatch batch = FirebaseFirestore.instance.batch();
    var snapshot = await schedulesRef.get();
    for (var doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
    _appendLog("...wiped ${snapshot.size} schedules.");

    // Batch delete all logs
    batch = FirebaseFirestore.instance.batch();
    snapshot = await logsRef.get();
    for (var doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
    _appendLog("...wiped ${snapshot.size} logs.");

    _appendLog("ACTION: Creating new sample schedules...");
    await _ensureSampleSchedules(user.uid);

    _appendLog("ACTION: Injecting past 3 weeks of log data...");
    final now = DateTime.now();
    final random = Random();
    
    final WriteBatch logBatch = FirebaseFirestore.instance.batch();

    // Go back 21 days
    for (int i = 0; i < 21; i++) {
      final date = now.subtract(Duration(days: i));
      final dateStr = "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
      
      List<Map<String, dynamic>> dailyIntakes = [];

      // For each sample medicine, create its 2 scheduled intakes for the day
      for (final medicineName in _sampleMedicines) {
        // 8:00 AM intake
        dailyIntakes.add({
          'medicine': medicineName,
          'time': '8:00 AM',
          'status': random.nextDouble() < 0.8 ? 'on_time' : 'missed',
        });

        // 8:00 PM intake
        bool isToday = date.year == now.year && date.month == now.month && date.day == now.day;
        if (!isToday || (isToday && now.hour >= 20)) {
           dailyIntakes.add({
            'medicine': medicineName,
            'time': '8:00 PM',
            'status': random.nextDouble() < 0.8 ? 'on_time' : 'missed',
          });
        }
      }
      
      final docRef = logsRef.doc(dateStr);
      logBatch.set(docRef, {'intakes': dailyIntakes});
    }

    try {
        await logBatch.commit();
        _appendLog("SUCCESS: Finished injecting past data. Please return to the dashboard.");
    } catch (e) {
        _appendLog("ERROR: Batch log injection failed: $e");
    }
  }


  Widget _buildStatus() {
    return Row(
      children: <Widget>[
        Icon(
          _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
          color: _isConnected ? Colors.green : Colors.red,
        ),
        const SizedBox(width: 8),
        Text(_isConnected ? "Connected" : "Disconnected"),
        const Spacer(),
        FilledButton(
          onPressed: () async {
            if (_isConnected) {
              _appendLog("ACTION: Disconnecting...");
              await BluetoothService().disconnect();
            } else {
              await _ensureConnected();
            }
          },
          child: Text(_isConnected ? "Disconnect" : "Connect"),
        ),
      ],
    );
  }

  Widget _buildGridButtons() {
    final List<_CmdBtn> buttons = <_CmdBtn>[
      _CmdBtn("Blink A", "A"), _CmdBtn("Blink B", "B"), _CmdBtn("Blink C", "C"),
      _CmdBtn("Blink D", "D"), _CmdBtn("Blink E", "E"), _CmdBtn("Blink F", "F"),
      _CmdBtn("On A", "a"), _CmdBtn("On B", "b"), _CmdBtn("On C", "c"),
      _CmdBtn("On D", "d"), _CmdBtn("On E", "e"), _CmdBtn("On F", "f"),
      _CmdBtn("All Off", "0"), _CmdBtn("Stop", "!"), _CmdBtn("Status", "?"),
      _CmdBtn("Test", "T"),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.4,
      ),
      itemCount: buttons.length,
      itemBuilder: (context, index) {
        final b = buttons[index];
        return FilledButton.tonal(
          onPressed: () async {
            await _ensureConnected();
            await _send(b.command);
          },
          child: Text(b.label),
        );
      },
    );
  }

  Widget _buildAdvancedButtons() {
    final List<_CmdBtn> adv = <_CmdBtn>[
      _CmdBtn("BLINK A", "BLINK A"), _CmdBtn("SET B", "SET B"),
      _CmdBtn("OFF", "OFF"), _CmdBtn("STOP", "STOP"),
      _CmdBtn("STATUS", "STATUS"), _CmdBtn("TEST", "TEST"),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: adv.map((b) {
        return OutlinedButton(
          onPressed: () async {
            await _ensureConnected();
            await _send(b.command);
          },
          child: Text(b.label),
        );
      }).toList(),
    );
  }

  Widget _buildDebugButtons() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Debug Actions"),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton(
              onPressed: () => _injectLogSample('on_time'),
              child: const Text("Inject 'On Time' Log"),
            ),
            ElevatedButton(
              onPressed: () => _injectLogSample('missed'),
              child: const Text("Inject 'Missed' Log"),
            ),
            ElevatedButton(
              onPressed: _injectPastData,
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green[700]),
              child: const Text("Inject Past 3 Weeks Data", style: TextStyle(color: Colors.white)),
            ),
          ],
        )
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("PillBox Bluetooth Debug"),
        actions: <Widget>[
          IconButton(
            tooltip: "Request Status",
            onPressed: () async {
              await _ensureConnected();
              await _send("?");
            },
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: "Clear Log",
            onPressed: () => setState(() => _logs.clear()),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildStatus(),
              const SizedBox(height: 12),
              _buildDebugButtons(),
              const SizedBox(height: 12),
              const Text("Quick Commands"),
              const SizedBox(height: 8),
              _buildGridButtons(),
              const SizedBox(height: 12),
              const Text("Advanced Commands"),
              const SizedBox(height: 8),
              _buildAdvancedButtons(),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _customCmd,
                      decoration: const InputDecoration(
                        labelText: "Custom command",
                        hintText: "e.g., BLINK F or a",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      final v = _customCmd.text.trim();
                      if (v.isEmpty) return;
                      await _ensureConnected();
                      await _send(v);
                    },
                    child: const Text("Send"),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text("Log"),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Text(
                          _logs[index],
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CmdBtn {
  final String label;
  final String command;
  _CmdBtn(this.label, this.command);
}
