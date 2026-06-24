import 'dart:async'; // برای تایمر لودینگ زنده اتصالات
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io'; // برای کلاس بومی پلتفرم و فایل‌ها
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart'; // برای رفع خطای وضعیت ریلیز
import 'package:window_manager/window_manager.dart'; // مدیریت پنجره ویندوز (دسکتاپ)
import 'package:tray_manager/tray_manager.dart'; // مدیریت سیستم تری کنار ساعت (دسکتاپ)
import 'src/rust/api/simple.dart'; // توابع راست
import 'src/rust/frb_generated.dart';

// مدل ساختار داده‌ای اکانت برای بخش گیت‌هاب
class VlessAccount {
  final String worker;
  final String uuid;
  final String path;
  final String name;

  VlessAccount({
    required this.worker,
    required this.uuid,
    required this.path,
    required this.name,
  });
}

// مدل ساختار داده‌ای دی‌ان‌اس
class DnsProfile {
  final String name;
  final String primary;
  final String secondary;
  final String description;

  DnsProfile({
    required this.name,
    required this.primary,
    required this.secondary,
    required this.description,
  });
}

// مدل پیشرفته تجزیه و تحلیل و سریالایز کردن لینک‌های ویتوری (VLESS و Trojan)
class V2rayConfig {
  String protocol; // vless or trojan
  String alias;
  String address;
  int port;
  String uuidOrPassword;
  String transport;
  String host;
  String path;
  String security;
  String sni;
  String fingerprint;
  String alpn;
  bool allowInsecure;

  V2rayConfig({
    required this.protocol,
    required this.alias,
    required this.address,
    required this.port,
    required this.uuidOrPassword,
    this.transport = 'tcp',
    this.host = '',
    this.path = '',
    this.security = 'none',
    this.sni = '',
    this.fingerprint = 'chrome',
    this.alpn = 'http/1.1',
    this.allowInsecure = false,
  });

  // تبدیل لینک خام ویتوری به فیلدهای ساختاریافته فلاتر
  static V2rayConfig parse(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      final protocol = uri.scheme;
      final alias = Uri.decodeComponent(uri.fragment);
      final address = uri.host;
      final port = uri.port;
      final uuidOrPassword = uri.userInfo;
      
      final params = uri.queryParameters;
      final transport = params['type'] ?? 'tcp';
      final host = params['host'] ?? '';
      final path = Uri.decodeComponent(params['path'] ?? '');
      final security = params['security'] ?? 'none';
      final sni = params['sni'] ?? '';
      final fingerprint = params['fp'] ?? 'chrome';
      final alpn = Uri.decodeComponent(params['alpn'] ?? 'http/1.1');
      final allowInsecure = (params['insecure'] == '1' || params['allowInsecure'] == '1');

      return V2rayConfig(
        protocol: protocol,
        alias: alias,
        address: address,
        port: port,
        uuidOrPassword: uuidOrPassword,
        transport: transport,
        host: host,
        path: path,
        security: security,
        sni: sni,
        fingerprint: fingerprint,
        alpn: alpn,
        allowInsecure: allowInsecure,
      );
    } catch (_) {
      // در صورت بروز هرگونه خطای پارس، بازگردانی ساختار پایه پیش‌فرض
      return V2rayConfig(
        protocol: 'vless',
        alias: 'سرور ویرایش‌نشده',
        address: '127.0.0.1',
        port: 443,
        uuidOrPassword: 'uuid-id',
      );
    }
  }

  // تبدیل مجدد فیلدهای فلاتر به لینک استاندارد خام ویتوری جهت ارسال به هسته
  String toRawUrl() {
    final Map<String, String> queryParams = {
      'security': security,
      'type': transport,
    };
    if (host.isNotEmpty) queryParams['host'] = host;
    if (path.isNotEmpty) queryParams['path'] = path;
    if (sni.isNotEmpty) queryParams['sni'] = sni;
    if (fingerprint.isNotEmpty) queryParams['fp'] = fingerprint;
    if (alpn.isNotEmpty) queryParams['alpn'] = alpn;
    if (allowInsecure) {
      queryParams['insecure'] = '1';
      queryParams['allowInsecure'] = '1';
    }

    final encodedAlias = Uri.encodeComponent(alias);
    final queryString = Uri(queryParameters: queryParams).query;

    return "$protocol://$uuidOrPassword@$address:$port?$queryString#$encodedAlias";
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  // ۱. راه‌اندازی بومی مدیریت پنجره در ویندوز
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(1100, 750),
      minimumSize: Size(950, 650),
      center: true,
      title: 'RedCloud VPN', // شخصی‌سازی عنوان پنجره برنامه
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    // جلوگیری از بسته‌شدن اجباری برنامه با زدن دکمه بستن (X)
    await windowManager.setPreventClose(true);
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F111A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C5DD3),
          secondary: Color(0xFF2DCA73),
          surface: Color(0xFF151824),
        ),
        useMaterial3: true,
      ),
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

// ادغام کردن شنونده‌های پنجره و سیستم تری
class _MainLayoutState extends State<MainLayout> with WindowListener, TrayListener {
  int _selectedMenuIndex = 0; // مدیریت زبانه‌های سایدبار کناری
  
  final TextEditingController _binaryPathController = TextEditingController(text: 'sing-box.exe');
  final TextEditingController _torPathController = TextEditingController(text: 'tor.exe');
  final TextEditingController _psiphonPathController = TextEditingController(text: 'psiphon-tunnel-core.exe');
  final TextEditingController _importController = TextEditingController();

  final TextEditingController _uuidController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _workerController = TextEditingController();

  // کنترلرها و متغیرهای وضعیت جدید برای تنظیمات ضد سانسور (Anti-DPI)
  final TextEditingController _customSniController = TextEditingController();
  final TextEditingController _tlsSpoofController = TextEditingController();
  bool _enableFragment = false;
  bool _enableRecordFragment = false;
  bool _useTunMode = false; // سوئیچ جدید فعال‌سازی کارت شبکه مجازی (TUN)

  // متغیرهای وضعیت مانیتور زنده سرعت ترافیک واقعی
  String _downloadSpeed = "0.0 B/s";
  String _uploadSpeed = "0.0 B/s";
  StreamSubscription? _trafficSubscription; // شنونده استریم سرعت Clash API

  // نگهدارنده پینگ‌های زنده سرورها
  final Map<String, int> _nodePings = {};
  bool _isBulkPinging = false;

  List<ProxyNode> _savedNodes = [];
  ProxyNode? _selectedNode;

  // اطلاعات موقعیت مکانی و آی‌پی سرور متصل شده
  String? _publicIp;
  String? _countryCode;
  String? _countryName;
  String? _cityName;
  bool _isLoadingIpInfo = false;

  // لیست اکانت‌های دریافت شده از گیت‌هاب
  List<VlessAccount> _githubAccounts = [];
  VlessAccount? _selectedGithubAccount;
  bool _isLoadingAccounts = false;

  // وضعیت‌های مستقل اتصالات برنامه
  bool _isProxyRunning = false;     // وضعیت سرورهای V2Ray
  bool _isTorRunning = false;       // وضعیت اتصال نهایی شبکه تور (به مدار پیاز متصل شده)
  bool _isTorConnecting = false;    // فرآیند میانی در حال اتصال تور (Bootstrap < 100)
  int _torProgressPercent = 0;      // نگهدارنده درصد زنده پیشرفت تور
  Timer? _torProgressTimer;         // تایمر پایش درصد لود تور
  
  bool _isPsiphonRunning = false;   // وضعیت نهایی اتصال شبکه سایفون (پورت ۹۰۸۰ متصل شده)
  bool _isPsiphonConnecting = false; // فرآیند میانی در حال اتصال سایفون
  Timer? _psiphonProgressTimer;     // تایمر پایش زنده لود سایفون
  
  String _selectedTorCountry = "تصادفی (Random)"; // کشور پیش‌فرض تور
  String _selectedPsiphonCountry = "تصادفی (Random)"; // کشور پیش‌فرض سایفون
  
  final Map<String, String> _torCountries = {
    'تصادفی (Random)': '',
    'آلمان (Germany)': 'de',
    'آمریکا (United States)': 'us',
    'فرانسه (France)': 'fr',
    'هلند (Netherlands)': 'nl',
    'سوئد (Sweden)': 'se',
    'بریتانیا (United Kingdom)': 'gb',
  };

  final Map<String, String> _psiphonCountries = {
    'تصادفی (Random)': '',
    'آمریکا (United States)': 'US',
    'آلمان (Germany)': 'DE',
    'بریتانیا (United Kingdom)': 'GB',
    'کانادا (Canada)': 'CA',
    'سنگاپور (Singapore)': 'SG',
    'ژاپن (Japan)': 'JP',
    'هلند (Netherlands)': 'NL',
  };

  // لیست دی‌ان‌اس‌های برگزیده تحریم‌شکن و جهانی
  final List<DnsProfile> _dnsList = [
    DnsProfile(name: 'شکن (Shecan)', primary: '178.22.122.100', secondary: '185.51.200.2', description: 'دور زدن تحریم‌های اینترنتی وب‌سایت‌های خارجی'),
    DnsProfile(name: 'الکترو (Electro)', primary: '78.157.42.100', secondary: '78.157.42.101', description: 'مخصوص بازی و تحریم‌شکن عمومی با پینگ عالی'),
    DnsProfile(name: '۴۰۳ آنلاین (403.online)', primary: '10.202.10.10', secondary: '10.202.10.11', description: 'مخصوص دور زدن محدودیت‌های توسعه‌دهندگی و بازی'),
    DnsProfile(name: 'رادار گیم (Radar Game)', primary: '10.201.10.10', secondary: '10.201.10.11', description: 'کاهش پینگ و دور زدن تحریم بازی‌های رایانه‌ای'),
    DnsProfile(name: 'کلودفلر (Cloudflare)', primary: '1.1.1.1', secondary: '1.0.0.1', description: 'امن‌ترین و سریع‌ترین دی ان اس عمومی جهان'),
    DnsProfile(name: 'گوگل (Google)', primary: '8.8.8.8', secondary: '8.8.4.4', description: 'دی ان اس عمومی، استاندارد و بسیار پایدار گوگل'),
  ];

  late DnsProfile _selectedDns; // دی‌ان‌اس انتخاب شده فعلی
  bool _isDnsRunning = false;   // وضعیت اعمال بودن دی‌ان‌اس
  int? _dnsPing;                // پینگ سرور دی‌ان‌اس بر اساس میلی‌ثانیه
  bool _isPingingDns = false;   // وضعیت در حال سنجش پینگ دی‌ان‌اس

  bool _useSystemProxy = true; 
  bool _isScanning = false; 
  String _statusMessage = "سیستم آماده اتصال است";

  // ایجاد کانال متد ارتباطی بومی بستر اندروید
  static const _androidVpnChannel = MethodChannel('com.example.redcloud/vpn');

  @override
  void initState() {
    super.initState();
    _selectedDns = _dnsList[0]; // انتخاب اولین گزینه شکن به عنوان پیش‌فرض
    
    // افزودن شنونده‌ها فقط در صورت اجرا روی دسکتاپ ویندوز
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initSystemTray();
    }
    _checkStatus();
    _testDnsPing(); // گرفتن پینگ دی‌ان‌اس پیش‌فرض در شروع برنامه
  }

  @override
  void dispose() {
    _torProgressTimer?.cancel();
    _psiphonProgressTimer?.cancel();
    _customSniController.dispose();
    _tlsSpoofController.dispose();
    _stopTrafficMonitoring(); // لغو اتصال فعال استریم پایش سرعت زنده
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  // فعال‌سازی پایش زنده و واقعی سرعت از Clash API داخلی sing-box
  void _startTrafficMonitoring() async {
    _stopTrafficMonitoring(); // قطع و ریست اتصالات قبلی جهت جلوگیری از تداخل
    
    try {
      final client = HttpClient();
      // لایه دور زدن قطعی پروکسی سیستم برای برقراری ارتباط مستقیم با لوکال‌هاست روی پورت ۹۰۹۰
      client.findProxy = (uri) => "DIRECT"; 
      
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:9090/traffic'));
      final response = await request.close();
      
      _trafficSubscription = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isEmpty) return;
        try {
          final data = jsonDecode(line);
          final double up = (data['up'] as num).toDouble();
          final double down = (data['down'] as num).toDouble();
          setState(() {
            _downloadSpeed = _formatSpeed(down);
            _uploadSpeed = _formatSpeed(up);
          });
        } catch (_) {}
      }, onError: (_) {
        _stopTrafficMonitoring();
      }, onDone: () {
        _stopTrafficMonitoring();
      });
    } catch (_) {
      _stopTrafficMonitoring();
    }
  }

  // غیرفعال کردن مانیتورینگ ترافیک زنده
  void _stopTrafficMonitoring() {
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    setState(() {
      _downloadSpeed = "0.0 B/s";
      _uploadSpeed = "0.0 B/s";
    });
  }

  // قالب‌بندی تبدیل بایت بر ثانیه به کیلوبایت و مگابایت بر ثانیه به صورت هوشمند
  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return "${bytesPerSecond.toStringAsFixed(1)} B/s";
    } else if (bytesPerSecond < 1024 * 1024) {
      return "${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s";
    } else {
      return "${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s";
    }
  }

  // فرآیند مأموریت پینگ گروهی و مرتب‌سازی موازی با لایه راست دسکتاپ
  Future<void> _bulkPingAndSort() async {
    setState(() {
      _isBulkPinging = true;
      _statusMessage = "در حال پایش موازی تاخیر پینگ سرورها با هسته راست...";
    });

    final List<Future<void>> pingFutures = [];
    for (var node in _savedNodes) {
      pingFutures.add(() async {
        try {
          final uri = Uri.parse(node.rawUrl);
          final host = uri.host;
          final port = uri.port;
          
          // فراخوانی مستقیم متد بومی راست برای بررسی TCP Handshake Latency
          final latency = await pingProxyServer(host: host, port: port);
          _nodePings[node.rawUrl] = latency;
        } catch (_) {
          _nodePings[node.rawUrl] = -1;
        }
      }());
    }

    await Future.wait(pingFutures);

    // مرتب‌سازی هوشمند: پینگ‌های سریع در بالای لیست و پینگ‌های قطع (-1) در انتهای لیست
    setState(() {
      _savedNodes.sort((a, b) {
        final pingA = _nodePings[a.rawUrl] ?? 99999;
        final pingB = _nodePings[b.rawUrl] ?? 99999;

        if (pingA == -1 && pingB == -1) return 0;
        if (pingA == -1) return 1;
        if (pingB == -1) return -1;

        return pingA.compareTo(pingB);
      });
      _isBulkPinging = false;
      _statusMessage = "تست پینگ موازی پایان یافت؛ سرورهای پایدار در صدر لیست قرار گرفتند.";
    });
  }

  // متد باز کردن دیالوگ پیشرفته ادیت دستی پارامترهای هر کانفیگ (دقیقاً مطابق فرمت درخواستی)
  void _openEditDialog(ProxyNode node, int index) {
    final config = V2rayConfig.parse(node.rawUrl);
    
    final aliasController = TextEditingController(text: config.alias);
    final addressController = TextEditingController(text: config.address);
    final portController = TextEditingController(text: config.port.toString());
    final uuidController = TextEditingController(text: config.uuidOrPassword);
    final hostController = TextEditingController(text: config.host);
    final pathController = TextEditingController(text: config.path);
    final sniController = TextEditingController(text: config.sni);
    final echController = TextEditingController();

    String selectedProtocol = config.protocol;
    String selectedTransport = config.transport;
    String selectedSecurity = config.security;
    String selectedFingerprint = config.fingerprint.isEmpty ? 'chrome' : config.fingerprint;
    String selectedAlpn = config.alpn.isEmpty ? 'http/1.1' : config.alpn;
    bool allowInsecure = config.allowInsecure;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF151824),
              title: Row(
                children: [
                  Icon(Icons.edit_rounded, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Text('ویرایش پیکربندی سرور (VLESS / Trojan)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 600,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('پروتکل اتصال:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(width: 16),
                          DropdownButton<String>(
                            value: selectedProtocol,
                            dropdownColor: const Color(0xFF0F111A),
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            underline: const SizedBox(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedProtocol = val);
                              }
                            },
                            items: ['vless', 'trojan'].map((p) => DropdownMenuItem(value: p, child: Text(p.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 24),
                      
                      _buildDialogField('نام مستعار (Alias / Remarks)', aliasController),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(flex: 3, child: _buildDialogField('آدرس سرور (Address)', addressController)),
                          const SizedBox(width: 12),
                          Expanded(flex: 1, child: _buildDialogField('پورت (Port)', portController, isNumeric: true)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField('شناسه کاربر (UUID / Password)', uuidController),
                      const SizedBox(height: 12),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('پروتکل انتقال (Transport):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedTransport,
                            dropdownColor: const Color(0xFF0F111A),
                            underline: const SizedBox(),
                            style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedTransport = val);
                              }
                            },
                            items: ['ws', 'tcp', 'grpc', 'http'].map((t) => DropdownMenuItem(value: t, child: Text(t.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),

                      _buildDialogField('میزبان وب‌ساکت (Host)', hostController),
                      const SizedBox(height: 12),
                      _buildDialogField('مسیر وب‌ساکت (Path)', pathController),
                      const SizedBox(height: 12),

                      const Divider(color: Colors.white12, height: 24),
                      const Text('تنظیمات امنیت لایه اتصال (TLS)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
                      const SizedBox(height: 12),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('نوع امنیت (Security):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedSecurity,
                            dropdownColor: const Color(0xFF0F111A),
                            underline: const SizedBox(),
                            style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedSecurity = val);
                              }
                            },
                            items: ['tls', 'reality', 'none'].map((s) => DropdownMenuItem(value: s, child: Text(s.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),

                      _buildDialogField('نام سرور امن (SNI)', sniController),
                      const SizedBox(height: 12),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('اثر انگشت مرورگر (Fingerprint):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedFingerprint,
                            dropdownColor: const Color(0xFF0F111A),
                            underline: const SizedBox(),
                            style: const TextStyle(fontSize: 12, color: Colors.white),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedFingerprint = val);
                              }
                            },
                            items: ['chrome', 'firefox', 'safari', 'edge', 'randomized'].map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('پروتکل ALPN:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedAlpn,
                            dropdownColor: const Color(0xFF0F111A),
                            underline: const SizedBox(),
                            style: const TextStyle(fontSize: 12, color: Colors.white),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedAlpn = val);
                              }
                            },
                            items: ['http/1.1', 'h2', 'http/1.1,h2'].map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),

                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('نادیده گرفتن خطای گواهی امنیتی (Allow Insecure)', style: TextStyle(fontSize: 12)),
                        value: allowInsecure,
                        activeColor: const Color(0xFF6C5DD3),
                        onChanged: (val) {
                          setDialogState(() => allowInsecure = val);
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField('EchConfigList', echController),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('انصراف', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () {
                    final updatedConfig = V2rayConfig(
                      protocol: selectedProtocol,
                      alias: aliasController.text.trim(),
                      address: addressController.text.trim(),
                      port: int.tryParse(portController.text.trim()) ?? 443,
                      uuidOrPassword: uuidController.text.trim(),
                      transport: selectedTransport,
                      host: hostController.text.trim(),
                      path: pathController.text.trim(),
                      security: selectedSecurity,
                      sni: sniController.text.trim(),
                      fingerprint: selectedFingerprint,
                      alpn: selectedAlpn,
                      allowInsecure: allowInsecure,
                    );

                    setState(() {
                      _savedNodes[index] = ProxyNode(
                        name: updatedConfig.alias,
                        protocol: updatedConfig.protocol,
                        rawUrl: updatedConfig.toRawUrl(),
                      );
                      if (_selectedNode == node) {
                        _selectedNode = _savedNodes[index];
                      }
                      _statusMessage = "تنظیمات سرور '${updatedConfig.alias}' با موفقیت به‌روزرسانی شد.";
                    });
                    Navigator.of(context).pop();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C5DD3)),
                  child: const Text('ثبت تغییرات', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildDialogField(String label, TextEditingController controller, {bool isNumeric = false, String hint = ''}) {
    return TextField(
      controller: controller,
      keyboardType: isNumeric ? TextInputType.number : TextInputType.text,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint.isNotEmpty ? hint : null,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  // فرآیند استارت سرویس بومی VPN در اندروید
  Future<void> _startAndroidVpn(String configJson) async {
    try {
      final String result = await _androidVpnChannel.invokeMethod('startVpn', {
        'config': configJson,
      });
      setState(() {
        _statusMessage = result;
      });
    } catch (e) {
      setState(() {
        _statusMessage = "خطا در برقراری ارتباط با VPN اندروید: $e";
      });
    }
  }

  // فرآیند متوقف کردن سرویس بومی VPN در اندروید
  Future<void> _stopAndroidVpn() async {
    try {
      final String result = await _androidVpnChannel.invokeMethod('stopVpn');
      setState(() {
        _statusMessage = result;
      });
    } catch (e) {
      setState(() {
        _statusMessage = "خطا در قطع VPN اندروید: $e";
      });
    }
  }

  // تست زنده پینگ دی‌ان‌اس انتخابی روی پورت ۵۳
  Future<void> _testDnsPing() async {
    setState(() {
      _isPingingDns = true;
      _dnsPing = null;
    });

    try {
      final ping = await pingDnsServer(ip: _selectedDns.primary);
      setState(() {
        _dnsPing = ping >= 0 ? ping : null;
        _isPingingDns = false;
      });
    } catch (e) {
      setState(() {
        _isPingingDns = false;
      });
    }
  }

  // راه‌اندازی و افزودن منوی راست‌کلیک بومی کنار ساعت با آدرس مطلق پویا و بدون خطا
  Future<void> _initSystemTray() async {
    String iconPath = 'assets/app_icon.ico';
    
    if (kReleaseMode) {
      // ساخت آدرس فیزیکی و مطلق آیکون نسبت به محل اجرای فایل .exe جهت لود قطعی در ویندوز
      final String exePath = Platform.resolvedExecutable;
      final String exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
      iconPath = '$exeDir\\data\\flutter_assets\\assets\\app_icon.ico';
    }

    await trayManager.setIcon(iconPath); 
    await trayManager.setToolTip('RedCloud VPN');

    List<MenuItem> items = [
      MenuItem(
        key: 'show_window',
        label: 'باز کردن برنامه',
      ),
      MenuItem.separator(), // خط جداساز میانی منو
      MenuItem(
        key: 'exit_app',
        label: 'خروج کامل',
      ),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  // شنونده: متوقف کردن فرآیند بسته‌شدن و مخفی کردن پنجره به جایش
  @override
  void onWindowClose() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide(); // مخفی کردن پنجره به جای بستن کامل ترافیک پروکسی
      setState(() {
        _statusMessage = "برنامه در پس‌زمینه و کنار ساعت ویندوز فعال است.";
      });
    }
  }

  // شنونده: پاسخ به کلیک روی منوهای راست‌کلیک کنار ساعت ویندوز
  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      // ۱. ابتدا اتصالات در حال اجرا را به طور ایمن قطع کن
      if (_isProxyRunning) await stopProxyCore();
      if (_isTorRunning) await stopTorCore();
      if (_isPsiphonRunning) await stopPsiphonCore();
      if (_isDnsRunning) await resetSystemDns();

      // ۲. پراکسی سیستم را ریست کن و سیستم تری را آزاد کن
      await trayManager.destroy();
      
      // ۳. برنامه را کاملاً ببند
      await windowManager.destroy(); 
    }
  }

  // شنونده: باز کردن برنامه به محض کلیک چپ روی آیکون ساعت
  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  // شنونده بومی بسیار حیاتی برای ویندوز: به محض راست‌کلیک، منوی کشویی contextMenu را پاپ‌آپ کن
  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  Future<void> _checkStatus() async {
    final activeProxy = await isConnected();
    final activeTor = await isTorConnected();
    final activePsiphon = await isPsiphonConnected();
    final activeDns = await isDnsActive();
    setState(() {
      _isProxyRunning = activeProxy;
      _isTorRunning = activeTor;
      _isPsiphonRunning = activePsiphon;
      _isDnsRunning = activeDns;
      
      if (activeProxy) {
        _statusMessage = "متصل به سرور ویتوری";
        _startTrafficMonitoring(); // آغاز به کار مانیتور سرعت زنده به محض فعال شدن استاتوس
        _fetchIpInfo();
      } else if (activeTor) {
        _statusMessage = "متصل به شبکه پیاز تور";
        _fetchIpInfo();
      } else if (activePsiphon) {
        _statusMessage = "متصل به شبکه سایفون";
        _fetchIpInfo();
      } else if (activeDns) {
        _statusMessage = "تنظیمات دی‌ان‌اس بر روی سیستم فعال است.";
      } else {
        _statusMessage = "قطع اتصال";
      }
    });
  }

  // دریافت و استعلام اطلاعات آی‌پی و موقعیت جغرافیایی سرور پروکسی متصل شده
  Future<void> _fetchIpInfo() async {
    if (!_isProxyRunning && !_isTorRunning && !_isPsiphonRunning) return;

    setState(() {
      _isLoadingIpInfo = true;
      _publicIp = null;
      _countryCode = null;
      _countryName = null;
      _cityName = null;
    });

    try {
      final response = await http
          .get(Uri.parse('https://freeipapi.com/api/json/'))
          .timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _publicIp = data['ipAddress']; 
          _countryCode = data['countryCode']; 
          _countryName = data['countryName']; 
          _cityName = data['cityName']; 
          _isLoadingIpInfo = false;
        });
      } else {
        throw Exception();
      }
    } catch (e) {
      setState(() {
        _isLoadingIpInfo = false;
        _statusMessage = "خطا در استعلام موقعیت جغرافیایی. دکمه رفرش را بزنید.";
      });
    }
  }

  // متد دریافت و پارس هوشمند اکانت‌ها از گیت‌هاب
  Future<void> _fetchGithubAccounts() async {
    setState(() {
      _isLoadingAccounts = true;
      _statusMessage = "در حال دریافت لیست اکانت‌ها از گیت‌هاب...";
    });

    try {
      final response = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/Devtahas/CG_BPB/refs/heads/main/accounts.txt'
      ));

      if (response.statusCode == 200) {
        final rawText = response.body;
        final lines = rawText.split('\n');
        
        List<VlessAccount> parsedList = [];
        String? currentWorker;
        String? currentUuid;
        String? currentPath;

        for (var line in lines) {
          final trimmedLine = line.trim();
          if (trimmedLine.isEmpty) continue;

          final colonIndex = trimmedLine.indexOf(':');
          if (colonIndex == -1) continue;

          final key = trimmedLine.substring(0, colonIndex).trim().toLowerCase();
          final value = trimmedLine.substring(colonIndex + 1).trim();

          if (key == 'worker') {
            currentWorker = value;
          } else if (key == 'uuid') {
            currentUuid = value;
          } else if (key == 'path') {
            currentPath = value;
          }

          if (currentWorker != null && currentUuid != null && currentPath != null) {
            parsedList.add(VlessAccount(
              worker: currentWorker,
              uuid: currentUuid,
              path: currentPath,
              name: '',
            ));
            currentWorker = null;
            currentUuid = null;
            currentPath = null;
          }
        }

        if (parsedList.isEmpty) {
          throw Exception("هیچ اکانت معتبری در فایل یافت نشد.");
        }

        parsedList.shuffle();
        final selectedRandoms = parsedList.take(5).toList();

        List<VlessAccount> finalAccounts = [];
        for (int i = 0; i < selectedRandoms.length; i++) {
          finalAccounts.add(VlessAccount(
            worker: selectedRandoms[i].worker,
            uuid: selectedRandoms[i].uuid,
            path: selectedRandoms[i].path,
            name: 'اکانت ${i + 1}',
          ));
        }

        setState(() {
          _githubAccounts = finalAccounts;
          _isLoadingAccounts = false;
          _statusMessage = "تعداد ${_githubAccounts.length} اکانت رندوم با موفقیت بارگذاری شد.";
          
          if (_githubAccounts.isNotEmpty) {
            _selectAccount(_githubAccounts.first);
          }
        });

      } else {
        throw Exception("خطا در پاسخ سرور گیت‌هاب: کد ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        _isLoadingAccounts = false;
        _statusMessage = "خطا در دریافت اکانت‌ها: $e";
      });
    }
  }

  void _selectAccount(VlessAccount account) {
    setState(() {
      _selectedGithubAccount = account;
      _uuidController.text = account.uuid;
      _workerController.text = account.worker;
      _pathController.text = account.path;
      _statusMessage = "اطلاعات ${account.name} روی فیلدهای ورودی اعمال گردید.";
    });
  }

  Future<void> _startCloudflareScanning() async {
    if (_uuidController.text.isEmpty || _pathController.text.isEmpty || _workerController.text.isEmpty) {
      setState(() => _statusMessage = "خطا: لطفاً ابتدا اطلاعات اکانت را پر یا دریافت کنید.");
      return;
    }

    setState(() {
      _isScanning = true;
      _statusMessage = "در حال شروع اسکن چندنخی آی‌پی‌های ترانزیت کلودفلر...";
    });

    try {
      final cleanNodes = await runCloudflareScanner(
        uuid: _uuidController.text.trim(),
        path: _pathController.text.trim(),
        worker: _workerController.text.trim(),
      );

      setState(() {
        _isScanning = false;
        if (cleanNodes.isEmpty) {
          _statusMessage = "اسکن پایان یافت؛ هیچ آی‌پی تمیزی با پینگ مناسب پیدا نشد.";
        } else {
          _statusMessage = "اسکن پایان یافت! تعداد ${cleanNodes.length} آی‌پی تمیز و پرسرعت یافت شد.";
          
          _savedNodes.removeWhere((n) => n.name.startsWith("From Scanner"));
          for (var node in cleanNodes) {
            _savedNodes.add(ProxyNode(
              name: node.name.replaceAll("Scanner", "From Scanner"),
              protocol: node.protocol,
              rawUrl: node.rawUrl,
            ));
          }
          _selectedNode = _savedNodes.firstWhere((n) => n.name.startsWith("From Scanner"));
        }
      });
    } catch (e) {
      setState(() {
        _isScanning = false;
        _statusMessage = "خطا در فرآیند اسکن: $e";
      });
    }
  }

  Future<void> _importConfigOrSub() async {
    final text = _importController.text.trim();
    if (text.isEmpty) return;

    setState(() => _statusMessage = "در حال پردازش ورودی...0");

    try {
      String rawContent = text;

      if (text.startsWith("http://") || text.startsWith("https://")) {
        final response = await http.get(Uri.parse(text));
        if (response.statusCode == 200) {
          rawContent = response.body;
        } else {
          throw Exception("خطا در دانلود ساب: کد وضعیت ${response.statusCode}");
        }
      }

      final parsedNodes = await parseImportLinks(input: rawContent);

      setState(() {
        _savedNodes.addAll(parsedNodes);
        _importController.clear();
        _statusMessage = "تعداد ${parsedNodes.length} سرور با موفقیت اضافه شد.";
        _selectedNode ??= _savedNodes.first;
      });
    } catch (e) {
      setState(() {
        _statusMessage = "خطا در اضافه کردن ورودی: ${e.toString()}";
      });
    }
  }

  // ۱. متد اتصال اختصاصی سرورهای V2Ray (داشبورد) - مجهز به تفکیک پلتفرم اندروید و ویندوز
  Future<void> _toggleV2RayConnection() async {
    try {
      if (Platform.isWindows) {
        // الف) سناریوی سیستم‌عامل ویندوز دسکتاپ
        if (_isProxyRunning) {
          final msg = await stopProxyCore();
          _stopTrafficMonitoring(); // قطع زنده پایش سرعت به محض خاموش شدن پروکسی
          setState(() {
            _isProxyRunning = false;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_selectedNode == null) {
            setState(() => _statusMessage = "خطا: لطفاً ابتدا یک سرور را از بخش پیکربندی انتخاب کنید.");
            return;
          }

          if (_isTorRunning || _isTorConnecting) {
            _torProgressTimer?.cancel();
            await stopTorCore();
            setState(() {
              _isTorRunning = false;
              _isTorConnecting = false;
              _torProgressPercent = 0;
            });
          }
          if (_isPsiphonRunning) {
            await stopPsiphonCore();
            setState(() => _isPsiphonRunning = false);
          }

          // ارسال آرگومان‌های جدید Anti-DPI و TUN به تابع راست دسکتاپ
          final msg = await startProxyWithNode(
            binaryPath: _binaryPathController.text,
            selectedNode: _selectedNode!,
            useSystemProxy: _useSystemProxy,
            customSni: _customSniController.text.trim().isEmpty ? null : _customSniController.text.trim(),
            enableFragment: _enableFragment,
            enableRecordFragment: _enableRecordFragment,
            tlsSpoof: _tlsSpoofController.text.trim().isEmpty ? null : _tlsSpoofController.text.trim(),
            useTunMode: _useTunMode, // ارسال پارامتر جدید شبکه مجازی به Rust
          );

          setState(() {
            _isProxyRunning = true;
            _statusMessage = msg;
          });

          // ۲ ثانیه مکث برای لود کامل هسته و سپس فعال‌سازی استریم سرعت زنده
          Future.delayed(const Duration(seconds: 2), () {
            if (_isProxyRunning) {
              _startTrafficMonitoring();
            }
          });

          _fetchIpInfo();
        }
      } else if (Platform.isAndroid) {
        // ب) سناریوی سیستم‌عامل بومی اندروید گوشی
        if (_isProxyRunning) {
          await _stopAndroidVpn();
          setState(() {
            _isProxyRunning = false;
            _resetIpInfo();
          });
        } else {
          if (_selectedNode == null) {
            setState(() => _statusMessage = "خطا: لطفاً ابتدا یک سرور انتخاب کنید.");
            return;
          }
          
          // ساخت کانفیگ داینامیک و ارسال آن به بستر بومی اندروید
          await _startAndroidVpn(_selectedNode!.rawUrl);
          setState(() {
            _isProxyRunning = true;
          });
        }
      }
    } catch (e) {
      setState(() => _statusMessage = "خطا در اتصال ویتوری: ${e.toString()}");
    }
  }

  // ۲. متد اتصال اختصاصی و هوشمند شبکه پیاز تور - مجهز به تفکیک پلتفرم اندروید و ویندوز
  Future<void> _toggleTorConnection() async {
    try {
      if (Platform.isWindows) {
        // الف) سناریوی سیستم‌عامل ویندوز دسکتاپ
        if (_isTorRunning || _isTorConnecting) {
          _torProgressTimer?.cancel();
          final msg = await stopTorCore();
          setState(() {
            _isTorRunning = false;
            _isTorConnecting = false;
            _torProgressPercent = 0;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_isProxyRunning) {
            await stopProxyCore();
            setState(() => _isProxyRunning = false);
          }
          if (_isPsiphonRunning) {
            await stopPsiphonCore();
            setState(() => _isPsiphonRunning = false);
          }

          final countryCode = _torCountries[_selectedTorCountry] ?? "";
          
          setState(() {
            _isTorConnecting = true;
            _torProgressPercent = 0;
            _statusMessage = "در حال اجرای هسته تور؛ پایش خروجی شبکه پیاز آغاز شد...";
          });
          
          await startTorCore(
            binaryPath: _torPathController.text,
            countryCode: countryCode,
            useSystemProxy: _useSystemProxy,
          );

          _torProgressTimer?.cancel();
          _torProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (!_isTorConnecting) {
              timer.cancel();
              return;
            }

            final percent = await getTorBootstrapProgress();
            setState(() {
              _torProgressPercent = percent;
              _statusMessage = "پیشرفت اتصال پیاز تور: $percent٪";
            });

            if (percent >= 100) {
              timer.cancel();
              setState(() {
                _isTorRunning = true;
                _isTorConnecting = false;
                _statusMessage = "اتصال به شبکه تور ۱۰۰٪ پایدار شد!";
              });
              _fetchIpInfo(); 
            }
          });
        }
      } else if (Platform.isAndroid) {
        // ب) سناریوی سیستم‌عامل بومی اندروید گوشی برای تور
        setState(() {
          _statusMessage = "شبکه تور در پلتفرم اندروید در دست توسعه است.";
        });
      }
    } catch (e) {
      _torProgressTimer?.cancel();
      setState(() {
        _isTorConnecting = false;
        _isTorRunning = false;
        _torProgressPercent = 0;
        _statusMessage = "خطا در اتصال تور: ${e.toString()}";
      });
    }
  }

  // ۳. متد اتصال اختصاصی و هوشمند شبکه سایفون دسکتاپ با پایش پیشرفت واقعی
  Future<void> _togglePsiphonConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isPsiphonRunning || _isPsiphonConnecting) {
          _psiphonProgressTimer?.cancel();
          final msg = await stopPsiphonCore();
          setState(() {
            _isPsiphonRunning = false;
            _isPsiphonConnecting = false;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          // تداخل‌سنجی هوشمند: خاموش کردن بقیه پورت‌های متداخل
          if (_isProxyRunning) {
            await stopProxyCore();
            _isProxyRunning = false;
          }
          if (_isTorRunning || _isTorConnecting) {
            _torProgressTimer?.cancel();
            await stopTorCore();
            _isTorRunning = false;
            _isTorConnecting = false;
            _torProgressPercent = 0;
          }

          final countryCode = _psiphonCountries[_selectedPsiphonCountry] ?? "";
          
          setState(() {
            _isPsiphonConnecting = true;
            _statusMessage = "در حال اتصال به هسته سایفون و ثبت مدار...";
          });

          final msg = await startPsiphonCore( // فراخوانی بومی به صورت شتری
            binaryPath: _psiphonPathController.text,
            countryCode: countryCode,
            useSystemProxy: _useSystemProxy,
          );

          // راه‌اندازی تایمر پایش برای استعلام تایید نهایی اتصال واقعی سایفون از راست
          _psiphonProgressTimer?.cancel();
          _psiphonProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (!_isPsiphonConnecting) {
              timer.cancel();
              return;
            }

            final isDone = await isPsiphonBootstrapDone();
            if (isDone) {
              timer.cancel();
              setState(() {
                _isPsiphonRunning = true;
                _isPsiphonConnecting = false;
                _statusMessage = "اتصال با موفقیت به شبکه سایفون برقرار شد!";
              });
              _fetchIpInfo(); // استعلام پرچم و موقعیت آی‌پی سایفون
            }
          });
        }
      } else if (Platform.isAndroid) {
        setState(() => _statusMessage = "سایفون در پلتفرم اندروید در دست توسعه است.");
      }
    } catch (e) {
      _psiphonProgressTimer?.cancel();
      setState(() {
        _isPsiphonConnecting = false;
        _isPsiphonRunning = false;
        _statusMessage = "خطا در اتصال سایفون: ${e.toString()}";
      });
    }
  }

  // ۴. متد اعمال یا بازنشانی دی‌ان‌اس هوشمند روی کارت شبکه بومی ویندوز
  Future<void> _toggleDnsConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isDnsRunning) {
          final msg = await resetSystemDns();
          setState(() {
            _isDnsRunning = false;
            _statusMessage = msg;
          });
        } else {
          setState(() => _statusMessage = "در حال اعمال تنظیمات دی‌ان‌اس روی کارت شبکه...");
          
          final msg = await setSystemDns(
            primary: _selectedDns.primary,
            secondary: _selectedDns.secondary,
          );

          setState(() {
            _isDnsRunning = true;
            _statusMessage = msg;
          });
        }
      } else if (Platform.isAndroid) {
        setState(() {
          _statusMessage = "تغییر دهنده دی‌ان‌اس در پلتفرم اندروید در دست توسعه است.";
        });
      }
    } catch (e) {
      setState(() {
        _isDnsRunning = false;
        _statusMessage = "خطا: $e \nمطمئن شوید برنامه را به عنوان Administrator اجرا کرده‌اید.";
      });
    }
  }

  void _resetIpInfo() {
    setState(() {
      _publicIp = null;
      _countryCode = null;
      _countryName = null;
      _cityName = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 240,
            color: const Color(0xFF151824),
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, // تراز ستون سایدبار
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.shield_rounded, color: Theme.of(context).colorScheme.primary, size: 28),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'RedCloud', // تغییر برند و نام اصلی بالای سایدبار به RedCloud
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.2),
                    ),
                  ],
                ),
                const SizedBox(height: 48),
                _buildSidebarItem(0, Icons.dashboard_rounded, 'داشبورد ویتوری'), // ویرایش نام زبانه به داشبورد
                const SizedBox(height: 12),
                _buildSidebarItem(1, Icons.tune_rounded, 'پیکربندی و سرورها'),
                const SizedBox(height: 12),
                _buildSidebarItem(2, Icons.blur_circular_rounded, 'شبکه پیاز تور (Tor)'),
                const SizedBox(height: 12),
                _buildSidebarItem(3, Icons.security_rounded, 'شبکه سایفون (Psiphon)'), // زبانه مستقل جدید سایفون
                const SizedBox(height: 12),
                _buildSidebarItem(4, Icons.radar_rounded, 'اسکنر کلودفلر'),
                const SizedBox(height: 12),
                _buildSidebarItem(5, Icons.dns_rounded, 'تغییر دهنده DNS'), // زبانه کاملاً مستقل دی‌ان‌اس
                const SizedBox(height: 12),
                _buildSidebarItem(6, Icons.settings_rounded, 'تنظیمات برنامه'),
                const Spacer(),
                const Padding(
                  padding: EdgeInsets.only(left: 8.0),
                  child: Text('نسخه اسکنر ۲.۵', style: TextStyle(color: Colors.grey, fontSize: 12)),
                )
              ],
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(32),
              child: _buildSelectedPage(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarItem(int index, IconData icon, String title) {
    final isSelected = _selectedMenuIndex == index;
    return InkWell(
      onTap: () => setState(() => _selectedMenuIndex = index),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? Theme.of(context).colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? Colors.white : Colors.grey[400], size: 20),
            const SizedBox(width: 16),
            // پیچیدن متن در ویجت Expanded برای محدود کردن عرض متن و جلوگیری از خطای سرریز
            Expanded(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis, // قرار دادن سه نقطه در صورت بلند بودن متن
                maxLines: 1,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[400],
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13, // سایز فونت سایدبار را به ۱۳ تغییر دادیم تا شیک‌تر و منظم‌تر شود
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedPage() {
    switch (_selectedMenuIndex) {
      case 0:
        return _buildDashboardPage();
      case 1:
        return _buildConfigPage();
      case 2:
        return _buildTorPage();
      case 3:
        return _buildPsiphonPage(); // بارگذاری زبانه سایفون
      case 4:
        return _buildScannerPage();
      case 5:
        return _buildDnsPage(); // بارگذاری صفحه مستقل دی‌ان‌اس
      case 6:
        return _buildSettingsPage();
      default:
        return _buildDashboardPage();
    }
  }

  Widget _buildDashboardPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('داشبورد ویتوری', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)), // ویرایش عنوان صفحه اصلی به داشبورد ویتوری
        const Text('مدیریت وضعیت اتصال و کنترل پراکسی بومی سرورهای ویتوری', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 40),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _toggleV2RayConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF151824),
                            border: Border.all(
                              color: _isProxyRunning ? const Color(0xFF2DCA73) : const Color(0xFF6C5DD3).withOpacity(0.5),
                              width: 4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _isProxyRunning 
                                    ? const Color(0xFF2DCA73).withOpacity(0.3) 
                                    : const Color(0xFF6C5DD3).withOpacity(0.15),
                                blurRadius: 40,
                                spreadRadius: 10,
                              )
                            ],
                          ),
                          child: Icon(
                            Icons.power_settings_new_rounded,
                            size: 80,
                            color: _isProxyRunning ? const Color(0xFF2DCA73) : Colors.grey[600],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isProxyRunning ? 'متصل به ویتوری' : 'جهت اتصال ویتوری ضربه بزنید',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, 
                          fontWeight: FontWeight.bold,
                          color: _isProxyRunning ? const Color(0xFF2DCA73) : Colors.grey[400]
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: _buildStatCard('دانلود', _downloadSpeed, Icons.arrow_downward_rounded, Colors.blueAccent)), // دریافت و نمایش سرعت زنده دانلود واقعی
                          const SizedBox(width: 16),
                          Expanded(child: _buildStatCard('آپلود', _uploadSpeed, Icons.arrow_upward_rounded, Colors.orangeAccent)), // دریافت و نمایش سرعت زنده آپلود واقعی
                        ],
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151824),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SwitchListTile(
                          title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeColor: const Color(0xFF6C5DD3),
                          onChanged: _useTunMode ? null : (bool value) { // در صورت فعال بودن TUN، تنظیم پروکسی سیستم‌عامل غیرفعال می‌شود
                            setState(() {
                              _useSystemProxy = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      // سوئیچ جدید نئونی برای فعال‌سازی کارت شبکه مجازی (TUN Mode)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151824),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: SwitchListTile(
                          title: const Text('فعال‌سازی کارت شبکه مجازی (TUN Mode)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('عبور ترافیک کل سیستم (حتی بازی‌ها و برنامه‌های بدون پروکسی)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useTunMode,
                          activeColor: const Color(0xFF6C5DD3),
                          onChanged: (bool value) {
                            setState(() {
                              _useTunMode = value;
                              if (value) {
                                _useSystemProxy = false; // هنگام فعال‌سازی TUN، نیازی به ثبت پروکسی سیستم نیست
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      // پنل کشویی پیشرفته تنظیمات دور زدن فیلترینگ (Anti-DPI)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151824),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ExpansionTile(
                          title: const Text('تنظیمات دور زدن فیلترینگ (Anti-DPI)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('اعمال تکنیک‌های جعل SNI و قطعه‌بندی ترافیک', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          leading: const Icon(Icons.security_rounded, color: Colors.amberAccent, size: 20),
                          shape: const Border(), // حذف حاشیه پیش‌فرض ExpansionTile
                          childrenPadding: const EdgeInsets.only(bottom: 16, left: 8, right: 8),
                          children: [
                            const SizedBox(height: 8),
                            // ۱. فیلد ورودی Custom SNI
                            TextField(
                              controller: _customSniController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'SNI سفارشی (مثلاً: www.microsoft.com)',
                                hintStyle: TextStyle(color: Colors.white24),
                                hintText: 'خالی بگذارید تا از SNI پیش‌فرض استفاده شود',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),
                            
                            // ۲. فیلد ورودی TLS Spoof
                            TextField(
                              controller: _tlsSpoofController,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                labelText: 'SNI جعلی برای TLS Spoof (ویژه sing-box 1.14+)',
                                hintStyle: TextStyle(color: Colors.white24),
                                hintText: 'تزریق ClientHelloی فیک برای فریب DPI (مثلاً: zoom.us)',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 12),

                            // ۳. کلیدهای فعال‌سازی Fragmentation
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('فعال‌سازی قطعه‌بندی (TLS Fragmentation)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              subtitle: const Text('تکه‌تکه کردن پکت ClientHello برای عبور از سد فیلترینگ', style: TextStyle(fontSize: 10, color: Colors.grey)),
                              value: _enableFragment,
                              activeColor: const Color(0xFF6C5DD3),
                              onChanged: (bool value) {
                                setState(() {
                                    _enableFragment = value;
                                });
                              },
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('فعال‌سازی Record Fragmentation', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              subtitle: const Text('تکه‌تکه کردن داده‌ها در سطح رکورد TLS جهت پایداری بیشتر', style: TextStyle(fontSize: 10, color: Colors.grey)),
                              value: _enableRecordFragment,
                              activeColor: const Color(0xFF6C5DD3),
                              onChanged: (bool value) {
                                setState(() {
                                  _enableRecordFragment = value;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151824),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: Colors.white10,
                              child: Icon(Icons.dns_rounded, color: Colors.amberAccent, size: 20),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('سرور فعال برای اتصال', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Text(
                                    _selectedNode?.name ?? "سروری انتخاب نشده است", 
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            )
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151824),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline_rounded, color: Colors.grey[400], size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _statusMessage, 
                                style: const TextStyle(color: Colors.grey, fontSize: 13, fontFamily: 'monospace'),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTorPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('شبکه پیاز تور (Tor Network)', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Text('اتصال ایمن و گمنام به شبکه جهانی تور همراه با قابلیت تغییر داینامیک کشور خروجی', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 40),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center, // تراز وسط دکمه پاور تور
                    children: [
                      GestureDetector(
                        onTap: _toggleTorConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF151824),
                            border: Border.all(
                              color: (_isTorRunning || _isTorConnecting) ? const Color(0xFF2DCA73) : const Color(0xFF6C5DD3).withOpacity(0.5),
                              width: 4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (_isTorRunning || _isTorConnecting)
                                    ? const Color(0xFF2DCA73).withOpacity(0.3) 
                                    : const Color(0xFF6C5DD3).withOpacity(0.15),
                                blurRadius: 40,
                                spreadRadius: 10,
                              )
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.blur_circular_rounded, 
                                size: 80,
                                color: (_isTorRunning || _isTorConnecting) ? const Color(0xFF2DCA73) : Colors.grey[600],
                              ),
                              if (_isTorConnecting)
                                SizedBox(
                                  width: 140,
                                  height: 140,
                                  child: CircularProgressIndicator(
                                    value: _torProgressPercent / 100.0,
                                    strokeWidth: 4,
                                    color: const Color(0xFF2DCA73),
                                    backgroundColor: Colors.white10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isTorRunning 
                            ? 'متصل به شبکه پیاز' 
                            : _isTorConnecting 
                                ? 'در حال اتصال به مدار پیاز: $_torProgressPercent٪' 
                                : 'جهت اتصال به تور ضربه بزنید',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, 
                          fontWeight: FontWeight.bold,
                          color: (_isTorRunning || _isTorConnecting) ? const Color(0xFF2DCA73) : Colors.grey[400]
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.public_rounded, color: Colors.amberAccent, size: 20),
                              SizedBox(width: 12),
                              Text('کشور خروجی (Exit Node):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          DropdownButton<String>(
                            value: _selectedTorCountry,
                            dropdownColor: const Color(0xFF151824),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            onChanged: _isTorConnecting || _isTorRunning ? null : (String? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedTorCountry = newValue;
                                  _statusMessage = "کشور خروجی تور به $newValue تغییر کرد.";
                                });
                              }
                            },
                            items: _torCountries.keys.map<DropdownMenuItem<String>>((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                          )
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SwitchListTile(
                        title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        value: _useSystemProxy,
                        activeColor: const Color(0xFF6C5DD3),
                        onChanged: (bool value) {
                          setState(() {
                            _useSystemProxy = value;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildLocationCard(), 
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.grey[400], size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusMessage, 
                              style: const TextStyle(color: Colors.grey, fontSize: 13, fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // صفحه مستقل جدید: شبکه سایفون (Psiphon Network Page)
  Widget _buildPsiphonPage() {
    final bool isPsiphonActive = _isPsiphonRunning;
    final bool isPsiphonLoading = _isPsiphonConnecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('شبکه سایفون (Psiphon Network)', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Text('اتصال آسان به فیلترشکن سایفون همراه با امکان انتخاب داینامیک کشور خروجی', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 40),
        Expanded(
          child: Row(
            children: [
              // دکمه پاور اختصاصی نئونی سایفون به همراه دایره لودینگ متحرک پیشرفت واقعی
              Expanded(
                flex: 4,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _togglePsiphonConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF151824),
                            border: Border.all(
                              color: (isPsiphonActive || isPsiphonLoading) ? const Color(0xFF2DCA73) : const Color(0xFF6C5DD3).withOpacity(0.5),
                              width: 4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (isPsiphonActive || isPsiphonLoading)
                                    ? const Color(0xFF2DCA73).withOpacity(0.3) 
                                    : const Color(0xFF6C5DD3).withOpacity(0.15),
                                blurRadius: 40,
                                spreadRadius: 10,
                              )
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.security_rounded, // آیکون سپر امنیتی سایفون
                                size: 80,
                                color: (isPsiphonActive || isPsiphonLoading) ? const Color(0xFF2DCA73) : Colors.grey[600],
                              ),
                              if (isPsiphonLoading)
                                const SizedBox(
                                  width: 140,
                                  height: 140,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 4,
                                    color: Color(0xFF2DCA73),
                                    backgroundColor: Colors.white10,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        isPsiphonActive 
                            ? 'متصل به سایفون' 
                            : isPsiphonLoading 
                                ? 'در حال اتصال به سرورهای سایفون...' 
                                : 'جهت اتصال به سایفون ضربه بزنید',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, 
                          fontWeight: FontWeight.bold,
                          color: (isPsiphonActive || isPsiphonLoading) ? const Color(0xFF2DCA73) : Colors.grey[400]
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // دراپ‌داون انتخاب کشور خروجی سایفون (Exit Region)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.public_rounded, color: Colors.amberAccent, size: 20),
                              SizedBox(width: 12),
                              Text('کشور خروجی (Exit Node):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          DropdownButton<String>(
                            value: _selectedPsiphonCountry,
                            dropdownColor: const Color(0xFF151824),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            onChanged: _isPsiphonRunning || _isPsiphonConnecting ? null : (String? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedPsiphonCountry = newValue;
                                  _statusMessage = "کشور خروجی سایفون به $newValue تغییر کرد.";
                                });
                              }
                            },
                            items: _psiphonCountries.keys.map<DropdownMenuItem<String>>((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                          )
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: SwitchListTile(
                        title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                        subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                        value: _useSystemProxy,
                        activeColor: const Color(0xFF6C5DD3),
                        onChanged: _isPsiphonRunning || _isPsiphonConnecting ? null : (bool value) {
                          setState(() {
                            _useSystemProxy = value;
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildLocationCard(), // موقعیت آی‌پی سرور سایفون متصل شده
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline_rounded, color: Colors.grey[400], size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusMessage, 
                              style: const TextStyle(color: Colors.grey, fontSize: 13, fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // صفحه مستقل پنجم: تغییر دهنده دی‌ان‌اس هوشمند (DNS Changer Page)
  Widget _buildDnsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('تغییر دهنده هوشمند DNS', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Text('اعمال دی‌ان‌اس‌های تحریم‌شکن داخلی و بین‌المللی با بررسی زنده پینگ و تاخیر شبکه', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 40),
        Expanded(
          child: Row(
            children: [
              // دکمه پاور نئونی بزرگ مخصوص دی‌ان‌اس
              Expanded(
                flex: 4,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _toggleDnsConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 180,
                          height: 180,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF151824),
                            border: Border.all(
                              color: _isDnsRunning ? const Color(0xFF2DCA73) : const Color(0xFF6C5DD3).withOpacity(0.5),
                              width: 4,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _isDnsRunning 
                                    ? const Color(0xFF2DCA73).withOpacity(0.3) 
                                    : const Color(0xFF6C5DD3).withOpacity(0.15),
                                blurRadius: 40,
                                spreadRadius: 10,
                              )
                            ],
                          ),
                          child: Icon(
                            Icons.dns_rounded, 
                            size: 80,
                            color: _isDnsRunning ? const Color(0xFF2DCA73) : Colors.grey[600],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isDnsRunning ? 'دی‌ان‌اس فعال است' : 'جهت اعمال دی‌ان‌اس ضربه بزنید',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, 
                          fontWeight: FontWeight.bold,
                          color: _isDnsRunning ? const Color(0xFF2DCA73) : Colors.grey[400]
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // دراپ‌داون انتخاب دی‌ان‌اس
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.radar_rounded, color: Colors.amberAccent, size: 20),
                              SizedBox(width: 12),
                              Text('انتخاب سرویس DNS:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          DropdownButton<DnsProfile>(
                            value: _selectedDns,
                            dropdownColor: const Color(0xFF151824),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            onChanged: _isDnsRunning ? null : (DnsProfile? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedDns = newValue;
                                });
                                _testDnsPing(); // پینگ گرفتن اتوماتیک به محض تغییر گزینش
                              }
                            },
                            items: _dnsList.map<DropdownMenuItem<DnsProfile>>((DnsProfile value) {
                              return DropdownMenuItem<DnsProfile>(
                                value: value,
                                child: Text(value.name),
                              );
                            }).toList(),
                          )
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // جزئیات آی‌پی‌ها و کارت سنجش پینگ پیشرفته
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('سرور اولیه (Primary):', style: TextStyle(color: Colors.grey, fontSize: 12)),
                              Text(_selectedDns.primary, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('سرور ثانویه (Secondary):', style: TextStyle(color: Colors.grey, fontSize: 12)),
                              Text(_selectedDns.secondary, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const Divider(color: Colors.white12, height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('تاخیر پاسخگویی (Ping):', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                              _isPingingDns
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amberAccent),
                                    )
                                  : Row(
                                      children: [
                                        Text(
                                          _dnsPing != null ? '$_dnsPing ms' : 'N/A (خاموش)',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: _dnsPing != null ? const Color(0xFF2DCA73) : Colors.redAccent,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        InkWell(
                                          onTap: _isDnsRunning ? null : _testDnsPing,
                                          child: const Icon(Icons.refresh_rounded, size: 18, color: Colors.grey),
                                        )
                                      ],
                                    ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // توضیحات کارکرد دی‌ان‌اس
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: Colors.grey, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _selectedDns.description,
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF151824),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline_rounded, color: Colors.amberAccent, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusMessage, 
                              style: const TextStyle(color: Colors.grey, fontSize: 12, fontFamily: 'monospace'),
                            ),
                          ),
                        ],
                      ),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLocationCard() {
    final bool isAnyConnected = _isProxyRunning || _isTorRunning || _isPsiphonRunning;
    if (!isAnyConnected) return const SizedBox.shrink();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF151824),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
        ),
      ),
      child: _isLoadingIpInfo
          ? const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 16),
                Text(
                  'در حال استعلام هویت و موقعیت جغرافیایی سرور...',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            )
          : _publicIp == null
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'موقعیت‌یابی موقتاً با خطا مواجه شد',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, color: Colors.grey, size: 20),
                      onPressed: _fetchIpInfo,
                    )
                  ],
                )
              : Row(
                  children: [
                    if (_countryCode != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.network(
                          'https://flagcdn.com/w80/${_countryCode!.toLowerCase()}.png',
                          width: 52,
                          height: 36,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.flag, size: 28),
                        ),
                      ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                _publicIp ?? '',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'monospace',
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: () {
                                  if (_publicIp != null) {
                                    Clipboard.setData(ClipboardData(text: _publicIp!));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('آی‌پی کپی شد!'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  }
                                },
                                child: const Icon(Icons.copy_rounded, size: 14, color: Colors.grey),
                              )
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_cityName ?? "ناشناس"}، ${_countryName ?? "ناشناس"}',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh_rounded, color: Colors.grey, size: 20),
                      onPressed: _fetchIpInfo,
                    )
                  ],
                ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF151824),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withOpacity(0.15),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 4),
              Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildConfigPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('پیکربندی و سرورها', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const Text('لینک ساب یا کانفیگ تکی خود را وارد کرده و سرور فعال را انتخاب کنید', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _importController,
                decoration: const InputDecoration(
                  labelText: 'لینک ساب (https://) یا کانفیگ تکی (vless://...) یا کلید Base64',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.add_link_rounded),
                ),
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _importConfigOrSub,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.download_rounded, color: Colors.white),
              label: const Text('وارد کردن', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        
        // دکمه‌های کنترلی بالای جدول سرورها
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('لیست سرورهای ذخیره‌شده', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
            ElevatedButton.icon(
              onPressed: _isBulkPinging ? null : _bulkPingAndSort,
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                foregroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: _isBulkPinging 
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6C5DD3)))
                  : const Icon(Icons.flash_on_rounded, size: 16),
              label: Text(_isBulkPinging ? 'در حال تست پینگ...' : 'پینگ دسته‌جمعی و مرتب‌سازی'),
            ),
          ],
        ),
        const SizedBox(height: 16),

        Expanded(
          child: _savedNodes.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.dns_outlined, size: 64, color: Colors.grey[700]),
                      const SizedBox(height: 16),
                      const Text('هنوز سروری اضافه نشده است.', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF151824),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _savedNodes.length,
                    separatorBuilder: (_, __) => const Divider(color: Colors.white12),
                    itemBuilder: (context, index) {
                      final node = _savedNodes[index];
                      final isSelected = _selectedNode == node;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isSelected 
                              ? Theme.of(context).colorScheme.secondary.withOpacity(0.15) 
                              : Colors.white10,
                          child: Text(
                            node.protocol[0].toUpperCase(),
                            style: TextStyle(
                              color: isSelected ? Theme.of(context).colorScheme.secondary : Colors.grey,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          node.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? Colors.white : Colors.grey[300],
                          ),
                        ),
                        subtitle: Text(node.protocol.toUpperCase(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // نمایش تأخیر پینگ زنده در صورت موجود بودن
                            if (_nodePings[node.rawUrl] != null) ...[
                              Text(
                                _nodePings[node.rawUrl] == -1 ? "Timeout" : "${_nodePings[node.rawUrl]} ms",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _nodePings[node.rawUrl] == -1 ? Colors.redAccent : const Color(0xFF2DCA73),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            // دکمه کپی لینک کانفیگ جهت اشتراک‌گذاری
                            IconButton(
                              icon: const Icon(Icons.share_rounded, size: 16, color: Colors.grey),
                              tooltip: 'اشتراک‌گذاری کانفیگ',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: node.rawUrl));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('لینک کانفیگ با موفقیت کپی شد!')),
                                );
                              },
                            ),
                            // دکمه ویرایش دستی پارامترهای سرور
                            IconButton(
                              icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.grey),
                              tooltip: 'ویرایش پارامترها',
                              onPressed: () => _openEditDialog(node, index),
                            ),
                            if (isSelected) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF2DCA73)),
                            ]
                          ],
                        ),
                        onTap: () {
                          setState(() {
                            _selectedNode = node;
                            _statusMessage = "سرور فعال تغییر کرد به: ${node.name}";
                          });
                        },
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildScannerPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('اسکنر موازی کلودفلر (IP Scanner)', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const Text('تست دقیق TCP Ping و TLS Handshake با دامنه ورکر شما برای پیدا کردن آی‌پی‌های تمیز', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF151824),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'دریافت اطلاعات اکانت از گیت‌هاب:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  _isLoadingAccounts
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : ElevatedButton.icon(
                          onPressed: _fetchGithubAccounts,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          icon: const Icon(Icons.cloud_download_rounded, size: 18, color: Colors.white),
                          label: const Text('دریافت اکانت‌های رندوم', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                ],
              ),
              const SizedBox(height: 12),

              if (_githubAccounts.isNotEmpty)
                Container(
                  height: 45,
                  margin: const EdgeInsets.only(bottom: 24),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _githubAccounts.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final acc = _githubAccounts[index];
                      final isSel = _selectedGithubAccount == acc;
                      return ChoiceChip(
                        label: Text(acc.name, style: TextStyle(color: isSel ? Colors.white : Colors.grey)),
                        selected: isSel,
                        selectedColor: Theme.of(context).colorScheme.primary,
                        backgroundColor: const Color(0xFF0F111A),
                        onSelected: (bool selected) {
                          if (selected) {
                            _selectAccount(acc);
                          }
                        },
                      );
                    },
                  ),
                ),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),

              TextField(
                controller: _uuidController,
                decoration: const InputDecoration(
                  labelText: 'کلید شناسایی کاربر (UUID)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.vpn_key_rounded),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _workerController,
                decoration: const InputDecoration(
                  labelText: 'دامنه ورکر (Worker Domain / SNI)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.language_rounded),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _pathController,
                decoration: const InputDecoration(
                  labelText: 'مسیر کانفیگ (WebSocket Path)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.alt_route_rounded),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: _isScanning
                    ? const Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('اسکنر در حال اتصال موازی به آی‌پی‌ها و ارزیابی دست‌دهی TLS است؛ لطفاً منتظر بمانید...', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
                      )
                    : ElevatedButton.icon(
                        onPressed: _startCloudflareScanning,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF6C5DD3),
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.radar_rounded, color: Colors.white),
                        label: const Text('شروع اسکن کلودفلر', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF151824).withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('وضعیت و لاگ‌های اسکنر:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      _statusMessage,
                      style: const TextStyle(fontFamily: 'monospace', color: Colors.grey, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // اضافه شدن فیلدهای جدید تور و سایفون در بخش تنظیمات برنامه
  Widget _buildSettingsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('تنظیمات برنامه', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const Text('پیکربندی هسته سیستم و آدرس فایل‌های باینری', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF151824),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('تنظیمات آدرس هسته V2Ray', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _binaryPathController,
                decoration: const InputDecoration(
                  labelText: 'مسیر فایل هسته sing-box.exe (مثلا D:\\net\\client\\sing-box.exe)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.code_rounded),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),
              const Text('تنظیمات آدرس هسته تور (Tor)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _torPathController,
                decoration: const InputDecoration(
                  labelText: 'مسیر فایل هسته tor.exe (مثلا D:\\net\\client\\tor.exe)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.blur_circular_rounded),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),
              const Text('تنظیمات آدرس هسته سایفون (Psiphon)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: _psiphonPathController,
                decoration: const InputDecoration(
                  labelText: 'مسیر فایل هسته psiphon-tunnel-core.exe (مثلا D:\\net\\client\\psiphon-tunnel-core.exe)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.security_rounded),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),
              const Text('سیستم‌عامل مقصد فعلی: Windows', style: TextStyle(color: Colors.grey, fontSize: 13)),
            ],
          ),
        ),
      ],
    );
  }
}