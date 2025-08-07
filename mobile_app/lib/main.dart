import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class Position {
  String name;
  double angle;
  double distance;
  int volume;

  Position({
    required this.name,
    required this.angle,
    required this.distance,
    this.volume = 60,
  });

  factory Position.fromJson(Map<String, dynamic> json) {
    return Position(
      name: json['name'],
      angle: (json['angle'] as num).toDouble(),
      distance: (json['distance'] as num).toDouble(),
      volume: json['volume'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'angle': angle,
      'distance': distance,
      'volume': volume,
    };
  }
}

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto-regulating Speaker',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        scaffoldBackgroundColor: Colors.grey[100],
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        appBarTheme: AppBarTheme(
          elevation: 0,
          centerTitle: true,
        ),
      ),
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool isAutoMode = true;
  bool isCustomMode = false;
  bool isManualMode = false;
  String serverIP = '';
  String currentTagName = "";
  double currentDistance = 0.0;
  double currentAngle = 0.0;
  int currentVolume = 60;
  List<Position> customPositions = [];
  int _highlightedIndex = -1;
  double _highlightedComposite = double.infinity;
  bool isConnected = false;
  bool _servoAutoTracking = true; // 默認為自動追踪
  double _servoManualAngle = 90.0; // 手動控制角度，默認 90 度

  Timer? _dataTimer;
  Timer? _connectionCheckTimer;

  @override
  void initState() {
    super.initState();
    _initializeConnection();
    _loadCustomPositionsFromPrefs();
  }

  void _initializeConnection() {
    _getServerIP();

    _connectionCheckTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (!isConnected) {
        _getServerIP();
      } else {
        _checkConnection();
      }
    });
  }

  Future<void> _checkConnection() async {
    if (serverIP.isEmpty) return;

    try {
      final response = await http
          .get(Uri.parse('http://$serverIP:5000/pi-ip'))
          .timeout(Duration(seconds: 3));

      if (response.statusCode != 200) {
        _handleConnectionLoss();
      }
    } catch (e) {
      _handleConnectionLoss();
    }
  }

  void _handleConnectionLoss() {
    setState(() {
      isConnected = false;
      serverIP = '';
    });
    _dataTimer?.cancel();
    _startDataPolling();
  }

  Future<void> _loadCustomPositionsFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final String? jsonString = prefs.getString('customPositions');
    if (jsonString != null) {
      final List<dynamic> decodedJson = jsonDecode(jsonString);
      setState(() {
        customPositions =
            decodedJson.map((json) => Position.fromJson(json)).toList();
      });
    }
  }

  Future<void> _saveCustomPositionsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final String jsonString =
        jsonEncode(customPositions.map((e) => e.toJson()).toList());
    await prefs.setString('customPositions', jsonString);
  }

  Future<void> _getServerIP() async {
    if (isConnected) return;

    List<String> candidateIPs = [
      '192.168.1.216',
      '192.168.0.123',
      '192.168.1.162',
      '192.168.160.241',
      '172.20.10.2', 
      '10.0.0.2'
    ];

    for (String ip in candidateIPs) {
      try {
        final response = await http
            .get(Uri.parse('http://$ip:5000/pi-ip'))
            .timeout(Duration(seconds: 3));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          setState(() {
            serverIP = data['ip'];
            isConnected = true;
          });
          print('連線成功，使用 IP：$serverIP');
          _startDataPolling();
          if (!isAutoMode) _loadPositions();
          return;
        }
      } catch (e) {
        print('IP $ip 無法連線');
      }
    }

    setState(() {
      serverIP = '';
      isConnected = false;
    });
    print('無可用 IP');
  }

  void _startDataPolling() {
    _dataTimer?.cancel();
    _dataTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
      if (isConnected) {
        _getCurrentData();
      } else {
        timer.cancel();
      }
    });
  }

  // Replace the _getCurrentData method in _HomePageState class
  Future<void> _getCurrentData() async {
    if (!isConnected || serverIP.isEmpty) return;

    try {
      // First check if the server is still alive
      final pingResponse = await http
          .get(Uri.parse('http://$serverIP:5000/pi-ip'))
          .timeout(Duration(seconds: 3));

      if (pingResponse.statusCode != 200) {
        _handleConnectionLoss();
        return;
      }

      // Then try to get current UWB data
      final response = await http
          .get(Uri.parse('http://$serverIP:5000/current-data'))
          .timeout(Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          currentTagName = data['address'] ?? "";
          currentDistance = (data['distance'] as num?)?.toDouble() ?? 0.0;
          currentAngle = (data['angle'] as num?)?.toDouble() ?? 0.0;
          currentVolume = (data['volume'] as num?)?.toInt() ?? 0;
        });
        _updateHighlightedIndex();
      } else {
        // Don't handle as connection loss - the server is running but no UWB data yet
        print('No UWB data available yet');
      }
    } catch (e) {
      _handleConnectionLoss();
      print('Error getting current data: $e');
    }
  }

  void _updateHighlightedIndex() {
    int candidateIndex = -1;
    double candidateComposite = double.infinity;
    const double weightAngle = 1.0;
    const double weightDistance = 20.0;

    for (int i = 0; i < customPositions.length; i++) {
      double aDiff = (customPositions[i].angle - currentAngle).abs();
      double dDiff = (customPositions[i].distance - currentDistance).abs();
      double composite = (aDiff * weightAngle) + (dDiff * weightDistance);
      if (composite < candidateComposite) {
        candidateComposite = composite;
        candidateIndex = i;
      }
    }

    if (_highlightedIndex == -1) {
      setState(() {
        _highlightedIndex = candidateIndex;
        _highlightedComposite = candidateComposite;
      });
    } else if (candidateIndex != _highlightedIndex &&
        candidateComposite < _highlightedComposite * 0.9) {
      setState(() {
        _highlightedIndex = candidateIndex;
        _highlightedComposite = candidateComposite;
      });
    } else if (candidateIndex == _highlightedIndex) {
      _highlightedComposite = candidateComposite;
    }
  }

  Future<void> _loadPositions() async {
    if (serverIP.isEmpty) return;
    try {
      final response =
          await http.get(Uri.parse('http://$serverIP:5000/positions'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          customPositions =
              data.map((json) => Position.fromJson(json)).toList();
        });
      }
    } catch (e) {
      print('Error loading positions: $e');
    }
  }

  Future<void> _setMode(String mode) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://$serverIP:5000/mode'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'mode': mode}),
      );
      if (response.statusCode == 200) {
        setState(() {
          isAutoMode = mode == 'auto';
          isCustomMode = mode == 'custom';
          isManualMode = mode == 'custom2';
        });
        if (isCustomMode) _loadPositions();
      }
    } catch (e) {
      print('Error setting mode: $e');
    }
  }

  Future<void> _setManualVolume(int volume) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://$serverIP:5000/volume'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'volume': volume}),
      );
      if (response.statusCode == 200) {
        setState(() {
          currentVolume = volume;
        });
      }
    } catch (e) {
      print('Error setting volume: $e');
    }
  }

  Future<void> _addNewPosition() async {
    String newName = '';
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('添加新位置'),
          content: TextField(
            onChanged: (value) => newName = value,
            decoration: InputDecoration(
              labelText: '位置名稱',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
              child: Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (newName.isNotEmpty) {
                  Navigator.pop(context);
                  _showVolumeDialogForNewPosition(newName);
                }
              },
              child: Text('下一步'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showVolumeDialogForNewPosition(String name) async {
    int newVolume = 60;
    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setStateDialog) {
          return AlertDialog(
            title: Text('調整音量'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '選擇音量: $newVolume%',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 16),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: Colors.indigo,
                    inactiveTrackColor: Colors.indigo.withOpacity(0.2),
                    thumbColor: Colors.indigo,
                    overlayColor: Colors.indigo.withOpacity(0.1),
                  ),
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 100,
                    value: newVolume.toDouble(),
                    label: '$newVolume',
                    onChanged: (value) {
                      setStateDialog(() {
                        newVolume = value.toInt();
                      });
                    },
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(foregroundColor: Colors.grey),
                child: Text('取消'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final newPosition = Position(
                    name: name,
                    angle: currentAngle,
                    distance: currentDistance,
                    volume: newVolume,
                  );
                  await _createPosition(newPosition);
                  Navigator.pop(context);
                },
                child: Text('確定'),
              ),
            ],
          );
        });
      },
    );
  }

  Future<void> _createPosition(Position position) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://$serverIP:5000/position'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(position.toJson()),
      );
      if (response.statusCode == 200) {
        setState(() {
          customPositions.add(position);
        });
        _saveCustomPositionsToPrefs();
        _loadPositions();
      }
    } catch (e) {
      print('Error creating position: $e');
    }
  }

  Future<void> _deletePosition(String name) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.delete(
        Uri.parse('http://$serverIP:5000/position/$name'),
      );
      if (response.statusCode == 200) {
        setState(() {
          customPositions.removeWhere((element) => element.name == name);
        });
        _saveCustomPositionsToPrefs();
        _loadPositions();
      }
    } catch (e) {
      print('Error deleting position: $e');
    }
  }

  Future<void> _setServoTrackingMode(bool autoTracking) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://$serverIP:5000/servo/tracking'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'auto_tracking': autoTracking}),
      );
      if (response.statusCode == 200) {
        setState(() {
          _servoAutoTracking = autoTracking;
        });
      }
    } catch (e) {
      print('Error setting servo tracking mode: $e');
    }
  }

  Future<void> _setServoManualAngle(double angle) async {
    if (serverIP.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://$serverIP:5000/servo/angle'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'angle': angle}),
      );
      if (response.statusCode == 200) {
        setState(() {
          _servoManualAngle = angle;
        });
      }
    } catch (e) {
      print('Error setting servo angle: $e');
    }
  }

  @override
  void dispose() {
    _dataTimer?.cancel();
    _connectionCheckTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Image.asset('lib/icons/STUST.png'),
        ),
        title: Text(
          'Auto-regulating Speaker',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          Container(
            margin: EdgeInsets.all(8.0),
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Icon(serverIP.isEmpty ? Icons.wifi_off : Icons.wifi,
                    size: 16, color: serverIP.isEmpty ? Colors.red : null),
                SizedBox(width: 4),
                Text(
                  serverIP.isEmpty ? '失去連線' : serverIP,
                  style: TextStyle(fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 8,
                  offset: Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16.0, bottom: 8.0),
                  child: Text(
                    '選擇模式',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.grey[700],
                    ),
                  ),
                ),
                Container(
                  height: 80,
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Row(
                    children: [
                      _buildModeButtonNew(
                        text: '自動模式',
                        description: '依距離調整音量',
                        isActive: isAutoMode,
                        onPressed: () => _setMode('auto'),
                        icon: Icons.auto_awesome,
                        color: Colors.blueAccent,
                      ),
                      _buildModeButtonNew(
                        text: '自定義模式',
                        description: '根據位置調整',
                        isActive: isCustomMode,
                        onPressed: () => _setMode('custom'),
                        icon: Icons.edit_location_alt,
                        color: Colors.orange,
                      ),
                      _buildModeButtonNew(
                        text: '手動模式',
                        description: '手動控制音量',
                        isActive: isManualMode,
                        onPressed: () => _setMode('custom2'),
                        icon: Icons.volume_up,
                        color: Colors.green,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isAutoMode) _buildAutoModeCard(),
          if (isCustomMode) _buildCustomModeList(_highlightedIndex),
          if (isManualMode) _buildManualModeCard(),
        ],
      ),
      floatingActionButton: isCustomMode
          ? FloatingActionButton.extended(
              onPressed: _addNewPosition,
              icon: Icon(Icons.add_location_alt),
              label: Text('新增位置'),
              elevation: 4,
            )
          : null,
    );
  }

  Widget _buildModeButtonNew({
    required String text,
    required String description,
    required bool isActive,
    required VoidCallback onPressed,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: 4.0),
          padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 10.0),
          decoration: BoxDecoration(
            color: isActive ? color.withOpacity(0.15) : Colors.grey[100],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? color : Colors.transparent,
              width: 2,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: color.withOpacity(0.2),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isActive ? color : Colors.grey[600],
                size: 22,
              ),
              SizedBox(height: 4),
              Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                  color: isActive ? color : Colors.grey[700],
                ),
              ),
              Text(
                description,
                style: TextStyle(
                  fontSize: 9,
                  color: isActive ? color.withOpacity(0.8) : Colors.grey[500],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 替換 _buildManualModeCard 方法中的音量按鈕部分

  Widget _buildManualModeCard() {
    return Expanded(
      child: SingleChildScrollView(
        // 添加 ScrollView
        child: Card(
          margin: EdgeInsets.all(16),
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoRow(Icons.label, '標籤位址', currentTagName),
                Divider(height: 24),
                _buildInfoRow(
                  Icons.straighten,
                  '距離',
                  '${currentDistance.toStringAsFixed(2)} m',
                ),
                SizedBox(height: 16),
                _buildInfoRow(
                  Icons.rotate_right,
                  '角度',
                  '${currentAngle.toStringAsFixed(2)}°',
                ),
                SizedBox(height: 24),

                // 新增伺服馬達控制部分
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '伺服馬達控制',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo,
                      ),
                    ),
                    Switch(
                      value: _servoAutoTracking,
                      onChanged: (value) => _setServoTrackingMode(value),
                      activeColor: Colors.indigo,
                    ),
                  ],
                ),

                SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.assistant, size: 22, color: Colors.indigo),
                    SizedBox(width: 8),
                    Text(
                      _servoAutoTracking ? '自動追蹤' : '手動控制',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ),

                // 手動角度控制滑桿，僅在手動模式下顯示
                if (!_servoAutoTracking) ...[
                  SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.rotate_right, size: 22, color: Colors.indigo),
                      SizedBox(width: 8),
                      Text(
                        '伺服馬達角度: ',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey[700],
                        ),
                      ),
                      Text(
                        '${_servoManualAngle.toInt()}°',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),
                  SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: Colors.indigo,
                      inactiveTrackColor: Colors.indigo.withOpacity(0.2),
                      thumbColor: Colors.indigo,
                      overlayColor: Colors.indigo.withOpacity(0.1),
                      trackHeight: 6,
                    ),
                    child: Slider(
                      min: 30,
                      max: 150,
                      divisions: 120,
                      value: _servoManualAngle,
                      label: '${_servoManualAngle.toInt()}°',
                      onChanged: (value) {
                        setState(() {
                          _servoManualAngle = value;
                        });
                      },
                      onChangeEnd: (value) {
                        _setServoManualAngle(value);
                      },
                    ),
                  ),
                  SizedBox(height: 8),
                  SizedBox(
                    height: 50,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildServoAnglePresetButton(30),
                        _buildServoAnglePresetButton(60),
                        _buildServoAnglePresetButton(90),
                        _buildServoAnglePresetButton(120),
                        _buildServoAnglePresetButton(150),
                      ],
                    ),
                  ),
                ],

                Divider(height: 32),

                // 音量控制標題
                Text(
                  '手動音量控制',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.indigo,
                  ),
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.volume_up, size: 22, color: Colors.indigo),
                    SizedBox(width: 8),
                    Text(
                      '目前音量: ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey[700],
                      ),
                    ),
                    Text(
                      '$currentVolume%',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.indigo,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: Colors.indigo,
                    inactiveTrackColor: Colors.indigo.withOpacity(0.2),
                    thumbColor: Colors.indigo,
                    overlayColor: Colors.indigo.withOpacity(0.1),
                    trackHeight: 6,
                  ),
                  child: Slider(
                    min: 0,
                    max: 100,
                    divisions: 100,
                    value: currentVolume.toDouble(),
                    label: '$currentVolume',
                    onChanged: (value) {
                      setState(() {
                        currentVolume = value.toInt();
                      });
                    },
                    onChangeEnd: (value) {
                      _setManualVolume(value.toInt());
                    },
                  ),
                ),
                SizedBox(height: 20),
                SizedBox(
                  height: 65,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildVolumePresetButton(0),
                      _buildVolumePresetButton(25),
                      _buildVolumePresetButton(50),
                      _buildVolumePresetButton(75),
                      _buildVolumePresetButton(100),
                    ],
                  ),
                ),
                // 添加底部間距，確保捲動時內容完全顯示
                SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

// 添加伺服馬達角度預設按鈕構建方法
  Widget _buildServoAnglePresetButton(int angle) {
    final bool isSelected = _servoManualAngle.toInt() == angle;
    final double size = 48;

    return GestureDetector(
      onTap: () => _setServoManualAngle(angle.toDouble()),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isSelected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.teal.shade400, Colors.teal.shade700],
                )
              : null,
          color: isSelected ? null : Colors.grey.shade200,
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? Colors.teal.withOpacity(0.4)
                  : Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Center(
          child: Text(
            '$angle°',
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black87,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

// 添加這個新方法來構建預設音量按鈕
  Widget _buildVolumePresetButton(int volume) {
    final bool isSelected = currentVolume == volume;
    final double size = 56;

    return GestureDetector(
      onTap: () => _setManualVolume(volume),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isSelected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.indigo.shade400, Colors.indigo.shade700],
                )
              : null,
          color: isSelected ? null : Colors.grey.shade200,
          boxShadow: [
            BoxShadow(
              color: isSelected
                  ? Colors.indigo.withOpacity(0.4)
                  : Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Center(
          child: Text(
            '$volume%',
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.black87,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoModeCard() {
    return Card(
      margin: EdgeInsets.all(16),
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow(Icons.label, '標籤位址', currentTagName),
            Divider(height: 24),
            _buildInfoRow(
              Icons.straighten,
              '距離',
              '${currentDistance.toStringAsFixed(2)} m',
            ),
            SizedBox(height: 16),
            _buildInfoRow(
              Icons.rotate_right,
              '角度',
              '${currentAngle.toStringAsFixed(2)}°',
            ),
            SizedBox(height: 16),
            _buildVolumeIndicator(currentVolume),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 24, color: Colors.indigo),
        SizedBox(width: 12),
        Text(
          '$label:',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: Colors.grey[600],
          ),
        ),
        SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildVolumeIndicator(int volume) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.volume_up, size: 24, color: Colors.indigo),
            SizedBox(width: 12),
            Text(
              '音量:',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[600],
              ),
            ),
            SizedBox(width: 8),
            Text(
              '$volume%',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: volume / 100,
            minHeight: 8,
            backgroundColor: Colors.grey[200],
            valueColor: AlwaysStoppedAnimation<Color>(Colors.indigo),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomModeList(int activeIndex) {
    return Expanded(
      child: ListView.builder(
        padding: EdgeInsets.all(16),
        itemCount: customPositions.length,
        itemBuilder: (context, index) {
          final position = customPositions[index];
          final bool isActive = index == activeIndex;

          return Card(
            margin: EdgeInsets.only(bottom: 12),
            color: isActive ? Colors.indigo.shade50 : Colors.white,
            child: ListTile(
              contentPadding: EdgeInsets.all(16),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    position.name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight:
                          isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive ? Colors.indigo : Colors.black87,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete_outline),
                    color: Colors.red,
                    onPressed: () => _deletePosition(position.name),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 8),
                  _buildPositionInfo(
                    Icons.rotate_right,
                    '角度',
                    '${position.angle.toStringAsFixed(2)}°',
                  ),
                  SizedBox(height: 4),
                  _buildPositionInfo(
                    Icons.straighten,
                    '距離',
                    '${position.distance.toStringAsFixed(2)} m',
                  ),
                  SizedBox(height: 4),
                  _buildPositionInfo(
                    Icons.volume_up,
                    '音量',
                    '${position.volume}',
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPositionInfo(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[600]),
        SizedBox(width: 4),
        Text(
          '$label: ',
          style: TextStyle(color: Colors.grey[600]),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: Colors.grey[800],
          ),
        ),
      ],
    );
  }
}
