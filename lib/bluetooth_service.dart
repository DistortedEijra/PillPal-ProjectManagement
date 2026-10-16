import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BluetoothService {
  // Singleton pattern
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() {
    return _instance;
  }
  BluetoothService._internal();

  BluetoothConnection? _connection;
  StreamSubscription? _inputSubscription;
  final StreamController<bool> _connectionStatusController = StreamController<bool>.broadcast();
  Stream<bool> get isConnectedStream => _connectionStatusController.stream;

  final StreamController<String> _dataController = StreamController<String>.broadcast();
  Stream<String> get dataStream => _dataController.stream;

  bool get isConnected => _connection?.isConnected ?? false;

  Future<bool> connect({int retries = 3}) async {
    if (isConnected) return true;

    final prefs = await SharedPreferences.getInstance();
    final String? deviceAddress = prefs.getString('pillbox_address');

    if (deviceAddress == null) {
      _connectionStatusController.add(false);
      return false;
    }

    // Ensure Bluetooth adapter is enabled
    final bluetooth = FlutterBluetoothSerial.instance;
    final state = await bluetooth.state;
    if (!state.isEnabled) {
      try {
        await bluetooth.requestEnable();
      } catch (e) {
        log('Failed to enable Bluetooth: $e');
      }
    }

    // Cancel discovery before attempting a connection (important on Android)
    try {
      await FlutterBluetoothSerial.instance.cancelDiscovery();
    } catch (_) {}

    // Ensure device is bonded; some stacks require bonding to create an RFCOMM socket
    try {
      final bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
      final isBonded = bonded.any((d) => d.address == deviceAddress);
      if (!isBonded) {
        log('Device not bonded, attempting to bond/pair: $deviceAddress');
        final ok = await FlutterBluetoothSerial.instance.bondDeviceAtAddress(deviceAddress);
        log((ok ?? false) ? 'Bond success' : 'Bond failed (may still connect if supported)');
      }
    } catch (e) {
      log('Bond check/attempt error: $e');
    }

    for (int i = 0; i < retries; i++) {
      try {
        log('Connecting to $deviceAddress (Attempt ${i + 1}/$retries)...');
        _connection = await BluetoothConnection.toAddress(deviceAddress);
        _connectionStatusController.add(true);
        log('Connected to $deviceAddress');

        final input = _connection?.input;
        if (input != null) {
          // Cancel any previous listener before attaching a new one
          // to prevent duplicate handlers on reconnect.
          await _inputSubscription?.cancel();
          _inputSubscription = input.listen((data) {
            final incomingMessage = utf8.decode(data);
            log('Received data: $incomingMessage');
            _dataController.add(incomingMessage);
          })..onDone(() {
            _connection = null;
            _inputSubscription = null;
            _connectionStatusController.add(false);
            log('Connection lost.');
            // Try to reconnect in the background
            _scheduleReconnect();
          });
        }
        return true;
      } catch (e) {
        log('Connection failed (Attempt ${i + 1}/$retries): $e');
        if (i == retries - 1) {
          _connectionStatusController.add(false);
          return false;
        }
        await Future.delayed(const Duration(seconds: 2)); // Wait before retrying
      }
    }
    return false;
  }

  Future<void> disconnect() async {
    await _inputSubscription?.cancel();
    _inputSubscription = null;
    await _connection?.close();
    _connection = null;
    _connectionStatusController.add(false);
  }

  Future<bool> sendSignal(String signal, {bool appendNewline = false}) async {
    if (!await connect()) {
      log('Failed to connect before sending signal.');
      return false;
    }

    try {
      // Optionally newline-terminate for Arduino line-oriented parsing
      final String payload = appendNewline
          ? (signal.endsWith('\n') ? signal : '$signal\n')
          : signal;
      log('Sending signal: $payload');
      final conn = _connection;
      if (conn == null) throw StateError('Connection is null after connect()');
      conn.output.add(utf8.encode(payload));
      await conn.output.allSent;
      log('Signal sent successfully.');
      return true;
    } catch (e) {
      log('Failed to send signal: $e');
      _connectionStatusController.add(false);
      // Attempt to reconnect and resend once
      if (await connect()) {
        try {
          final String payload2 = appendNewline
              ? (signal.endsWith('\n') ? signal : '$signal\n')
              : signal;
          final conn2 = _connection;
          if (conn2 == null) throw StateError('Connection is null after reconnect()');
          conn2.output.add(utf8.encode(payload2));
          await conn2.output.allSent;
          return true;
        } catch (e2) {
          log('Failed to send signal on second attempt: $e2');
          _connectionStatusController.add(false);
        }
      }
    }
    return false;
  }

  void _scheduleReconnect() {
    // Fire and forget simple reconnect attempt after a short delay
    Future<void>.delayed(const Duration(seconds: 2), () async {
      if (!isConnected) {
        await connect(retries: 2);
      }
    });
  }

  void dispose() {
    // Intentionally do not close broadcast controllers to avoid add-after-close errors
    // when widgets dispose but the app continues to use the singleton service.
    // Ensure we tear down the connection instead.
    _inputSubscription?.cancel();
    _inputSubscription = null;
    _connection?.dispose();
    _connection = null;
  }
}
