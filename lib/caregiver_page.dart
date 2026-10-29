import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'caregiver_service.dart';
import 'medicine_editor.dart';
import 'reminder_chat_page.dart';
import 'time_utils.dart';

const Color _brand = Color(0xFF116FA9);

/// Caregiver Companion Mode.
/// Tab 1 (patient): invite a caregiver with a code, see/remove linked caregivers.
/// Tab 2 (caregiver): enter a code, see the patients you monitor.
class CaregiverPage extends StatefulWidget {
  const CaregiverPage({super.key});

  @override
  State<CaregiverPage> createState() => _CaregiverPageState();
}

class _CaregiverPageState extends State<CaregiverPage> {
  final CaregiverService _service = CaregiverService();
  final TextEditingController _codeController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _err(Object e) => e.toString().replaceFirst('Exception: ', '');

  Future<void> _createInvite() async {
    setState(() => _busy = true);
    try {
      final code = await _service.createInviteCode();
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Your invite code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                code,
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold, letterSpacing: 6, color: _brand),
              ),
              const SizedBox(height: 12),
              const Text(
                'Give this code to your caregiver. On their phone, they open Care → "Patients I monitor" and enter it.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    } catch (e) {
      _snack('Could not create code: ${_err(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _link() async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final name = await _service.linkWithCode(_codeController.text);
      _codeController.clear();
      _snack('You are now monitoring $name.');
    } catch (e) {
      _snack(_err(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF1F5F9),
        appBar: AppBar(
          backgroundColor: _brand,
          foregroundColor: Colors.white,
          title: const Text('Caregiver Companion'),
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [Tab(text: 'My caregivers'), Tab(text: 'Patients I monitor')],
          ),
        ),
        body: Stack(
          children: [
            TabBarView(children: [_myCaregiversTab(), _patientsTab()]),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _myCaregiversTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Let a family member or nurse see your doses and get alerts when you miss one.',
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: _busy ? null : _createInvite,
          icon: const Icon(Icons.person_add),
          label: const Text('Create invite code'),
          style: ElevatedButton.styleFrom(backgroundColor: _brand, foregroundColor: Colors.white),
        ),
        const SizedBox(height: 20),
        const Text('Linked caregivers', style: TextStyle(fontWeight: FontWeight.bold)),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _service.myCaregivers(),
          builder: (context, snap) {
            if (snap.hasError) return _errorText(snap.error);
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('No caregivers yet.', style: TextStyle(color: Colors.grey)),
              );
            }
            return Column(
              children: docs.map((d) {
                final data = d.data();
                final caregiverName = (data['name'] as String?) ?? 'Caregiver';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.health_and_safety, color: _brand),
                    title: Text(caregiverName),
                    subtitle: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: _service.reminderChat(_service.myUid, d.id),
                      builder: (context, chat) {
                        final pending = chat.data?.docs.where((m) => m.data()['done'] != true).length ?? 0;
                        if (pending == 0) return const Text('Tap to open reminders');
                        return Text(
                          '$pending reminder${pending == 1 ? '' : 's'} waiting for Done',
                          style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                        );
                      },
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ReminderChatPage(
                          patientUid: _service.myUid,
                          caregiverUid: d.id,
                          title: 'Reminders from $caregiverName',
                          isCaregiver: false,
                        ),
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        if (await _confirm('Remove caregiver?', 'They will stop seeing your doses and alerts.')) {
                          await _service.removeCaregiver(d.id);
                        }
                      },
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _patientsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          "Enter the 6-character code from the patient's PillPal app.",
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _codeController,
                textCapitalization: TextCapitalization.characters,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Invite code',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _busy ? null : _link,
              style: ElevatedButton.styleFrom(
                backgroundColor: _brand,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              ),
              child: const Text('Link'),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Patients', style: TextStyle(fontWeight: FontWeight.bold)),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _service.myPatients(),
          builder: (context, snap) {
            if (snap.hasError) return _errorText(snap.error);
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            final docs = snap.data!.docs;
            if (docs.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Text('You are not monitoring anyone yet.', style: TextStyle(color: Colors.grey)),
              );
            }
            return Column(
              children: docs.map((d) {
                final name = (d.data()['name'] as String?) ?? 'Patient';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.person, color: _brand),
                    title: Text(name),
                    subtitle: const Text('Tap to see doses and alerts'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PatientMonitorPage(patientUid: d.id, patientName: name)),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.link_off),
                      onPressed: () async {
                        if (await _confirm('Stop monitoring?', 'You will no longer see $name\'s doses.')) {
                          await _service.unlinkPatient(d.id);
                        }
                      },
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

Widget _errorText(Object? e) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'Could not load: $e\nIf this says "permission-denied", publish firestore.rules in the Firebase console.',
        style: const TextStyle(color: Colors.red),
      ),
    );

/// What a caregiver sees for one patient: today's doses, last 7 days, alerts.
class PatientMonitorPage extends StatelessWidget {
  final String patientUid;
  final String patientName;

  const PatientMonitorPage({super.key, required this.patientUid, required this.patientName});

  void _openChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReminderChatPage(
          patientUid: patientUid,
          caregiverUid: CaregiverService().myUid,
          title: 'Reminders to $patientName',
          isCaregiver: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = CaregiverService();
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(backgroundColor: _brand, foregroundColor: Colors.white, title: Text(patientName)),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openChat(context),
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.chat),
        label: const Text('Reminders chat'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: service.schedulesOf(patientUid),
        builder: (context, schedSnap) {
          if (schedSnap.hasError) return Padding(padding: const EdgeInsets.all(16), child: _errorText(schedSnap.error));
          if (!schedSnap.hasData) return const Center(child: CircularProgressIndicator());
          final activeDocs = schedSnap.data!.docs.where((d) => d.data()['isActive'] != false).toList();
          final schedules = activeDocs.map((d) => d.data()).toList();

          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: service.logsOf(patientUid),
            builder: (context, logSnap) {
              if (logSnap.hasError) return Padding(padding: const EdgeInsets.all(16), child: _errorText(logSnap.error));
              if (!logSnap.hasData) return const Center(child: CircularProgressIndicator());
              final logs = {for (final d in logSnap.data!.docs) d.id: d.data()};

              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  _todayCard(schedules, logs),
                  _medicinesCard(context, activeDocs),
                  _weekCard(logs),
                  _alertsCard(service),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _todayCard(List<Map<String, dynamic>> schedules, Map<String, Map<String, dynamic>> logs) {
    final now = DateTime.now();
    final today = kDaysOfWeek[now.weekday - 1];
    final intakes = (logs[dateKey(now)]?['intakes'] as List?) ?? [];
    final rows = <Map<String, dynamic>>[];

    for (final s in schedules) {
      final days = ((s['repeatDays'] as List?) ?? []).cast<String>();
      if (!days.contains(today)) continue;
      if (!runsOn(s['endDate'] as String?, now)) continue; // course finished
      for (final t in (s['schedules'] as List? ?? [])) {
        final tod = TimeOfDay(hour: t['hour'] as int, minute: t['minute'] as int);
        final timeText = formatTime12h(tod);
        String status = 'upcoming';
        for (final i in intakes) {
          if (i['medicine'] == s['name'] && i['time'] == timeText) status = i['status'] as String;
        }
        if (status == 'upcoming' && (tod.hour * 60 + tod.minute) < (now.hour * 60 + now.minute)) {
          status = 'not_confirmed';
        }
        rows.add({'name': s['name'], 'dosage': s['dosage'], 'time': timeText, 'min': tod.hour * 60 + tod.minute, 'status': status});
      }
    }
    rows.sort((a, b) => (a['min'] as int) - (b['min'] as int));

    Widget icon(String status) {
      switch (status) {
        case 'on_time':
          return const Icon(Icons.check_circle, color: Colors.green);
        case 'missed':
          return const Icon(Icons.cancel, color: Colors.red);
        case 'not_confirmed':
          return const Icon(Icons.hourglass_bottom, color: Colors.orange);
        default:
          return const Icon(Icons.schedule, color: Colors.grey);
      }
    }

    String label(String status) => const {
          'on_time': 'Taken',
          'missed': 'Missed',
          'not_confirmed': 'Not confirmed yet',
        }[status] ??
        'Upcoming';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Today's doses (${DateFormat('MMM d').format(now)})", style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (rows.isEmpty) const Text('No doses scheduled today.', style: TextStyle(color: Colors.grey)),
            ...rows.map((r) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: icon(r['status'] as String),
                  title: Text('${r['name']}  •  ${r['time']}'),
                  subtitle: Text('${r['dosage'] ?? ''}  —  ${label(r['status'] as String)}'),
                )),
          ],
        ),
      ),
    );
  }

  /// The patient's medicines; the caregiver can edit each one.
  Widget _medicinesCard(BuildContext context, List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Medicines', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('Tap ✎ to change a dose, time or day.',
                style: TextStyle(fontSize: 12, color: Colors.black45)),
            const SizedBox(height: 4),
            if (docs.isEmpty) const Text('No medicines scheduled.', style: TextStyle(color: Colors.grey)),
            ...docs.map((doc) {
              final m = MedicineEdit.fromFirestore(doc.data());
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.medication, color: _brand),
                title: Text('${m.name}  •  ${m.dosage}'),
                subtitle: Text('${m.timesText}\n${m.daysText}'
                    '${m.endDate != null ? '\n${courseText(m.endDate)}' : ''}'),
                isThreeLine: true,
                trailing: IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit, color: _brand),
                  onPressed: () => _editPatientMedicine(context, doc.id, m),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Future<void> _editPatientMedicine(BuildContext context, String scheduleId, MedicineEdit current) async {
    final edit = await showMedicineEditor(
      context,
      initial: current,
      title: 'Edit ${current.name}',
      subtitle: "Changes go to $patientName's app and update their reminders.",
    );
    if (edit == null || !context.mounted) return;
    try {
      await ScheduleEdits.save(
        ownerUid: patientUid,
        scheduleId: scheduleId,
        edit: edit,
        oldName: current.name,
        editorName: await CaregiverService().myName(),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${edit.name} updated for $patientName.')));
      }
    } catch (e) {
      if (context.mounted) {
        final denied = e.toString().contains('permission-denied');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(denied
              ? 'Not allowed yet: publish the new firestore.rules in the Firebase console.'
              : 'Could not save: $e'),
        ));
      }
    }
  }

  Widget _weekCard(Map<String, Map<String, dynamic>> logs) {
    int taken = 0;
    int missed = 0;
    final now = DateTime.now();
    for (int i = 0; i < 7; i++) {
      final intakes = (logs[dateKey(now.subtract(Duration(days: i)))]?['intakes'] as List?) ?? [];
      taken += intakes.where((x) => x['status'] == 'on_time').length;
      missed += intakes.where((x) => x['status'] == 'missed').length;
    }
    final total = taken + missed;
    final rate = total == 0 ? null : (taken * 100 / total).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Last 7 days', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(rate == null ? 'No logged doses yet.' : 'Adherence: $rate%',
                style: TextStyle(fontSize: 22, color: rate == null ? Colors.grey : (rate >= 80 ? Colors.green : Colors.red))),
            Text('$taken taken  •  $missed missed'),
          ],
        ),
      ),
    );
  }

  Widget _alertsCard(CaregiverService service) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: service.alertsOf(patientUid),
          builder: (context, snap) {
            if (snap.hasError) return _errorText(snap.error);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final docs = snap.data!.docs;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recent alerts', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (docs.isEmpty) const Text('No alerts. All good!', style: TextStyle(color: Colors.grey)),
                ...docs.map((d) {
                  final a = d.data();
                  final severity = (a['severity'] as String?) ?? 'high';
                  final ms = a['createdAtMs'] as int?;
                  final when = ms == null ? '' : DateFormat('MMM d, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(ms));
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      severity == 'info' ? Icons.info_outline : Icons.warning_amber_rounded,
                      color: severity == 'high' ? Colors.red : (severity == 'medium' ? Colors.orange : _brand),
                    ),
                    title: Text((a['message'] as String?) ?? ''),
                    subtitle: Text(when),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}
