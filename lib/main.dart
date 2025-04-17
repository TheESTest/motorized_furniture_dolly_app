//Author: Austin Allen
//Motorized Furniture Dolly
//Flutter App

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Dolly Controller',
      home: BLEControlPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BLEControlPage extends StatefulWidget {
  @override
  _BLEControlPageState createState() => _BLEControlPageState();
}

class _BLEControlPageState extends State<BLEControlPage> {
  bool? isConnected;
  bool showDeviceList = true;
  final String targetDeviceName = "ESP32_S3_BLE";
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? bleCharacteristic;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;

  final ValueNotifier<double> displayedSpeed = ValueNotifier<double>(0.0);
  final ValueNotifier<double> verticalValue = ValueNotifier<double>(0.0);
  final ValueNotifier<double> horizontalValue = ValueNotifier<double>(0.0);

  final double factor1 = 0.8;
  final double factor2 = -0.2;
  Timer? joystickTimer;

  bool allowJoystickSend = true;
  bool isWriting = false;
  int lastSentY = 9999;
  int lastSentX = 9999;

  @override
  void initState() {
    super.initState();
    requestPermissions();

    joystickTimer = Timer.periodic(Duration(milliseconds: 50), (_) {
      if (allowJoystickSend && bleCharacteristic != null && isConnected == true) {
        final y = (verticalValue.value * factor1).round();
        final x = (horizontalValue.value * factor2).round();

        if (y != lastSentY || x != lastSentX) {
          sendJoystickData(y, x);
          lastSentY = y;
          lastSentX = x;
        }
      }
    });
  }

  @override
  void dispose() {
    joystickTimer?.cancel();
    verticalValue.dispose();
    horizontalValue.dispose();
    displayedSpeed.dispose();
    connectionSubscription?.cancel();
    super.dispose();
  }

  Future<void> requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  void resetVertical() => verticalValue.value = 0;
  void resetHorizontal() => horizontalValue.value = 0;

  Future<void> _setupDevice(BluetoothDevice device) async {
    setState(() => isConnected = true);
    connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && isConnected == true) {
        setState(() {
          isConnected = false;
          connectedDevice = null;
          bleCharacteristic = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Device disconnected")),
        );
      }
    });

    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString().toLowerCase() == "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
        for (BluetoothCharacteristic c in service.characteristics) {
          if (c.uuid.toString().toLowerCase() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            bleCharacteristic = c;
            if (c.properties.notify) {
              try {
                await c.setNotifyValue(true);
                c.lastValueStream.listen((value) {
                  try {
                    final decoded = String.fromCharCodes(value).trim();
                    final rpm = double.tryParse(decoded);
                    if (rpm != null) {
                      final speed = rpm * 0.00192;
                      displayedSpeed.value = speed;
                    }
                  } catch (e) {
                    print("BLE PARSE ERROR: $e");
                  }
                });
              } catch (e) {
                print("Notification setup failed: $e");
              }
            }
          }
        }
      }
    }
  }

  void scanAndConnect() async {
    await FlutterBluePlus.startScan(timeout: Duration(seconds: 4));
  }

  void sendJoystickData(int y, int x) async {
    if (bleCharacteristic != null && !isWriting) {
      final scaledY = y * 24;
      final scaledX = x * 24;
      final dataString = "$scaledY,$scaledX";
      try {
        isWriting = true;
        await bleCharacteristic!.write(dataString.codeUnits);
      } catch (_) {} finally {
        isWriting = false;
      }
    }
  }

  void sendCommand(String cmd) async {
    if (bleCharacteristic != null) {
      allowJoystickSend = false;
      await bleCharacteristic!.write(cmd.codeUnits);
      await Future.delayed(Duration(milliseconds: 200));
      allowJoystickSend = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    String connectionStatus = "Disconnected";
    if (connectedDevice != null) {
      connectionStatus = isConnected == true ? "Connected to $targetDeviceName" : "Connecting...";
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                ElevatedButton(
                  onPressed: () => setState(() => showDeviceList = !showDeviceList),
                  child: Text(showDeviceList ? "Hide Devices" : "Show Devices"),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: scanAndConnect,
                  child: Text("Scan for Devices"),
                ),
                SizedBox(width: 16),
                Icon(
                  isConnected == true ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: isConnected == true ? Colors.green : Colors.red,
                ),
                SizedBox(width: 8),
                Text(connectionStatus, style: TextStyle(fontSize: 16)),
              ],
            ),
            if (showDeviceList)
              SizedBox(
                height: 80,
                child: StreamBuilder<List<ScanResult>>(
                  stream: FlutterBluePlus.scanResults,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      return Center(child: Text("No devices found"));
                    }
                    final results = snapshot.data!;
                    return ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final device = results[index].device;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: ElevatedButton(
                            onPressed: () async {
                              setState(() {
                                isConnected = false;
                                showDeviceList = false;
                                connectedDevice = device;
                              });

                              await FlutterBluePlus.stopScan();
                              await Future.delayed(Duration(milliseconds: 500));

                              try {
                                if (!(await connectedDevice!.isConnected)) {
                                  await connectedDevice!.connect(autoConnect: false);
                                }
                              } catch (e) {
                                print("First connect attempt error: $e");
                                await Future.delayed(Duration(seconds: 1));
                                try {
                                  await connectedDevice!.connect(autoConnect: false);
                                } catch (e) {
                                  print("Second connect attempt failed: $e");
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Failed to connect to device.")),
                                  );
                                  setState(() {
                                    isConnected = null;
                                    connectedDevice = null;
                                  });
                                  return;
                                }
                              }
                              await _setupDevice(connectedDevice!);
                            },
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(device.name.isNotEmpty ? device.name : device.id.toString()),
                                Text("RSSI: ${results[index].rssi}", style: TextStyle(fontSize: 12)),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Listener(
                      onPointerMove: (event) {
                        verticalValue.value -= event.delta.dy;
                        verticalValue.value = verticalValue.value.clamp(-2400.0, 2400.0);
                      },
                      onPointerUp: (_) => resetVertical(),
                      child: Container(
                        color: Colors.blue.shade50,
                        child: Center(
                          child: ValueListenableBuilder<double>(
                            valueListenable: verticalValue,
                            builder: (context, value, _) => RotatedBox(
                              quarterTurns: 3,
                              child: Slider(
                                value: value,
                                min: -100,
                                max: 100,
                                onChanged: (_) {},
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ValueListenableBuilder<double>(
                          valueListenable: displayedSpeed,
                          builder: (context, value, _) => Text(
                            "Speed: ${value.toStringAsFixed(2)} mph",
                            style: TextStyle(fontSize: 24),
                          ),
                        ),
                        SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: () => sendCommand("L"),
                          child: Icon(Icons.lightbulb),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Listener(
                      onPointerMove: (event) {
                        horizontalValue.value += event.delta.dx;
                        horizontalValue.value = horizontalValue.value.clamp(-2400.0, 2400.0);
                      },
                      onPointerUp: (_) => resetHorizontal(),
                      child: Container(
                        color: Colors.green.shade50,
                        child: Center(
                          child: ValueListenableBuilder<double>(
                            valueListenable: horizontalValue,
                            builder: (context, value, _) => Slider(
                              value: value,
                              min: -100,
                              max: 100,
                              onChanged: (_) {},
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
    );
  }
}
