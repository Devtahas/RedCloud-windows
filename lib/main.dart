import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

const String managerWorkerUrl = "https://round-sea-8418.redcloudir.workers.dev";
const String appCurrentVersion = "3.5";
const String telegramChannelUrl = "https://t.me/DevTaha_project";
const String usdtBnbAddress = "0xDeda28Aa73Ec089A77B3fC616E0011a8fce12900";
const String githubRepoReleasesUrl = "https://github.com/Devtahas/RedCloud-windows/releases/latest";

void openBrowserUrl(String url) {
  if (Platform.isWindows) {
    Process.run('cmd', ['/c', 'start', '', url]);
  } else if (Platform.isLinux) {
    Process.run('xdg-open', [url]);
  } else if (Platform.isMacOS) {
    Process.run('open', [url]);
  }
}

class VlessAccount {
  final String worker;
  final String uuid;
  final String path;
  final String name;
  final String status;
  final int usedBytes;

  VlessAccount({
    required this.worker,
    required this.uuid,
    required this.path,
    required this.name,
    required this.status,
    required this.usedBytes,
  });
}

class DnsProfile {
  final String name;
  final String primary;
  final String secondary;
  final String description;
  final String dnsType;
  final String? dohUrl;
  final String? dotHost;
  final bool isCustom;

  DnsProfile({
    required this.name,
    required this.primary,
    required this.secondary,
    required this.description,
    required this.dnsType,
    this.dohUrl,
    this.dotHost,
    this.isCustom = false,
  });
}

class V2rayConfig {
  String protocol;
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
  String publicKey;
  String shortId;
  String spiderX;
  String echConfig;

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
    this.publicKey = '',
    this.shortId = '',
    this.spiderX = '',
    this.echConfig = '',
  });

  static V2rayConfig parse(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      var protocol = uri.scheme.toLowerCase();
      if (protocol == 'hy2') protocol = 'hysteria2';
      
      final alias = Uri.decodeComponent(uri.fragment);
      final address = uri.host;
      final port = uri.port;
      final uuidOrPassword = uri.userInfo;
      
      final params = uri.queryParameters;
      final transport = params['type'] ?? 'tcp';
      final host = params['host'] ?? '';
      final path = Uri.decodeComponent(params['path'] ?? '');
      var security = params['security'] ?? 'none';
      if (params.containsKey('pbk') || params.containsKey('public_key')) {
        security = 'reality';
      }

      final sni = params['sni'] ?? params['peer'] ?? '';
      final fingerprint = params['fp'] ?? 'chrome';
      final alpn = Uri.decodeComponent(params['alpn'] ?? 'http/1.1');
      final allowInsecure = (params['insecure'] == '1' || params['allowInsecure'] == '1' || params['insecure'] == 'true');
      final publicKey = params['pbk'] ?? params['public_key'] ?? '';
      final shortId = params['sid'] ?? params['short_id'] ?? '';
      final spiderX = params['spx'] ?? params['spider_x'] ?? '';
      final echConfig = params['ech'] ?? params['ech_config'] ?? '';

      return V2rayConfig(
        protocol: protocol,
        alias: alias.isNotEmpty ? alias : 'سرور $address:$port',
        address: address,
        port: port == 0 ? 443 : port,
        uuidOrPassword: uuidOrPassword,
        transport: transport,
        host: host,
        path: path,
        security: security,
        sni: sni,
        fingerprint: fingerprint,
        alpn: alpn,
        allowInsecure: allowInsecure,
        publicKey: publicKey,
        shortId: shortId,
        spiderX: spiderX,
        echConfig: echConfig,
      );
    } catch (_) {
      return V2rayConfig(
        protocol: 'vless',
        alias: 'سرور ویرایش‌نشده',
        address: '127.0.0.1',
        port: 443,
        uuidOrPassword: 'uuid-id',
      );
    }
  }

  String toRawUrl() {
    final Map<String, String> queryParams = {};
    
    if (protocol == 'hysteria2') {
      if (sni.isNotEmpty) queryParams['sni'] = sni;
      if (allowInsecure) queryParams['insecure'] = '1';
      if (echConfig.isNotEmpty) queryParams['ech'] = echConfig;
    } else {
      queryParams['security'] = security;
      queryParams['type'] = transport;
      if (host.isNotEmpty) queryParams['host'] = host;
      if (path.isNotEmpty) queryParams['path'] = path;
      if (sni.isNotEmpty) queryParams['sni'] = sni;
      if (fingerprint.isNotEmpty) queryParams['fp'] = fingerprint;
      if (alpn.isNotEmpty) queryParams['alpn'] = alpn;
      if (allowInsecure) {
        queryParams['insecure'] = '1';
        queryParams['allowInsecure'] = '1';
      }
      if (security == 'reality') {
        if (publicKey.isNotEmpty) queryParams['pbk'] = publicKey;
        if (shortId.isNotEmpty) queryParams['sid'] = shortId;
        if (spiderX.isNotEmpty) queryParams['spx'] = spiderX;
      }
      if (echConfig.isNotEmpty) queryParams['ech'] = echConfig;
    }

    final encodedAlias = Uri.encodeComponent(alias);
    final queryString = Uri(queryParameters: queryParams).query;

    return "$protocol://$uuidOrPassword@$address:$port?$queryString#$encodedAlias";
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(1220, 840),
      minimumSize: Size(1000, 700),
      center: true,
      title: 'RedCloud VPN - Next-Gen Anti-Censorship Client',
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

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
        scaffoldBackgroundColor: const Color(0xFF090B10),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C5DD3),
          secondary: Color(0xFF00D2FF),
          surface: Color(0xFF121520),
        ),
        useMaterial3: true,
      ),
      home: const MainLayout(),
    );
  }
}

class MainLayout extends StatelessWidget {
  const MainLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return const MainLayoutContent();
  }
}

class MainLayoutContent extends StatefulWidget {
  const MainLayoutContent({super.key});

  @override
  State<MainLayoutContent> createState() => _MainLayoutContentState();
}

class _MainLayoutContentState extends State<MainLayoutContent> with WindowListener, TrayListener, TickerProviderStateMixin {
  int _selectedMenuIndex = 0;
  
  final TextEditingController _binaryPathController = TextEditingController(text: 'sing-box.exe');
  final TextEditingController _aetherPathController = TextEditingController(text: 'aether.exe');
  final TextEditingController _torPathController = TextEditingController(text: 'tor.exe');
  final TextEditingController _psiphonPathController = TextEditingController(text: 'psiphon-tunnel-core.exe');
  final TextEditingController _importController = TextEditingController();

  final TextEditingController _uuidController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _workerController = TextEditingController();

  final TextEditingController _customSniController = TextEditingController();
  final TextEditingController _tlsSpoofController = TextEditingController(text: 'zoom.us');
  final TextEditingController _fallbackDelayController = TextEditingController(text: '500ms');

  final TextEditingController _aetherWarpKeyController = TextEditingController();
  final TextEditingController _aetherTeamController = TextEditingController();
  String _selectedAetherNoize = 'firewall';
  
  String _selectedUtlsFingerprint = 'chrome';
  bool _enableFragment = false;
  bool _enableRecordFragment = false;
  bool _enableTlsSpoof = false;
  bool _useTunMode = false;

  bool _isHybridModeEnabled = true;

  String _downloadSpeed = "0.0 B/s";
  String _uploadSpeed = "0.0 B/s";
  StreamSubscription? _trafficSubscription;

  final Map<String, int> _nodePings = {};
  bool _isBulkPinging = false;

  List<ProxyNode> _savedNodes = [];
  ProxyNode? _selectedNode;

  String? _publicIp;
  String? _countryCode;
  String? _countryName;
  String? _cityName;
  bool _isLoadingIpInfo = false;

  List<VlessAccount> _githubAccounts = [];
  VlessAccount? _selectedGithubAccount;
  bool _isLoadingAccounts = false;

  double _sessionBytesUsed = 0; 
  Timer? _telemetryTimer;

  bool _isProxyRunning = false;
  bool _isHybridRunning = false;
  
  bool _isAetherRunning = false;
  bool _isAetherConnecting = false;
  int _aetherProgressPercent = 0;
  String _aetherStatusText = "آماده اتصال";
  Timer? _aetherProgressTimer;
  
  String _selectedAetherMode = "auto";

  final Map<String, String> _aetherModes = {
    'auto': 'انتخاب خودکار هوشمند (Auto Failover - پیشنهادی)',
    'masque_h3': 'MASQUE H3 (QUIC) - پرسرعت',
    'masque_h2': 'MASQUE H2 + Fragment - ضد اختلال UDP',
    'gool': 'Gool (WARP-in-WARP) - تونل مضاعف ضد قطع',
    'wireguard': 'WireGuard - پروتکل استاندارد وایرگارد',
  };

  final Map<String, String> _aetherNoizeProfiles = {
    'firewall': 'فایروال (Firewall - ضد فیلترینگ و مسدودسازی پیشرفته)',
    'light': 'سبک (Light - حداکثر سرعت و پینگ پایین)',
    'aggressive': 'تهاجمی (Aggressive - عبور از اختلالات شدید شبکه)',
  };

  bool _isTorRunning = false;
  bool _isTorConnecting = false;
  bool _isTorMasqueRunning = false;
  bool _isTorMasqueEnabled = true;
  int _torProgressPercent = 0;
  Timer? _torProgressTimer;
  
  bool _isPsiphonRunning = false;
  bool _isPsiphonConnecting = false;
  bool _isPsiphonMasqueRunning = false;
  bool _isPsiphonMasqueEnabled = true;
  Timer? _psiphonProgressTimer;
  
  String _selectedTorCountry = "تصادفی (Random)";
  String _selectedPsiphonCountry = "تصادفی (Random)";
  
  final Map<String, String> _torCountries = {
    'تصادفی (Random)': '',
    'آلمان (Germany)': 'de',
    'آمریکا (United States)': 'us',
    'فرانسه (France)': 'fr',
    'هلند (Netherlands)': 'nl',
    'سوئد (Sweden)': 'se',
    'بریتانیا (United Kingdom)': 'gb',
    'کانادا (Canada)': 'ca',
    'سوئیس (Switzerland)': 'ch',
    'ایتالیا (Italy)': 'it',
    'لهستان (Poland)': 'pl',
  };

  final Map<String, String> _psiphonCountries = {
    'تصادفی (Random)': '',
    'آلمان (Germany)': 'DE',
    'آمریکا (United States)': 'US',
    'بریتانیا (United Kingdom)': 'GB',
    'کانادا (Canada)': 'CA',
    'اتریش (Austria)': 'AT',
    'هلند (Netherlands)': 'NL',
    'فرانسه (France)': 'FR',
    'سنگاپور (Singapore)': 'SG',
    'ژاپن (Japan)': 'JP',
    'سوئیس (Switzerland)': 'CH',
    'لهستان (Poland)': 'PL',
    'ترکیه (Turkey)': 'TR',
    'آرژانتین (Argentina)': 'AR',
  };

  final List<DnsProfile> _dnsList = [
    DnsProfile(
      name: 'کلودفلر DoH (فوق امن)', 
      primary: '1.1.1.1', 
      secondary: '1.0.0.1', 
      description: 'امن‌ترین پروتکل دی‌ان‌اس رمزنگاری شده جهان بر بستر HTTPS',
      dnsType: 'doh',
      dohUrl: 'https://cloudflare-dns.com/dns-query',
    ),
    DnsProfile(
      name: 'گوگل DoT (سرعت بالا)', 
      primary: '8.8.8.8', 
      secondary: '8.8.4.4', 
      description: 'ترافیک دی‌ان‌اس رمزنگاری شده گوگل بر بستر پورت بومی TLS 853',
      dnsType: 'dot',
      dotHost: 'dns.google',
    ),
    DnsProfile(
      name: 'شکن (Shecan)', 
      primary: '178.22.122.100', 
      secondary: '185.51.200.2', 
      description: 'دور زدن تحریم‌های اینترنتی وب‌سایت‌های خارجی',
      dnsType: 'udp',
    ),
    DnsProfile(
      name: 'الکترو (Electro)', 
      primary: '78.157.42.100', 
      secondary: '78.157.42.101', 
      description: 'مخصوص بازی و تحریم‌شکن عمومی با پینگ مناسب',
      dnsType: 'udp',
    ),
    DnsProfile(
      name: 'رادار گیم (Radar Game)', 
      primary: '10.201.10.10', 
      secondary: '10.201.10.11', 
      description: 'دی‌ان‌اس ایرانی مخصوص بازی‌های آنلاین',
      dnsType: 'udp',
    ),
    DnsProfile(
      name: '۴۰۳ آنلاین (403.online)', 
      primary: '10.202.10.10', 
      secondary: '10.202.10.11', 
      description: 'دی‌ان‌اس تحریم‌شکن ایرانی بسیار پرسرعت',
      dnsType: 'udp',
    ),
    DnsProfile(
      name: 'ادگارد DoH (حذف تبلیغات)', 
      primary: '94.140.14.14', 
      secondary: '94.140.15.15', 
      description: 'فیلتر کردن خودکار دامنه‌های تبلیغاتی و ردیاب‌ها با DoH',
      dnsType: 'doh',
      dohUrl: 'https://dns.adguard-dns.com/dns-query',
    ),
    DnsProfile(
      name: 'نکست دی‌ان‌اس DoH (NextDNS)', 
      primary: '45.90.28.0', 
      secondary: '45.90.30.0', 
      description: 'دی‌ان‌اس شخصی‌سازی شده پرسرعت جهانی با امنیت عالی بر بستر HTTPS',
      dnsType: 'doh',
      dohUrl: 'https://dns.nextdns.io',
    ),
    DnsProfile(
      name: 'کواد ناین DoH (Quad9)', 
      primary: '9.9.9.9', 
      secondary: '149.112.112.112', 
      description: 'مسدودسازی خودکار وب‌سایت‌های بدافزاری ساخت سوئیس',
      dnsType: 'doh',
      dohUrl: 'https://dns.quad9.net/dns-query',
    ),
  ];

  late DnsProfile _selectedDns;
  bool _isDnsRunning = false;
  int? _dnsPing;
  bool _isPingingDns = false;

  bool _useSystemProxy = true; 
  String _statusMessage = "سیستم آماده اتصال است";

  bool _showDnsRescueToast = false;
  String _dnsRescueToastMsg = "";
  Timer? _dnsToastTimer;

  bool _isScanning = false; 
  int _scannedTotal = 0;
  int _scannedAlive = 0;
  int _scannedDead = 0;
  Timer? _scanStatsTimer;

  bool _hasUpdate = false;
  String _latestVersion = "";
  String _latestReleaseUrl = githubRepoReleasesUrl;
  bool _isCheckingUpdate = false;
  AnimationController? _pulseController;
  Animation<double>? _pulseAnimation;

  static const _androidVpnChannel = MethodChannel('com.example.redcloud/vpn');

  Future<File> _getLocalFile(String fileName) async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}/$fileName');
  }

  Future<void> _saveNodesToDisk() async {
    try {
      final file = await _getLocalFile('saved_nodes.json');
      final List<Map<String, String>> data = _savedNodes.map((node) => {
        'name': node.name,
        'protocol': node.protocol,
        'rawUrl': node.rawUrl,
      }).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("خطا در ذخیره کانفیگ‌ها روی دیسک: $e");
    }
  }

  Future<void> _loadNodesFromDisk() async {
    try {
      final file = await _getLocalFile('saved_nodes.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        setState(() {
          _savedNodes = decoded.map((item) => ProxyNode(
            name: item['name'] ?? '',
            protocol: item['protocol'] ?? '',
            rawUrl: item['rawUrl'] ?? '',
          )).toList();
          
          if (_savedNodes.isNotEmpty) {
            _selectedNode = _savedNodes.first;
          }
        });
      }
    } catch (e) {
      debugPrint("خطا در لود کانفیگ‌ها از دیسک: $e");
    }
  }

  Future<void> _saveDnsToDisk() async {
    try {
      final file = await _getLocalFile('saved_dns.json');
      final customDns = _dnsList.where((dns) => dns.isCustom).toList();
      final List<Map<String, dynamic>> data = customDns.map((dns) => {
        'name': dns.name,
        'primary': dns.primary,
        'secondary': dns.secondary,
        'description': dns.description,
        'dnsType': dns.dnsType,
        'dohUrl': dns.dohUrl,
        'dotHost': dns.dotHost,
      }).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("خطا در ذخیره دی‌ان‌اس‌های سفارشی: $e");
    }
  }

  Future<void> _loadDnsFromDisk() async {
    try {
      final file = await _getLocalFile('saved_dns.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        final loadedCustom = decoded.map((item) => DnsProfile(
          name: item['name'] ?? '',
          primary: item['primary'] ?? '',
          secondary: item['secondary'] ?? '',
          description: item['description'] ?? '',
          dnsType: item['dnsType'] ?? 'udp',
          dohUrl: item['dohUrl'],
          dotHost: item['dotHost'],
          isCustom: true,
        )).toList();
        
        setState(() {
          _dnsList.addAll(loadedCustom);
        });
      }
    } catch (e) {
      debugPrint("خطا در لود دی‌ان‌اس‌های سفارشی: $e");
    }
  }

  Future<void> _saveAntiDpiToDisk() async {
    try {
      final file = await _getLocalFile('saved_anti_dpi.json');
      final data = {
        'utls_fingerprint': _selectedUtlsFingerprint,
        'tls_fragment': _enableFragment,
        'tls_record_fragment': _enableRecordFragment,
        'fallback_delay': _fallbackDelayController.text,
        'tls_spoof_enabled': _enableTlsSpoof,
        'tls_spoof_sni': _tlsSpoofController.text,
        'aether_noize': _selectedAetherNoize,
        'aether_warp_key': _aetherWarpKeyController.text,
        'aether_team': _aetherTeamController.text,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint("خطا در ذخیره تنظیمات ضدسانسور: $e");
    }
  }

  Future<void> _loadAntiDpiFromDisk() async {
    try {
      final file = await _getLocalFile('saved_anti_dpi.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(content);
        setState(() {
          _selectedUtlsFingerprint = decoded['utls_fingerprint'] ?? 'chrome';
          _enableFragment = decoded['tls_fragment'] ?? false;
          _enableRecordFragment = decoded['tls_record_fragment'] ?? false;
          _fallbackDelayController.text = decoded['fallback_delay'] ?? '500ms';
          _enableTlsSpoof = decoded['tls_spoof_enabled'] ?? false;
          _tlsSpoofController.text = decoded['tls_spoof_sni'] ?? 'zoom.us';
          _selectedAetherNoize = decoded['aether_noize'] ?? 'firewall';
          _aetherWarpKeyController.text = decoded['aether_warp_key'] ?? '';
          _aetherTeamController.text = decoded['aether_team'] ?? '';
        });
      }
    } catch (e) {
      debugPrint("خطا در لود تنظیمات ضدسانسور: $e");
    }
  }

  void _triggerDnsRescueToast(String message) {
    _dnsToastTimer?.cancel();
    if (mounted) {
      setState(() {
        _showDnsRescueToast = true;
        _dnsRescueToastMsg = message;
      });
      _dnsToastTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) {
          setState(() {
            _showDnsRescueToast = false;
          });
        }
      });
    }
  }

  Future<void> _checkForUpdates({bool showSnackbarIfNoUpdate = false}) async {
    setState(() => _isCheckingUpdate = true);
    try {
      final response = await http.get(
        Uri.parse('https://api.github.com/repos/Devtahas/RedCloud-windows/releases/latest'),
        headers: {'User-Agent': 'RedCloud-Client'},
      ).timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final String tagName = (data['tag_name'] ?? '').toString().replaceAll('v', '').trim();
        final String htmlUrl = data['html_url'] ?? githubRepoReleasesUrl;

        if (tagName.isNotEmpty && tagName != appCurrentVersion) {
          setState(() {
            _hasUpdate = true;
            _latestVersion = tagName;
            _latestReleaseUrl = htmlUrl;
          });
        } else {
          setState(() => _hasUpdate = false);
          if (showSnackbarIfNoUpdate && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('شما از آخرین نسخه برنامه (v$appCurrentVersion) استفاده می‌کنید.')),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("خطا در بررسی آپدیت: $e");
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void _openDonationDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121520),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: Color(0xFFFFC837), width: 1.5)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amberAccent.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.favorite_rounded, color: Colors.amberAccent, size: 24),
              ),
              const SizedBox(width: 14),
              const Text('حمایت مالی از پروژه RedCloud', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'از اینکه با حمایت مالی خود به توسعه، بقا و ارتقای سرورهای ضدسانسور RedCloud کمک می‌کنید، بی‌نهایت سپاسگزاریم.\nحمایت‌های ارزشمند شما انگیزه اصلی ما برای مبارزه با فیلترینگ و حفظ اینترنت آزاد برای همه است. ❤️',
                  style: TextStyle(fontSize: 13, height: 1.6, color: Colors.white70),
                  textAlign: TextAlign.justify,
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090B10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.currency_bitcoin_rounded, color: Colors.greenAccent, size: 18),
                              SizedBox(width: 8),
                              Text('آدرس تتر (USDT)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.greenAccent)),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                            ),
                            child: const Text('شبکه BNB Smart Chain (BEP20)', style: TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold)),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        usdtBnbAddress,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(const ClipboardData(text: usdtBnbAddress));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('آدرس ولت با موفقیت کپی شد! تشکر از حمایت شما ❤️'),
                                backgroundColor: Color(0xFF2DCA73),
                              ),
                            );
                            Navigator.of(context).pop();
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6C5DD3),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          icon: const Icon(Icons.copy_rounded, color: Colors.white, size: 18),
                          label: const Text('کپی آدرس ولت', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      )
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('بستن', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _selectedDns = _dnsList[0];

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController!, curve: Curves.easeInOut),
    );
    
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initSystemTray();
    }
    _checkStatus();
    _testDnsPing();
    _loadNodesFromDisk();
    _loadDnsFromDisk();
    _loadAntiDpiFromDisk();
    _checkForUpdates();
  }

  @override
  void dispose() {
    _pulseController?.dispose();
    _scanStatsTimer?.cancel();
    _aetherProgressTimer?.cancel();
    _torProgressTimer?.cancel();
    _psiphonProgressTimer?.cancel();
    _dnsToastTimer?.cancel();
    _customSniController.dispose();
    _tlsSpoofController.dispose();
    _fallbackDelayController.dispose();
    _aetherWarpKeyController.dispose();
    _aetherTeamController.dispose();
    _stopTrafficMonitoring();
    _stopTelemetryReporting();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  void _startTrafficMonitoring() async {
    _stopTrafficMonitoring();
    
    try {
      final client = HttpClient();
      client.findProxy = (uri) => "DIRECT"; 
      
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:9090/traffic'));
      const double fiveGB = 5.0 * 1024 * 1024 * 1024;
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
          
          _sessionBytesUsed += (up + down);

          if (_selectedGithubAccount != null) {
            final double totalBytes = _selectedGithubAccount!.usedBytes + _sessionBytesUsed;
            if (totalBytes >= fiveGB) {
              _handleAutoRotation();
            }
          }

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

  void _stopTrafficMonitoring() {
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    setState(() {
      _downloadSpeed = "0.0 B/s";
      _uploadSpeed = "0.0 B/s";
    });
  }

  void _startTelemetryReporting() {
    _stopTelemetryReporting();
    _sessionBytesUsed = 0;
    
    _telemetryTimer = Timer.periodic(const Duration(minutes: 3), (timer) async {
      if (_sessionBytesUsed > 1024 * 1024) {
        await _sendTrafficReport();
      }
    });
  }

  Future<void> _stopTelemetryReporting() async {
    _telemetryTimer?.cancel();
    _telemetryTimer = null;
    if (_sessionBytesUsed > 0) {
      await _sendTrafficReport();
    }
  }

  Future<void> _sendTrafficReport() async {
    if (_selectedNode == null) return;
    
    final config = V2rayConfig.parse(_selectedNode!.rawUrl);
    final String workerHost = config.host; 
    
    try {
      final response = await http.post(
        Uri.parse("$managerWorkerUrl/api/report"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "worker": workerHost,
          "bytes_used": _sessionBytesUsed.toInt(),
        }),
      );
      
      if (response.statusCode == 200) {
        _sessionBytesUsed = 0;
        debugPrint("گزارش ترافیک با موفقیت مخابره شد.");
      }
    } catch (e) {
      debugPrint("خطا در ارسال تله‌متری ترافیک: $e");
    }
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return "${bytesPerSecond.toStringAsFixed(1)} B/s";
    } else if (bytesPerSecond < 1024 * 1024) {
      return "${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s";
    } else {
      return "${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s";
    }
  }

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
          
          final latency = await pingProxyServer(host: host, port: port);
          _nodePings[node.rawUrl] = latency;
        } catch (_) {
          _nodePings[node.rawUrl] = -1;
        }
      }());
    }

    await Future.wait(pingFutures);

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

  void _openEditDialog(ProxyNode node, int index) {
    final config = V2rayConfig.parse(node.rawUrl);
    
    final aliasController = TextEditingController(text: config.alias);
    final addressController = TextEditingController(text: config.address);
    final portController = TextEditingController(text: config.port.toString());
    final uuidController = TextEditingController(text: config.uuidOrPassword);
    final hostController = TextEditingController(text: config.host);
    final pathController = TextEditingController(text: config.path);
    final sniController = TextEditingController(text: config.sni);
    final echController = TextEditingController(text: config.echConfig);
    final pbkController = TextEditingController(text: config.publicKey);
    final sidController = TextEditingController(text: config.shortId);
    final spxController = TextEditingController(text: config.spiderX);

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
              backgroundColor: const Color(0xFF121520),
              title: Row(
                children: [
                  Icon(Icons.edit_rounded, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Text('ویرایش پیکربندی سرور (VLESS / Trojan / Hysteria2)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
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
                            dropdownColor: const Color(0xFF090B10),
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            underline: const SizedBox(),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedProtocol = val);
                              }
                            },
                            items: ['vless', 'trojan', 'hysteria2'].map((p) => DropdownMenuItem(value: p, child: Text(p.toUpperCase()))).toList(),
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
                      _buildDialogField(
                        selectedProtocol == 'hysteria2' ? 'رمز عبور احراز هویت (Auth Password)' : 'شناسه کاربر (UUID / Password)', 
                        uuidController
                      ),
                      const SizedBox(height: 12),
                      
                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('پروتکل انتقال (Transport):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            DropdownButton<String>(
                              value: selectedTransport,
                              dropdownColor: const Color(0xFF090B10),
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
                      ],

                      const Divider(color: Colors.white12, height: 24),
                      const Text('تنظیمات امنیت لایه اتصال (TLS / Reality)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey)),
                      const SizedBox(height: 12),

                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('نوع امنیت (Security):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            DropdownButton<String>(
                              value: selectedSecurity,
                              dropdownColor: const Color(0xFF090B10),
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
                      ],

                      _buildDialogField('نام سرور امن (SNI / Peer)', sniController),
                      const SizedBox(height: 12),

                      if (selectedSecurity == 'reality') ...[
                        _buildDialogField('کلید عمومی ریالیتی (Public Key / pbk)', pbkController),
                        const SizedBox(height: 12),
                        _buildDialogField('شناسه کوتاه ریالیتی (Short ID / sid)', sidController),
                        const SizedBox(height: 12),
                        _buildDialogField('مسیر اسپایدر (SpiderX / spx)', spxController),
                        const SizedBox(height: 12),
                      ],

                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('اثر انگشت مرورگر (Fingerprint):', style: TextStyle(fontSize: 12, color: Colors.grey)),
                            DropdownButton<String>(
                              value: selectedFingerprint,
                              dropdownColor: const Color(0xFF090B10),
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
                              dropdownColor: const Color(0xFF090B10),
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
                      ],

                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('نادیده گرفتن خطای گواهی امنیتی (Allow Insecure)', style: TextStyle(fontSize: 12)),
                        value: allowInsecure,
                        activeThumbColor: const Color(0xFF6C5DD3),
                        onChanged: (val) {
                          setDialogState(() => allowInsecure = val);
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField('رشته پیکربندی رمزنگاری هدر (EchConfigList)', echController, hint: 'کد Base64 یا لیست ECH Config'),
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
                  onPressed: () async {
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
                      publicKey: pbkController.text.trim(),
                      shortId: sidController.text.trim(),
                      spiderX: spxController.text.trim(),
                      echConfig: echController.text.trim(),
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
                      _statusMessage = "تنظیمات سرور '${updatedConfig.alias}' به‌روزرسانی شد.";
                    });
                    
                    final navigator = Navigator.of(context);
                    await _saveNodesToDisk();
                    navigator.pop();
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

  void _openAddDnsDialog() {
    final nameController = TextEditingController();
    final primaryController = TextEditingController();
    final secondaryController = TextEditingController();
    final descriptionController = TextEditingController();
    final dohUrlController = TextEditingController();
    final dotHostController = TextEditingController();
    String selectedType = 'udp';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              title: Row(
                children: [
                  Icon(Icons.add_moderator_rounded, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 12),
                  const Text('افزودن DNS سفارشی جدید', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDialogField('نام نمایشی دی‌ان‌اس', nameController),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('نوع پروتکل اتصال DNS:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedType,
                            dropdownColor: const Color(0xFF090B10),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => selectedType = val);
                              }
                            },
                            items: ['udp', 'doh', 'dot'].map((type) => DropdownMenuItem(value: type, child: Text(type.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField('آدرس آی‌پی اصلی (Primary IP)', primaryController),
                      const SizedBox(height: 12),
                      _buildDialogField('آدرس آی‌پی ثانویه (Secondary IP)', secondaryController),
                      const SizedBox(height: 12),
                      if (selectedType == 'doh') ...[
                        _buildDialogField('لینک بستر DoH', dohUrlController),
                        const SizedBox(height: 12),
                      ],
                      if (selectedType == 'dot') ...[
                        _buildDialogField('هاست امن DoT', dotHostController),
                        const SizedBox(height: 12),
                      ],
                      _buildDialogField('توضیحات کوتاه دی‌ان‌اس', descriptionController),
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
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty || primaryController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('وارد کردن نام دی‌ان‌اس و آی‌پی اصلی اجباری است.')),
                      );
                      return;
                    }

                    final newDns = DnsProfile(
                      name: nameController.text.trim(),
                      primary: primaryController.text.trim(),
                      secondary: secondaryController.text.trim().isEmpty ? primaryController.text.trim() : secondaryController.text.trim(),
                      description: descriptionController.text.trim().isEmpty ? 'دی‌ان‌اس سفارشی کاربر' : descriptionController.text.trim(),
                      dnsType: selectedType,
                      dohUrl: selectedType == 'doh' ? dohUrlController.text.trim() : null,
                      dotHost: selectedType == 'dot' ? dotHostController.text.trim() : null,
                      isCustom: true,
                    );

                    setState(() {
                      _dnsList.add(newDns);
                      _selectedDns = newDns;
                    });
                    
                    final navigator = Navigator.of(context);
                    await _saveDnsToDisk();
                    navigator.pop();
                    _testDnsPing();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C5DD3)),
                  child: const Text('افزودن دی‌ان‌اس', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
        _statusMessage = "خطا در اتصال به VPN اندروید: $e";
      });
    }
  }

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

  Future<void> _initSystemTray() async {
    String iconPath = 'assets/app_icon.ico';
    
    if (kReleaseMode) {
      final String exePath = Platform.resolvedExecutable;
      final String exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
      iconPath = '$exeDir\\data\\flutter_assets\\assets\\app_icon.ico';
    }

    await trayManager.setIcon(iconPath); 
    await trayManager.setToolTip('RedCloud VPN');

    List<MenuItem> items = [
      MenuItem(key: 'show_window', label: 'باز کردن برنامه'),
      MenuItem.separator(),
      MenuItem(key: 'exit_app', label: 'خروج کامل'),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  @override
  void onWindowClose() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
      setState(() {
        _statusMessage = "برنامه در پس‌زمینه و کنار ساعت فعال است.";
      });
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      if (_isHybridRunning) await stopHybridConnection();
      if (_isProxyRunning) await stopProxyCore();
      if (_isAetherRunning || _isAetherConnecting) await stopAetherCore();
      if (_isTorMasqueRunning) {
        await stopTorOverMasque();
      } else if (_isTorRunning) {
        await stopTorCore();
      }
      if (_isPsiphonMasqueRunning) {
        await stopPsiphonOverMasque();
      } else if (_isPsiphonRunning) {
        await stopPsiphonCore();
      }
      if (_isDnsRunning) await resetSystemDns();

      await trayManager.destroy();
      await windowManager.destroy(); 
    }
  }

  @override
  void onTrayIconMouseDown() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  Future<void> _checkStatus() async {
    final activeHybrid = await isHybridConnected();
    final activeProxy = await isConnected();
    final activeAether = await isAetherConnected();
    final activeTorMasque = await isTorMasqueConnected();
    final activeTor = await isTorConnected();
    final activePsiphonMasque = await isPsiphonMasqueConnected();
    final activePsiphon = await isPsiphonConnected();
    final activeDns = await isDnsActive();
    
    setState(() {
      _isHybridRunning = activeHybrid;
      _isProxyRunning = activeProxy && !activeHybrid;
      _isAetherRunning = activeAether && !activeHybrid && !activePsiphonMasque && !activeTorMasque;
      _isTorMasqueRunning = activeTorMasque;
      _isTorRunning = activeTor;
      _isPsiphonMasqueRunning = activePsiphonMasque;
      _isPsiphonRunning = activePsiphon;
      _isDnsRunning = activeDns;
      
      if (activeHybrid) {
        _statusMessage = "متصل به اتصال هیبریدی RedCloud (پل اِتر + Sing-box)";
        _startTrafficMonitoring();
        _fetchIpInfo();
      } else if (activeTorMasque) {
        _statusMessage = "متصل به شبکه پیاز تور بر بستر مسک (Tor over MASQUE)";
        _fetchIpInfo();
      } else if (activePsiphonMasque) {
        _statusMessage = "متصل به شبکه سایفون بر بستر مسک (Psiphon over MASQUE)";
        _fetchIpInfo();
      } else if (activeAether) {
        _statusMessage = "متصل به شبکه ضدسانسور اِتر (MASQUE)";
        _fetchIpInfo();
      } else if (activeProxy) {
        _statusMessage = "متصل به سرور ویتوری";
        _startTrafficMonitoring();
        _startTelemetryReporting();
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

  Future<void> _fetchIpInfo({int retryCount = 2}) async {
    final bool isAnyConnected = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning;
    if (!isAnyConnected) return;

    if (!mounted) return;
    setState(() {
      _isLoadingIpInfo = true;
    });

    final providers = [
      'http://ip-api.com/json/?fields=status,country,countryCode,city,query',
      'https://freeipapi.com/api/json/',
      'https://ipwho.is/',
    ];

    for (int attempt = 0; attempt <= retryCount; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(seconds: 2));
      }

      for (final urlStr in providers) {
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 6);
          client.badCertificateCallback = (cert, host, port) => true;

          if (_isPsiphonRunning || _isPsiphonMasqueRunning) {
            client.findProxy = (uri) => "PROXY 127.0.0.1:9081";
          } else if (_isTorRunning || _isTorMasqueRunning) {
            client.findProxy = (uri) => "PROXY 127.0.0.1:9051";
          } else if (_isHybridRunning || _isProxyRunning) {
            client.findProxy = (uri) => "PROXY 127.0.0.1:2080";
          } else if (_isAetherRunning) {
            client.findProxy = (uri) => "PROXY 127.0.0.1:1820";
          } else {
            client.findProxy = (uri) => "DIRECT";
          }

          final request = await client.getUrl(Uri.parse(urlStr));
          final response = await request.close();

          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            final data = jsonDecode(body);

            String? ip = data['query'] ?? data['ipAddress'] ?? data['ip'];
            String? countryCode = data['countryCode'] ?? data['country_code'];
            String? country = data['country'] ?? data['countryName'];
            String? city = data['city'] ?? data['cityName'];

            if (ip != null && countryCode != null && mounted) {
              setState(() {
                _publicIp = ip;
                _countryCode = countryCode;
                _countryName = country ?? 'ناشناس';
                _cityName = city ?? 'ناشناس';
                _isLoadingIpInfo = false;
                _statusMessage = "اتصال پایدار و ترافیک فعال است (لوکیشن: $_countryName).";
              });
              return;
            }
          }
        } catch (_) {}
      }
    }

    if (mounted) {
      setState(() {
        _isLoadingIpInfo = false;
      });
    }
  }

  Future<void> _fetchGithubAccounts() async {
    setState(() {
      _isLoadingAccounts = true;
      _statusMessage = "در حال دریافت لیست اکانت‌های فعال از گیت‌هاب...";
    });

    try {
      final response = await http.get(Uri.parse(
        'https://raw.githubusercontent.com/Devtahas/Devtahas-redcloud-config/main/accounts.json'
      ));

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = jsonDecode(response.body);
        
        List<VlessAccount> parsedList = [];
        for (var item in jsonList) {
          final String status = item['status'] ?? 'full';
          if (status == 'exhausted') continue;

          parsedList.add(VlessAccount(
            worker: item['worker'] ?? '',
            uuid: item['uuid'] ?? '',
            path: item['path'] ?? '',
            name: '',
            status: status,
            usedBytes: item['used_bytes'] ?? 0,
          ));
        }

        if (parsedList.isEmpty) {
          throw Exception("تمام سرورهای اشتراکی پر هستند.");
        }

        parsedList.sort((a, b) {
          final int priorityA = a.status == 'full' ? 1 : 2;
          final int priorityB = b.status == 'full' ? 1 : 2;
          return priorityA.compareTo(priorityB);
        });

        final int takeCount = parsedList.length < 5 ? parsedList.length : 5;
        final selectedRandoms = parsedList.take(takeCount).toList();

        List<VlessAccount> finalAccounts = [];
        for (int i = 0; i < selectedRandoms.length; i++) {
          finalAccounts.add(VlessAccount(
            worker: selectedRandoms[i].worker,
            uuid: selectedRandoms[i].uuid,
            path: selectedRandoms[i].path,
            status: selectedRandoms[i].status,
            usedBytes: selectedRandoms[i].usedBytes,
            name: 'اکانت ${i + 1} (${selectedRandoms[i].status == 'full' ? 'فول شارژ' : 'ظرفیت متوسط'})',
          ));
        }

        setState(() {
          _githubAccounts = finalAccounts;
          _isLoadingAccounts = false;
          _statusMessage = "تعداد ${_githubAccounts.length} اکانت بارگذاری شد.";
          
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
      _statusMessage = "اطلاعات ${account.name} روی فیلدها اعمال شد.";
    });
  }

  Future<void> _handleAutoRotation() async {
    await _stopTelemetryReporting();
    if (_isHybridRunning) {
      await stopHybridConnection();
    } else if (_isProxyRunning) {
      await stopProxyCore();
    }
    _stopTrafficMonitoring();
    
    setState(() {
      _statusMessage = "ظرفیت اکانت به پایان رسید! در حال چرخش خودکار و اسکن هوشمند...";
    });
    
    await _fetchGithubAccounts();
    
    if (_githubAccounts.isNotEmpty) {
      await _startCloudflareScan(mode: "quick", earlyStop: false);
      if (_selectedNode == null) {
        await _startCloudflareScan(mode: "deep", earlyStop: true);
      }

      if (_selectedNode != null) {
        await _toggleV2RayConnection();
      }
    }
  }

  Future<void> _startCloudflareScan({String mode = "quick", bool earlyStop = false}) async {
    if (_uuidController.text.isEmpty || _pathController.text.isEmpty || _workerController.text.isEmpty) {
      setState(() => _statusMessage = "خطا: لطفاً ابتدا اطلاعات اکانت را پر کنید.");
      return;
    }

    _scanStatsTimer?.cancel();
    setState(() {
      _isScanning = true;
      _scannedTotal = 0;
      _scannedAlive = 0;
      _scannedDead = 0;
      _statusMessage = mode == "deep" 
          ? "در حال اسکن عمیق و چندنخی از فایل cloudflare_IPs.txt..." 
          : "در حال اجرای اسکن سریع کلودفلر...";
    });

    _scanStatsTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (!_isScanning) {
        timer.cancel();
        return;
      }
      try {
        final stats = await getScannerStats();
        setState(() {
          _scannedTotal = stats.totalScanned;
          _scannedAlive = stats.aliveCount;
          _scannedDead = stats.deadCount;
        });
      } catch (_) {}
    });

    try {
      final cleanNodes = await runCloudflareScanner(
        uuid: _uuidController.text.trim(),
        path: _pathController.text.trim(),
        worker: _workerController.text.trim(),
        scanMode: mode,
        earlyStop: earlyStop,
      );

      _scanStatsTimer?.cancel();

      setState(() {
        _isScanning = false;
        if (cleanNodes.isEmpty) {
          _statusMessage = "اسکن پایان یافت؛ هیچ آی‌پی تمیزی یافت نشد.";
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
      await _saveNodesToDisk();
    } catch (e) {
      _scanStatsTimer?.cancel();
      setState(() {
        _isScanning = false;
        _statusMessage = "خطا در اسکن: $e";
      });
    }
  }

  void _stopCloudflareScan() async {
    try {
      await stopCloudflareScanner();
      _scanStatsTimer?.cancel();
      setState(() {
        _statusMessage = "دستور توقف اسکن ارسال شد. در حال جمع‌آوری آی‌پی‌های سفید...";
      });
    } catch (e) {
      debugPrint("خطا در توقف اسکن: $e");
    }
  }

  Future<void> _importConfigOrSub() async {
    final text = _importController.text.trim();
    if (text.isEmpty) return;

    setState(() => _statusMessage = "در حال پردازش ورودی...");

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
        _statusMessage = "تعداد ${parsedNodes.length} سرور اضافه شد.";
        _selectedNode ??= _savedNodes.first;
      });
      await _saveNodesToDisk();
    } catch (e) {
      setState(() {
        _statusMessage = "خطا در اضافه کردن ورودی: ${e.toString()}";
      });
    }
  }

  Future<void> _toggleV2RayConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isHybridRunning || _isProxyRunning) {
          await _stopTelemetryReporting();
          
          final String msg = _isHybridRunning 
              ? await stopHybridConnection() 
              : await stopProxyCore();
              
          _stopTrafficMonitoring();
          setState(() {
            _isHybridRunning = false;
            _isProxyRunning = false;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_selectedNode == null) {
            setState(() => _statusMessage = "در حال دریافت خودکار اکانت و اجرای اسکن دو‌مرحله‌ای...");
            await _fetchGithubAccounts();
            if (_githubAccounts.isNotEmpty) {
              await _startCloudflareScan(mode: "quick", earlyStop: false);
              if (_selectedNode == null) {
                setState(() => _statusMessage = "آی‌پی‌های سریع مسدود بودند؛ در حال جستجوی عمیق اولین آی‌پی سفید...");
                await _startCloudflareScan(mode: "deep", earlyStop: true);
              }
            }
            if (_selectedNode == null) {
              setState(() => _statusMessage = "خطا: لطفاً ابتدا یک سرور را از بخش پیکربندی انتخاب کنید.");
              return;
            }
          }

          if (_isAetherRunning || _isAetherConnecting) {
            _aetherProgressTimer?.cancel();
            await stopAetherCore();
            setState(() {
              _isAetherRunning = false;
              _isAetherConnecting = false;
            });
          }
          if (_isTorMasqueRunning) {
            await stopTorOverMasque();
            setState(() {
              _isTorRunning = false;
              _isTorMasqueRunning = false;
            });
          } else if (_isTorRunning) {
            await stopTorCore();
            setState(() => _isTorRunning = false);
          }
          if (_isPsiphonMasqueRunning) {
            await stopPsiphonOverMasque();
            setState(() {
              _isPsiphonRunning = false;
              _isPsiphonMasqueRunning = false;
            });
          } else if (_isPsiphonRunning) {
            await stopPsiphonCore();
            setState(() => _isPsiphonRunning = false);
          }

          if (_isHybridModeEnabled) {
            setState(() {
              _statusMessage = "در حال ایجاد پل چرخشی اِتر و زنجیره‌سازی با Sing-box...";
            });

            final msg = await startHybridConnection(
              singboxPath: _binaryPathController.text.trim(),
              aetherPath: _aetherPathController.text.trim(),
              selectedNode: _selectedNode!,
              aetherMode: _selectedAetherMode,
              aetherNoize: _selectedAetherNoize,
              aetherWarpKey: _aetherWarpKeyController.text.trim().isEmpty ? null : _aetherWarpKeyController.text.trim(),
              aetherTeam: _aetherTeamController.text.trim().isEmpty ? null : _aetherTeamController.text.trim(),
              useSystemProxy: _useSystemProxy,
              useTunMode: _useTunMode,
              dnsType: _selectedDns.dnsType,
              dnsPrimary: _selectedDns.primary,
              dnsSecondary: _selectedDns.secondary,
              dnsDotHost: _selectedDns.dotHost,
              utlsFingerprint: _selectedUtlsFingerprint,
            );

            setState(() {
              _isHybridRunning = true;
              _statusMessage = msg;
            });
          } else {
            final msg = await startProxyWithNode(
              binaryPath: _binaryPathController.text.trim(),
              selectedNode: _selectedNode!,
              useSystemProxy: _useSystemProxy,
              customSni: _customSniController.text.trim().isEmpty ? null : _customSniController.text.trim(),
              enableFragment: _enableFragment,
              enableRecordFragment: _enableRecordFragment,
              tlsSpoof: _enableTlsSpoof && _tlsSpoofController.text.trim().isNotEmpty ? _tlsSpoofController.text.trim() : null,
              useTunMode: _useTunMode,
              dnsType: _selectedDns.dnsType,
              dnsPrimary: _selectedDns.primary,
              dnsSecondary: _selectedDns.secondary,
              dnsDohUrl: _selectedDns.dohUrl,
              dnsDotHost: _selectedDns.dotHost,
              utlsFingerprint: _selectedUtlsFingerprint,
              fragmentFallbackDelay: _fallbackDelayController.text.trim().isEmpty ? null : _fallbackDelayController.text.trim(),
            );

            setState(() {
              _isProxyRunning = true;
              _statusMessage = msg;
            });
          }

          Future.delayed(const Duration(seconds: 2), () {
            if (_isHybridRunning || _isProxyRunning) {
              _startTrafficMonitoring();
              _startTelemetryReporting();
            }
          });

          _fetchIpInfo();
        }
      } else if (Platform.isAndroid) {
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
          await _startAndroidVpn(_selectedNode!.rawUrl);
          setState(() {
            _isProxyRunning = true;
          });
        }
      }
    } catch (e) {
      _triggerDnsRescueToast("اختلال در اتصال؛ در حال بررسی و بازیابی استخر DNS...");
      runDnsRescueScan(customDnsList: null).then((_) {
        _checkStatus();
      });
      setState(() => _statusMessage = "خطا در اتصال: ${e.toString()}");
    }
  }

  Future<void> _toggleAetherConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isAetherRunning || _isAetherConnecting) {
          _aetherProgressTimer?.cancel();
          final msg = await stopAetherCore();
          setState(() {
            _isAetherRunning = false;
            _isAetherConnecting = false;
            _aetherProgressPercent = 0;
            _aetherStatusText = "اتصال قطع شد.";
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_isHybridRunning) {
            await stopHybridConnection();
            setState(() => _isHybridRunning = false);
          }
          if (_isProxyRunning) {
            await stopProxyCore();
            setState(() => _isProxyRunning = false);
          }
          if (_isTorMasqueRunning) {
            await stopTorOverMasque();
            setState(() {
              _isTorRunning = false;
              _isTorMasqueRunning = false;
            });
          } else if (_isTorRunning) {
            await stopTorCore();
            setState(() => _isTorRunning = false);
          }
          if (_isPsiphonMasqueRunning) {
            await stopPsiphonOverMasque();
            setState(() {
              _isPsiphonRunning = false;
              _isPsiphonMasqueRunning = false;
            });
          } else if (_isPsiphonRunning) {
            await stopPsiphonCore();
            setState(() => _isPsiphonRunning = false);
          }

          setState(() {
            _isAetherConnecting = true;
            _aetherProgressPercent = 25;
            _aetherStatusText = "در حال اسکن و آزمایش خودکار پروتکل‌های ضدسانسور...";
            _statusMessage = "اتصال به شبکه اتر آغاز شد...";
          });

          await startAetherCore(
            binaryPath: _aetherPathController.text.trim(),
            mode: _selectedAetherMode,
            noize: _selectedAetherNoize,
            warpKey: _aetherWarpKeyController.text.trim().isEmpty ? null : _aetherWarpKeyController.text.trim(),
            team: _aetherTeamController.text.trim().isEmpty ? null : _aetherTeamController.text.trim(),
            useSystemProxy: _useSystemProxy,
          );

          _aetherProgressTimer?.cancel();
          _aetherProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (!_isAetherConnecting) {
              timer.cancel();
              return;
            }

            final percent = await getAetherBootstrapProgress();
            final isDone = await isAetherBootstrapDone();
            final statusTxt = await getAetherStatusText();

            setState(() {
              _aetherProgressPercent = percent;
              if (statusTxt.isNotEmpty) {
                _aetherStatusText = statusTxt;
              }
            });

            if (isDone || percent >= 100) {
              timer.cancel();
              setState(() {
                _isAetherRunning = true;
                _isAetherConnecting = false;
                _aetherProgressPercent = 100;
                _aetherStatusText = "اتصال پایدار شد! پورت 1820 و 1819 فعال است.";
                _statusMessage = "شبکه اتر با موفقیت متصل شد.";
              });
              _fetchIpInfo();
            }
          });
        }
      } else if (Platform.isAndroid) {
        setState(() => _statusMessage = "شبکه اتر در پلتفرم اندروید در دست توسعه است.");
      }
    } catch (e) {
      _aetherProgressTimer?.cancel();
      setState(() {
        _isAetherConnecting = false;
        _isAetherRunning = false;
        _aetherProgressPercent = 0;
        _statusMessage = "خطا در اتصال اتر: ${e.toString()}";
      });
    }
  }

  Future<void> _toggleTorConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isTorRunning || _isTorConnecting) {
          _torProgressTimer?.cancel();
          final String msg = _isTorMasqueRunning 
              ? await stopTorOverMasque() 
              : await stopTorCore();

          setState(() {
            _isTorRunning = false;
            _isTorMasqueRunning = false;
            _isTorConnecting = false;
            _torProgressPercent = 0;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_isHybridRunning) await stopHybridConnection();
          if (_isProxyRunning) await stopProxyCore();
          if (_isAetherRunning || _isAetherConnecting) await stopAetherCore();
          if (_isPsiphonMasqueRunning) {
            await stopPsiphonOverMasque();
          } else if (_isPsiphonRunning) {
            await stopPsiphonCore();
          }

          setState(() {
            _isHybridRunning = false;
            _isProxyRunning = false;
            _isAetherRunning = false;
            _isPsiphonRunning = false;
            _isTorMasqueRunning = false;
          });

          final countryCode = _torCountries[_selectedTorCountry] ?? "";
          
          setState(() {
            _isTorConnecting = true;
            _torProgressPercent = 0;
            _statusMessage = _isTorMasqueEnabled 
                ? "در حال ایجاد پل مسک و راه‌اندازی شبکه پیاز تور..." 
                : "در حال اجرای هسته تور...";
          });
          
          final String msg = _isTorMasqueEnabled
              ? await startTorOverMasque(
                  torPath: _torPathController.text.trim(),
                  aetherPath: _aetherPathController.text.trim(),
                  countryCode: countryCode,
                  aetherMode: _selectedAetherMode,
                  aetherNoize: _selectedAetherNoize,
                  aetherWarpKey: _aetherWarpKeyController.text.trim().isEmpty ? null : _aetherWarpKeyController.text.trim(),
                  aetherTeam: _aetherTeamController.text.trim().isEmpty ? null : _aetherTeamController.text.trim(),
                  useSystemProxy: _useSystemProxy,
                )
              : await startTorCore(
                  binaryPath: _torPathController.text.trim(),
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
              _statusMessage = "پیشرفت اتصال تور: $percent٪";
            });

            if (percent >= 100) {
              timer.cancel();
              setState(() {
                _isTorRunning = true;
                _isTorMasqueRunning = _isTorMasqueEnabled;
                _isTorConnecting = false;
                _statusMessage = _isTorMasqueEnabled 
                    ? "اتصال ترکیبی تور بر بستر مسک (Tor over MASQUE) با موفقیت برقرار شد!" 
                    : msg;
              });
              
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted && (_isTorRunning || _isTorMasqueRunning)) {
                  _fetchIpInfo();
                }
              });
            }
          });
        }
      } else if (Platform.isAndroid) {
        setState(() => _statusMessage = "تور در اندروید در دست توسعه است.");
      }
    } catch (e) {
      _torProgressTimer?.cancel();
      _triggerDnsRescueToast("سیستم هوشمند در حال رفع اختلال و آماده‌سازی گارد تور است...");
      setState(() {
        _isTorConnecting = false;
        _isTorRunning = false;
        _isTorMasqueRunning = false;
        _torProgressPercent = 0;
        _statusMessage = "خطا در اتصال تور: ${e.toString()}";
      });
    }
  }

  Future<void> _togglePsiphonConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isPsiphonRunning || _isPsiphonConnecting) {
          _psiphonProgressTimer?.cancel();
          final String msg = _isPsiphonMasqueRunning 
              ? await stopPsiphonOverMasque() 
              : await stopPsiphonCore();
              
          setState(() {
            _isPsiphonRunning = false;
            _isPsiphonMasqueRunning = false;
            _isPsiphonConnecting = false;
            _statusMessage = msg;
            _resetIpInfo();
          });
        } else {
          if (_isHybridRunning) await stopHybridConnection();
          if (_isProxyRunning) await stopProxyCore();
          if (_isAetherRunning || _isAetherConnecting) await stopAetherCore();
          if (_isTorMasqueRunning) {
            await stopTorOverMasque();
          } else if (_isTorRunning) {
            await stopTorCore();
          }

          setState(() {
            _isHybridRunning = false;
            _isProxyRunning = false;
            _isAetherRunning = false;
            _isTorRunning = false;
            _isTorMasqueRunning = false;
          });

          final countryCode = _psiphonCountries[_selectedPsiphonCountry] ?? "";
          
          setState(() {
            _isPsiphonConnecting = true;
            _statusMessage = _isPsiphonMasqueEnabled 
                ? "در حال ایجاد پل ضدسانسور مسک و برقراری ارتباط با سایفون..." 
                : "در حال اتصال به هسته سایفون...";
          });

          final String msg = _isPsiphonMasqueEnabled
              ? await startPsiphonOverMasque(
                  psiphonPath: _psiphonPathController.text.trim(),
                  aetherPath: _aetherPathController.text.trim(),
                  countryCode: countryCode,
                  aetherMode: _selectedAetherMode,
                  aetherNoize: _selectedAetherNoize,
                  aetherWarpKey: _aetherWarpKeyController.text.trim().isEmpty ? null : _aetherWarpKeyController.text.trim(),
                  aetherTeam: _aetherTeamController.text.trim().isEmpty ? null : _aetherTeamController.text.trim(),
                  useSystemProxy: _useSystemProxy,
                )
              : await startPsiphonCore(
                  binaryPath: _psiphonPathController.text.trim(),
                  countryCode: countryCode,
                  useSystemProxy: _useSystemProxy,
                );

          _psiphonProgressTimer?.cancel();
          _psiphonProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) async {
            if (!_isPsiphonConnecting) {
              timer.cancel();
              return;
            }

            final isDone = await isPsiphonBootstrapDone();
            final statusTxt = await getPsiphonStatusText();
            if (statusTxt.isNotEmpty && mounted) {
              setState(() {
                _statusMessage = statusTxt;
              });
            }

            if (isDone) {
              timer.cancel();
              setState(() {
                _isPsiphonRunning = true;
                _isPsiphonMasqueRunning = _isPsiphonMasqueEnabled;
                _isPsiphonConnecting = false;
                _statusMessage = _isPsiphonMasqueEnabled 
                    ? "اتصال ترکیبی سایفون بر بستر مسک (Psiphon over MASQUE) با موفقیت برقرار شد!" 
                    : msg;
              });
              
              Future.delayed(const Duration(milliseconds: 1500), () {
                if (mounted && (_isPsiphonRunning || _isPsiphonMasqueRunning)) {
                  _fetchIpInfo();
                }
              });
            }
          });
        }
      } else if (Platform.isAndroid) {
        setState(() => _statusMessage = "سایفون در اندروید در دست توسعه است.");
      }
    } catch (e) {
      _psiphonProgressTimer?.cancel();
      _triggerDnsRescueToast("سیستم هوشمند در حال غربالگری دیتابیس سایفون است...");
      setState(() {
        _isPsiphonConnecting = false;
        _isPsiphonRunning = false;
        _isPsiphonMasqueRunning = false;
        _statusMessage = "خطا در اتصال سایفون: ${e.toString()}";
      });
    }
  }

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
          setState(() => _statusMessage = "در حال اعمال دی‌ان‌اس...");
          
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
        setState(() => _statusMessage = "تغییر دهنده DNS در اندروید در دست توسعه است.");
      }
    } catch (e) {
      setState(() {
        _isDnsRunning = false;
        _statusMessage = "خطا: $e (برنامه را با Administrator اجرا کنید)";
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

  _TabTheme _getTabTheme(int index) {
    switch (index) {
      case 0:
        return const _TabTheme(
          gradient: [Color(0xFF00D2FF), Color(0xFFFF8008)],
          accent: Color(0xFF00D2FF),
          glow: Color(0xFFFF8008),
          icon: Icons.dashboard_rounded,
          title: 'داشبورد ویتوری',
        );
      case 1:
        return const _TabTheme(
          gradient: [Color(0xFF00D2FF), Color(0xFF0072FF)],
          accent: Color(0xFF00D2FF),
          glow: Color(0xFF00D2FF),
          icon: Icons.bolt_rounded,
          title: 'شبکه اِتر (MASQUE)',
        );
      case 2:
        return const _TabTheme(
          gradient: [Color(0xFF6C5DD3), Color(0xFF2DCA73)],
          accent: Color(0xFF2DCA73),
          glow: Color(0xFF6C5DD3),
          icon: Icons.tune_rounded,
          title: 'پیکربندی و سرورها',
        );
      case 3:
        return const _TabTheme(
          gradient: [Color(0xFF8A2387), Color(0xFFE94057)],
          accent: Color(0xFFE94057),
          glow: Color(0xFF8A2387),
          icon: Icons.blur_circular_rounded,
          title: 'شبکه پیاز تور (Tor)',
        );
      case 4:
        return const _TabTheme(
          gradient: [Color(0xFF11998E), Color(0xFF38EF7D)],
          accent: Color(0xFF38EF7D),
          glow: Color(0xFF11998E),
          icon: Icons.security_rounded,
          title: 'شبکه سایفون (Psiphon)',
        );
      case 5:
        return const _TabTheme(
          gradient: [Color(0xFFFF8008), Color(0xFFFFC837)],
          accent: Color(0xFFFF8008),
          glow: Color(0xFFFFC837),
          icon: Icons.radar_rounded,
          title: 'اسکنر کلودفلر',
        );
      case 6:
        return const _TabTheme(
          gradient: [Color(0xFF2193B0), Color(0xFF6DD5ED)],
          accent: Color(0xFF6DD5ED),
          glow: Color(0xFF2193B0),
          icon: Icons.dns_rounded,
          title: 'تغییر دهنده DNS',
        );
      case 7:
        return const _TabTheme(
          gradient: [Color(0xFF4A5568), Color(0xFF718096)],
          accent: Color(0xFFA0AEC0),
          glow: Color(0xFF718096),
          icon: Icons.settings_rounded,
          title: 'تنظیمات برنامه',
        );
      case 8:
        return const _TabTheme(
          gradient: [Color(0xFFF9D423), Color(0xFFFF4E50)],
          accent: Color(0xFFF9D423),
          glow: Color(0xFFFF4E50),
          icon: Icons.menu_book_rounded,
          title: 'راهنمای جامع کاربری',
        );
      case 9:
        return const _TabTheme(
          gradient: [Color(0xFFED213A), Color(0xFF93291E)],
          accent: Color(0xFFFF4B4B),
          glow: Color(0xFFED213A),
          icon: Icons.shield_rounded,
          title: 'تنظیمات Anti-DPI',
        );
      default:
        return const _TabTheme(
          gradient: [Color(0xFF6C5DD3), Color(0xFF00D2FF)],
          accent: Color(0xFF00D2FF),
          glow: Color(0xFF6C5DD3),
          icon: Icons.dashboard_rounded,
          title: 'داشبورد',
        );
    }
  }

  Widget _buildGlassContainer({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(20),
    List<Color>? gradientColors,
    Color? borderColor,
    double borderRadius = 20,
    List<BoxShadow>? shadows,
  }) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors ?? [
            const Color(0xFF141828).withValues(alpha: 0.85),
            const Color(0xFF0F111D).withValues(alpha: 0.95),
          ],
        ),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: 0.1),
          width: 1.2,
        ),
        boxShadow: shadows ?? [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 20,
            offset: const Offset(0, 8),
          )
        ],
      ),
      child: child,
    );
  }

  Widget _buildDnsRescueFloatingToast() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: _showDnsRescueToast ? 1.0 : 0.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF141828).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFFC837), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFC837).withValues(alpha: 0.3),
              blurRadius: 20,
              spreadRadius: 2,
            )
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_rounded, color: Color(0xFFFFC837), size: 20),
            const SizedBox(width: 12),
            Text(
              _dnsRescueToastMsg,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              Container(
                width: 275,
                decoration: BoxDecoration(
                  color: const Color(0xFF0D101A),
                  border: Border(
                    right: BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1B2138), Color(0xFF101422)],
                        ),
                        border: Border.all(color: const Color(0xFF00D2FF).withValues(alpha: 0.3), width: 1.2),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                            blurRadius: 16,
                          )
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00D2FF), Color(0xFFFF8008)],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00D2FF).withValues(alpha: 0.4),
                                  blurRadius: 10,
                                )
                              ],
                            ),
                            child: const Icon(Icons.shield_rounded, color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 12),
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'RedCloud',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Colors.white),
                              ),
                              Text(
                                'Next-Gen VPN Client',
                                style: TextStyle(fontSize: 9.5, color: Colors.grey),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          children: [
                            _buildSidebarItem(0),
                            const SizedBox(height: 5),
                            _buildSidebarItem(1),
                            const SizedBox(height: 5),
                            _buildSidebarItem(2),
                            const SizedBox(height: 5),
                            _buildSidebarItem(3),
                            const SizedBox(height: 5),
                            _buildSidebarItem(4),
                            const SizedBox(height: 5),
                            _buildSidebarItem(5),
                            const SizedBox(height: 5),
                            _buildSidebarItem(6),
                            const SizedBox(height: 5),
                            _buildSidebarItem(7),
                            const SizedBox(height: 5),
                            _buildSidebarItem(8),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    _buildUpdateCard(),
                    const SizedBox(height: 10),

                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => openBrowserUrl(telegramChannelUrl),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF229ED9),
                              side: BorderSide(color: const Color(0xFF229ED9).withValues(alpha: 0.5)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.send_rounded, size: 14),
                            label: const Text('تلگرام', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _openDonationDialog,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber.withValues(alpha: 0.15),
                              foregroundColor: Colors.amberAccent,
                              elevation: 0,
                              side: BorderSide(color: Colors.amber.withValues(alpha: 0.4)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.favorite_rounded, size: 14, color: Colors.amberAccent),
                            label: const Text('حمایت', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    const Center(
                      child: Text('نسخه ضدسانسور ۳.۵ (Hybrid)', style: TextStyle(color: Colors.grey, fontSize: 10)),
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
          if (_showDnsRescueToast)
            Positioned(
              top: 24,
              right: 24,
              child: _buildDnsRescueFloatingToast(),
            ),
        ],
      ),
    );
  }

  Widget _buildUpdateCard() {
    if (_hasUpdate && _pulseAnimation != null) {
      final displayVer = _latestVersion.isNotEmpty ? _latestVersion : 'جدید';
      return AnimatedBuilder(
        animation: _pulseAnimation!,
        builder: (context, child) {
          return InkWell(
            onTap: () => openBrowserUrl(_latestReleaseUrl),
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  colors: [Color(0xFF6C5DD3), Color(0xFF00D2FF)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00D2FF).withValues(alpha: _pulseAnimation!.value * 0.7),
                    blurRadius: 16 * _pulseAnimation!.value,
                    spreadRadius: 2 * _pulseAnimation!.value,
                  )
                ],
                border: Border.all(color: Colors.white.withValues(alpha: 0.4), width: 1),
              ),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'آپدیت نسخه $displayVer آماده است',
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.download_rounded, color: Colors.white, size: 16),
                ],
              ),
            ),
          );
        },
      );
    }

    return InkWell(
      onTap: _isCheckingUpdate ? null : () => _checkForUpdates(showSnackbarIfNoUpdate: true),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.sync_rounded, size: 14, color: _isCheckingUpdate ? Colors.amberAccent : Colors.grey),
                const SizedBox(width: 6),
                Text(
                  _isCheckingUpdate ? 'بررسی...' : 'بررسی آپدیت نرم‌افزار',
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
              ],
            ),
            Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF2DCA73),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(int index) {
    final isSelected = _selectedMenuIndex == index;
    final theme = _getTabTheme(index);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedMenuIndex = index),
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: isSelected 
                ? LinearGradient(
                    colors: theme.gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: isSelected ? null : const Color(0xFF141828).withValues(alpha: 0.5),
            border: Border.all(
              color: isSelected 
                  ? Colors.white.withValues(alpha: 0.5) 
                  : theme.accent.withValues(alpha: 0.22),
              width: isSelected ? 1.4 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: theme.glow.withValues(alpha: 0.45),
                      blurRadius: 18,
                      spreadRadius: 1,
                      offset: const Offset(0, 4),
                    )
                  ]
                : null,
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.black.withValues(alpha: 0.25) : theme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  theme.icon,
                  color: isSelected ? Colors.white : theme.accent,
                  size: 17,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  theme.title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.grey[300],
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    fontSize: 12.5,
                  ),
                ),
              ),
              if (!isSelected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.accent.withValues(alpha: 0.6),
                  ),
                )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedPage() {
    switch (_selectedMenuIndex) {
      case 0:
        return _buildDashboardPage();
      case 1:
        return _buildAetherPage();
      case 2:
        return _buildConfigPage();
      case 3:
        return _buildTorPage();
      case 4:
        return _buildPsiphonPage();
      case 5:
        return _buildScannerPage();
      case 6:
        return _buildDnsPage();
      case 7:
        return _buildSettingsPage();
      case 8:
        return _buildHelpPage();
      case 9:
        return _buildAntiDpiSettingsPage();
      default:
        return _buildDashboardPage();
    }
  }

  Widget _buildDashboardPage() {
    final bool isAnyRunning = _isHybridRunning || _isProxyRunning;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('داشبورد ویتوری و اتصال هیبریدی', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                SizedBox(height: 4),
                Text('کنترل ترافیک با قابلیت زنجیره‌سازی خودکار از دل پل ضدسانسور اِتر', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
            _buildGlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              borderRadius: 16,
              borderColor: _isHybridModeEnabled ? const Color(0xFF00D2FF).withValues(alpha: 0.6) : Colors.white12,
              child: Row(
                children: [
                  Icon(Icons.hub_rounded, size: 18, color: _isHybridModeEnabled ? const Color(0xFF00D2FF) : Colors.grey),
                  const SizedBox(width: 10),
                  const Text('اتصال هیبریدی (Aether+VLESS):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Switch(
                    value: _isHybridModeEnabled,
                    activeThumbColor: const Color(0xFF00D2FF),
                    activeTrackColor: const Color(0xFFFF8008).withValues(alpha: 0.5),
                    onChanged: isAnyRunning ? null : (bool val) {
                      setState(() {
                        _isHybridModeEnabled = val;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
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
                          duration: const Duration(milliseconds: 350),
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: isAnyRunning
                                ? const LinearGradient(
                                    colors: [Color(0xFF00D2FF), Color(0xFFFF8008)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : const LinearGradient(
                                    colors: [Color(0xFF141828), Color(0xFF0F111D)],
                                  ),
                            border: Border.all(
                              color: isAnyRunning ? Colors.white : const Color(0xFF00D2FF).withValues(alpha: 0.4),
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: isAnyRunning 
                                    ? const Color(0xFF00D2FF).withValues(alpha: 0.5)
                                    : const Color(0xFF00D2FF).withValues(alpha: 0.15),
                                blurRadius: 45,
                                spreadRadius: isAnyRunning ? 8 : 2,
                                offset: const Offset(-4, -4),
                              ),
                              BoxShadow(
                                color: isAnyRunning 
                                    ? const Color(0xFFFF8008).withValues(alpha: 0.5)
                                    : const Color(0xFFFF8008).withValues(alpha: 0.15),
                                blurRadius: 45,
                                spreadRadius: isAnyRunning ? 8 : 2,
                                offset: const Offset(4, 4),
                              ),
                            ],
                          ),
                          child: Icon(
                            _isHybridRunning ? Icons.hub_rounded : Icons.power_settings_new_rounded,
                            size: 85,
                            color: isAnyRunning ? Colors.white : Colors.grey[500],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isHybridRunning 
                            ? 'متصل به اتصال هیبریدی (پل اِتر + Sing-box)' 
                            : _isProxyRunning 
                                ? 'متصل به ویتوری مستقیم' 
                                : (_isHybridModeEnabled ? 'جهت اتصال هیبریدی ضربه بزنید' : 'جهت اتصال ویتوری مستقیم ضربه بزنید'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15, 
                          fontWeight: FontWeight.bold,
                          color: isAnyRunning ? const Color(0xFF00D2FF) : Colors.grey[400]
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
                          Expanded(child: _buildStatCard('دانلود', _downloadSpeed, Icons.arrow_downward_rounded, const Color(0xFF00D2FF))),
                          const SizedBox(width: 16),
                          Expanded(child: _buildStatCard('آپلود', _uploadSpeed, Icons.arrow_upward_rounded, const Color(0xFFFF8008))),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFF00D2FF),
                          onChanged: _useTunMode ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: const Text('فعال‌سازی کارت شبکه مجازی (TUN Mode)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('عبور ترافیک کل سیستم (حتی بازی‌ها و برنامه‌های بدون پروکسی)', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useTunMode,
                          activeThumbColor: const Color(0xFFFF8008),
                          onChanged: (bool value) {
                            setState(() {
                              _useTunMode = value;
                              if (value) {
                                _useSystemProxy = false;
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        borderColor: const Color(0xFFED213A).withValues(alpha: 0.3),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(colors: [Color(0xFFED213A), Color(0xFF93291E)]),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.shield_rounded, color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'تنظیمات پیشرفته ضدسانسور (Anti-DPI)',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'جعل اثر انگشت مرورگر، فرگمنت ترافیک و تزریق اس‌ان‌آی فیک',
                                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _selectedMenuIndex = 9;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFED213A),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: const Text('پیکربندی', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        borderRadius: 18,
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFC837).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.dns_rounded, color: Color(0xFFFFC837), size: 20),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('سرور فعال برای خروجی ویتوری', style: TextStyle(color: Colors.grey, fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Text(
                                    _selectedNode?.name ?? "سرور خودکار (دریافت اتوماتیک از گیت‌هاب)", 
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
                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
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

  Widget _buildAetherPage() {
    final bool isActive = _isAetherRunning;
    final bool isLoading = _isAetherConnecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00D2FF), Color(0xFF0072FF)]),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF00D2FF).withValues(alpha: 0.35), blurRadius: 10),
                ],
              ),
              child: const Text('پروتکل نسل جدید MASQUE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text('شبکه ضدسانسور اِتر (Aether Engine)', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
        const Text('اتصال مستقیم و مقاوم به شبکه Cloudflare Zero Trust بر بستر HTTP/3 QUIC بدون نیاز به دامنه شخصی', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 32),
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
                        onTap: _toggleAetherConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: (isActive || isLoading)
                                ? const LinearGradient(colors: [Color(0xFF00D2FF), Color(0xFF0072FF)])
                                : const LinearGradient(colors: [Color(0xFF141828), Color(0xFF0F111D)]),
                            border: Border.all(
                              color: (isActive || isLoading) ? Colors.white : const Color(0xFF00D2FF).withValues(alpha: 0.4),
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (isActive || isLoading)
                                    ? const Color(0xFF00D2FF).withValues(alpha: 0.55) 
                                    : const Color(0xFF00D2FF).withValues(alpha: 0.12),
                                blurRadius: 45,
                                spreadRadius: (isActive || isLoading) ? 10 : 2,
                              )
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                Icons.bolt_rounded,
                                size: 90,
                                color: (isActive || isLoading) ? Colors.white : Colors.grey[600],
                              ),
                              if (isLoading)
                                SizedBox(
                                  width: 155,
                                  height: 155,
                                  child: CircularProgressIndicator(
                                    value: _aetherProgressPercent > 0 ? _aetherProgressPercent / 100.0 : null,
                                    strokeWidth: 4.5,
                                    color: Colors.white,
                                    backgroundColor: Colors.white24,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        isActive 
                            ? 'متصل به شبکه اِتر (MASQUE)' 
                            : isLoading 
                                ? 'در حال اسکن و تایید عبور داده: $_aetherProgressPercent٪' 
                                : 'جهت اتصال به شبکه اِتر ضربه بزنید',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16, 
                          fontWeight: FontWeight.bold,
                          color: (isActive || isLoading) ? const Color(0xFF00D2FF) : Colors.grey[400]
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
                      _buildGlassContainer(
                        borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.35),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.tune_rounded, color: Color(0xFF00D2FF), size: 18),
                                SizedBox(width: 10),
                                Text('حالت پروتکل ضدسانسور (Mode):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            DropdownButton<String>(
                              value: _selectedAetherMode,
                              isExpanded: true,
                              dropdownColor: const Color(0xFF0D101A),
                              underline: const SizedBox(),
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              onChanged: isActive || isLoading ? null : (String? newValue) {
                                if (newValue != null) {
                                  setState(() {
                                    _selectedAetherMode = newValue;
                                    _statusMessage = "حالت پروتکل اتر به ${_aetherModes[newValue]} تغییر کرد.";
                                  });
                                }
                              },
                              items: _aetherModes.entries.map((entry) {
                                return DropdownMenuItem<String>(
                                  value: entry.key,
                                  child: Text(entry.value),
                                );
                              }).toList(),
                            ),
                            const Divider(color: Colors.white10, height: 20),
                            
                            const Row(
                              children: [
                                Icon(Icons.waves_rounded, color: Color(0xFF00D2FF), size: 18),
                                SizedBox(width: 10),
                                Text('پروفایل پارازیت ضد DPI (Noize):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            DropdownButton<String>(
                              value: _selectedAetherNoize,
                              isExpanded: true,
                              dropdownColor: const Color(0xFF0D101A),
                              underline: const SizedBox(),
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              onChanged: isActive || isLoading ? null : (String? val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedAetherNoize = val;
                                  });
                                  _saveAntiDpiToDisk();
                                }
                              },
                              items: _aetherNoizeProfiles.entries.map((entry) {
                                return DropdownMenuItem<String>(
                                  value: entry.key,
                                  child: Text(entry.value),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: ExpansionTile(
                          title: const Text('تنظیمات پیشرفته (اکانت WARP+ و Zero Trust)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          leading: const Icon(Icons.vpn_key_rounded, color: Colors.amberAccent, size: 18),
                          childrenPadding: const EdgeInsets.all(16),
                          children: [
                            TextField(
                              controller: _aetherWarpKeyController,
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                labelText: 'کلید لایسنس WARP+ (اختیاری)',
                                hintText: 'لایسنس ۲۴ کاراکتری وارپ پلاس',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (_) => _saveAntiDpiToDisk(),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _aetherTeamController,
                              style: const TextStyle(fontSize: 12),
                              decoration: const InputDecoration(
                                labelText: 'نام سازمان یا توکن Team کلودفلر (اختیاری)',
                                hintText: 'مثلاً myteam.cloudflarewarp.com',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (_) => _saveAntiDpiToDisk(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل (HTTP 1820 & SOCKS 1819)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('هدایت خودکار ترافیک کروم و ویندوز به درگاه Aether', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFF00D2FF),
                          onChanged: isActive || isLoading ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.terminal_rounded, size: 16, color: Color(0xFF00D2FF)),
                                SizedBox(width: 8),
                                Text('وضعیت زنده اسکنر Data-Plane اتر:', style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _aetherStatusText, 
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
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

  Widget _buildConfigPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('پیکربندی و سرورها', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('لینک ساب یا کانفیگ تکی خود را وارد کرده و سرور فعال را انتخاب کنید', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _importController,
                decoration: const InputDecoration(
                  labelText: 'لینک ساب (https://) یا کانفیگ تکی (vless / hysteria2 / trojan) یا Base64',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.add_link_rounded, color: Color(0xFF2DCA73)),
                ),
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _importConfigOrSub,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C5DD3),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.download_rounded, color: Colors.white),
              label: const Text('وارد کردن', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        const SizedBox(height: 24),
        
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('لیست سرورهای ذخیره‌شده', style: TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: Colors.grey)),
            ElevatedButton.icon(
              onPressed: _isBulkPinging ? null : _bulkPingAndSort,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                foregroundColor: const Color(0xFF2DCA73),
                side: const BorderSide(color: Color(0xFF2DCA73), width: 1),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: _isBulkPinging 
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2DCA73)))
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
              : _buildGlassContainer(
                  padding: const EdgeInsets.all(12),
                  borderRadius: 18,
                  child: ListView.separated(
                    itemCount: _savedNodes.length,
                    separatorBuilder: (_, index) => const Divider(color: Colors.white12),
                    itemBuilder: (context, index) {
                      final node = _savedNodes[index];
                      final isSelected = _selectedNode == node;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isSelected 
                              ? const Color(0xFF2DCA73).withValues(alpha: 0.2)
                              : Colors.white10,
                          child: Text(
                            node.protocol[0].toUpperCase(),
                            style: TextStyle(
                              color: isSelected ? const Color(0xFF2DCA73) : Colors.grey,
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
                            IconButton(
                              icon: const Icon(Icons.share_rounded, size: 16, color: Colors.grey),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: node.rawUrl));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('لینک کانفیگ با موفقیت کپی شد!')),
                                );
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.grey),
                              onPressed: () => _openEditDialog(node, index),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_forever_rounded, size: 16, color: Colors.redAccent),
                              onPressed: () async {
                                setState(() {
                                  _savedNodes.removeAt(index);
                                  if (_selectedNode == node) {
                                    _selectedNode = _savedNodes.isNotEmpty ? _savedNodes.first : null;
                                  }
                                });
                                await _saveNodesToDisk();
                              },
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

  Widget _buildTorPage() {
    final bool isTorActive = _isTorRunning;
    final bool isTorLoading = _isTorConnecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('شبکه پیاز تور (Tor Network)', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                SizedBox(height: 4),
                Text('اتصال فوق‌امن و گمنام با امکان گذر از گارد ضدسانسور MASQUE و تعیین کشور خروجی', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
            _buildGlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              borderRadius: 16,
              borderColor: _isTorMasqueEnabled ? const Color(0xFFE94057).withValues(alpha: 0.6) : Colors.white12,
              child: Row(
                children: [
                  Icon(Icons.hub_rounded, size: 18, color: _isTorMasqueEnabled ? const Color(0xFFE94057) : Colors.grey),
                  const SizedBox(width: 10),
                  const Text('پل مسک (Tor over MASQUE):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Switch(
                    value: _isTorMasqueEnabled,
                    activeThumbColor: const Color(0xFFE94057),
                    activeTrackColor: const Color(0xFF8A2387).withValues(alpha: 0.5),
                    onChanged: (isTorActive || isTorLoading) ? null : (bool val) {
                      setState(() {
                        _isTorMasqueEnabled = val;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
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
                        onTap: _toggleTorConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: (isTorActive || isTorLoading)
                                ? const LinearGradient(colors: [Color(0xFF8A2387), Color(0xFFE94057)])
                                : const LinearGradient(colors: [Color(0xFF141828), Color(0xFF0F111D)]),
                            border: Border.all(
                              color: (isTorActive || isTorLoading) ? Colors.white : const Color(0xFFE94057).withValues(alpha: 0.4),
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (isTorActive || isTorLoading)
                                    ? const Color(0xFFE94057).withValues(alpha: 0.5) 
                                    : const Color(0xFF8A2387).withValues(alpha: 0.15),
                                blurRadius: 40,
                                spreadRadius: 8,
                              )
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                _isTorMasqueRunning ? Icons.hub_rounded : Icons.blur_circular_rounded, 
                                size: 85,
                                color: (isTorActive || isTorLoading) ? Colors.white : Colors.grey[600],
                              ),
                              if (isTorLoading)
                                SizedBox(
                                  width: 155,
                                  height: 155,
                                  child: CircularProgressIndicator(
                                    value: _torProgressPercent > 0 ? _torProgressPercent / 100.0 : null,
                                    strokeWidth: 4,
                                    color: Colors.white,
                                    backgroundColor: Colors.white24,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isTorMasqueRunning 
                            ? 'متصل به شبکه تور بر بستر مسک (MASQUE)'
                            : isTorActive 
                                ? 'متصل به شبکه پیاز تور' 
                                : isTorLoading 
                                    ? 'در حال برقراری مدار پیاز: $_torProgressPercent٪' 
                                    : (_isTorMasqueEnabled ? 'جهت اتصال تور از بستر مسک ضربه بزنید' : 'جهت اتصال به تور مستقیم ضربه بزنید'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15, 
                          fontWeight: FontWeight.bold,
                          color: (isTorActive || isTorLoading) ? const Color(0xFFE94057) : Colors.grey[400]
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
                      _buildGlassContainer(
                        borderColor: const Color(0xFFE94057).withValues(alpha: 0.35),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.public_rounded, color: Color(0xFFE94057), size: 20),
                                SizedBox(width: 12),
                                Text('کشور خروجی (Exit Node):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            DropdownButton<String>(
                              value: _selectedTorCountry,
                              dropdownColor: const Color(0xFF0D101A),
                              underline: const SizedBox(),
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              onChanged: isTorLoading || isTorActive ? null : (String? newValue) {
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
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل (Port 9051)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFFE94057),
                          onChanged: (isTorActive || isTorLoading) ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
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

  Widget _buildPsiphonPage() {
    final bool isPsiphonActive = _isPsiphonRunning;
    final bool isPsiphonLoading = _isPsiphonConnecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('شبکه سایفون (Psiphon Network)', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
                SizedBox(height: 4),
                Text('اتصال امن به فیلترشکن سایفون با امکان گذر از بستر پرسرعت و پایدار MASQUE', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
            _buildGlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              borderRadius: 16,
              borderColor: _isPsiphonMasqueEnabled ? const Color(0xFF38EF7D).withValues(alpha: 0.6) : Colors.white12,
              child: Row(
                children: [
                  Icon(Icons.hub_rounded, size: 18, color: _isPsiphonMasqueEnabled ? const Color(0xFF38EF7D) : Colors.grey),
                  const SizedBox(width: 10),
                  const Text('پل مسک (Psiphon over MASQUE):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Switch(
                    value: _isPsiphonMasqueEnabled,
                    activeThumbColor: const Color(0xFF38EF7D),
                    activeTrackColor: const Color(0xFF11998E).withValues(alpha: 0.5),
                    onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (bool val) {
                      setState(() {
                        _isPsiphonMasqueEnabled = val;
                      });
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
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
                        onTap: _togglePsiphonConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 200,
                          height: 200,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: (isPsiphonActive || isPsiphonLoading)
                                ? const LinearGradient(colors: [Color(0xFF11998E), Color(0xFF38EF7D)])
                                : const LinearGradient(colors: [Color(0xFF141828), Color(0xFF0F111D)]),
                            border: Border.all(
                              color: (isPsiphonActive || isPsiphonLoading) ? Colors.white : const Color(0xFF38EF7D).withValues(alpha: 0.4),
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: (isPsiphonActive || isPsiphonLoading)
                                    ? const Color(0xFF38EF7D).withValues(alpha: 0.5) 
                                    : const Color(0xFF11998E).withValues(alpha: 0.15),
                                blurRadius: 40,
                                spreadRadius: 8,
                              )
                            ],
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                _isPsiphonMasqueRunning ? Icons.hub_rounded : Icons.security_rounded,
                                size: 85,
                                color: (isPsiphonActive || isPsiphonLoading) ? Colors.white : Colors.grey[600],
                              ),
                              if (isPsiphonLoading)
                                const SizedBox(
                                  width: 155,
                                  height: 155,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 4,
                                    color: Colors.white,
                                    backgroundColor: Colors.white24,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _isPsiphonMasqueRunning
                            ? 'متصل به سایفون بر بستر مسک (MASQUE)'
                            : isPsiphonActive 
                                ? 'متصل به سایفون مستقیم' 
                                : isPsiphonLoading 
                                    ? (_isPsiphonMasqueEnabled ? 'در حال برقراری پل مسک و تونل سایفون...' : 'در حال اتصال به سرورهای سایفون...') 
                                    : (_isPsiphonMasqueEnabled ? 'جهت اتصال سایفون از بستر مسک ضربه بزنید' : 'جهت اتصال به سایفون مستقیم ضربه بزنید'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15, 
                          fontWeight: FontWeight.bold,
                          color: (isPsiphonActive || isPsiphonLoading) ? const Color(0xFF38EF7D) : Colors.grey[400]
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
                      _buildGlassContainer(
                        borderColor: const Color(0xFF38EF7D).withValues(alpha: 0.35),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.public_rounded, color: Color(0xFF38EF7D), size: 20),
                                SizedBox(width: 12),
                                Text('کشور خروجی (Exit Node):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            DropdownButton<String>(
                              value: _selectedPsiphonCountry,
                              dropdownColor: const Color(0xFF0D101A),
                              underline: const SizedBox(),
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (String? newValue) {
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
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: const Text('تنظیم اتوماتیک پروکسی سیستم‌عامل (Port 9081)', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text('فعال‌سازی رجیستری ویندوز جهت عبور کل ترافیک سیستم', style: TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFF38EF7D),
                          onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
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

  Widget _buildDnsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('تغییر دهنده هوشمند DNS', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const Text('اعمال دی‌ان‌اس‌های تحریم‌شکن با بررسی زنده پینگ و تاخیر شبکه', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 36),
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
                        onTap: _toggleDnsConnection,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          width: 190,
                          height: 190,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: _isDnsRunning
                                ? const LinearGradient(colors: [Color(0xFF2193B0), Color(0xFF6DD5ED)])
                                : const LinearGradient(colors: [Color(0xFF141828), Color(0xFF0F111D)]),
                            border: Border.all(
                              color: _isDnsRunning ? Colors.white : const Color(0xFF6DD5ED).withValues(alpha: 0.4),
                              width: 3.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _isDnsRunning 
                                    ? const Color(0xFF6DD5ED).withValues(alpha: 0.5) 
                                    : const Color(0xFF2193B0).withValues(alpha: 0.15),
                                blurRadius: 40,
                                spreadRadius: 8,
                              )
                            ],
                          ),
                          child: Icon(
                            Icons.dns_rounded, 
                            size: 85,
                            color: _isDnsRunning ? Colors.white : Colors.grey[600],
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
                          color: _isDnsRunning ? const Color(0xFF6DD5ED) : Colors.grey[400]
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
                    mainAxisAlignment: MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildGlassContainer(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.radar_rounded, color: Color(0xFF6DD5ED), size: 20),
                                      SizedBox(width: 8),
                                      Text('انتخاب DNS:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButton<DnsProfile>(
                                      value: _selectedDns,
                                      isExpanded: true,
                                      dropdownColor: const Color(0xFF0D101A),
                                      underline: const SizedBox(),
                                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                      alignment: AlignmentDirectional.centerEnd,
                                      onChanged: _isDnsRunning ? null : (DnsProfile? newValue) {
                                        if (newValue != null) {
                                          setState(() {
                                            _selectedDns = newValue;
                                          });
                                          _testDnsPing();
                                        }
                                      },
                                      items: _dnsList.map<DropdownMenuItem<DnsProfile>>((DnsProfile value) {
                                        return DropdownMenuItem<DnsProfile>(
                                          value: value,
                                          child: Text(
                                            value.name,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  )
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton.icon(
                            onPressed: _isDnsRunning ? null : _openAddDnsDialog,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2193B0),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            ),
                            icon: const Icon(Icons.add_moderator_rounded, color: Colors.white, size: 18),
                            label: const Text('افزودن DNS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      
                      _buildGlassContainer(
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
                            if (_selectedDns.dnsType == 'doh' && _selectedDns.dohUrl != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('آدرس رمزنگاری DoH:', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                  Expanded(
                                    child: Text(
                                      _selectedDns.dohUrl!, 
                                      textAlign: TextAlign.end,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFFC837)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (_selectedDns.dnsType == 'dot' && _selectedDns.dotHost != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text('هاست امن DoT:', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                  Text(_selectedDns.dotHost!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFFC837))),
                                ],
                              ),
                            ],
                            const Divider(color: Colors.white12, height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('تاخیر پاسخگویی (Ping):', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                                _isPingingDns
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6DD5ED)),
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

                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
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

                      if (_selectedDns.isCustom) ...[
                        ElevatedButton.icon(
                          onPressed: _isDnsRunning ? null : () async {
                            setState(() {
                              _dnsList.remove(_selectedDns);
                              _selectedDns = _dnsList[0];
                            });
                            
                            final scaffoldMessenger = ScaffoldMessenger.of(context);
                            await _saveDnsToDisk();
                            _testDnsPing();
                            scaffoldMessenger.showSnackBar(
                              const SnackBar(content: Text('دی‌ان‌اس سفارشی از سیستم حذف شد.')),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.delete_forever_rounded),
                          label: const Text('حذف این دی‌ان‌اس سفارشی', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 16),
                      ],

                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded, color: Color(0xFFFFC837), size: 20),
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
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScannerPage() {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('اسکنر موازی کلودفلر (IP Scanner)', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('اسکن دو‌حالته سریع و عمیق با پایش زنده TCP Ping و TLS Handshake', style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 20),
          
          _buildGlassContainer(
            borderColor: const Color(0xFFFF8008).withValues(alpha: 0.35),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('دریافت اطلاعات اکانت از گیت‌هاب:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    _isLoadingAccounts
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF8008)))
                        : ElevatedButton.icon(
                            onPressed: _fetchGithubAccounts,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFF8008),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.cloud_download_rounded, size: 16, color: Colors.white),
                            label: const Text('دریافت اکانت‌های رندوم', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                  ],
                ),
                const SizedBox(height: 12),

                if (_githubAccounts.isNotEmpty)
                  Container(
                    height: 38,
                    margin: const EdgeInsets.only(bottom: 14),
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _githubAccounts.length,
                      separatorBuilder: (_, index) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final acc = _githubAccounts[index];
                        final isSel = _selectedGithubAccount == acc;
                        return ChoiceChip(
                          label: Text(acc.name, style: TextStyle(color: isSel ? Colors.white : Colors.grey, fontSize: 11)),
                          selected: isSel,
                          selectedColor: const Color(0xFFFF8008),
                          backgroundColor: const Color(0xFF090B10),
                          onSelected: (bool selected) {
                            if (selected) {
                              _selectAccount(acc);
                            }
                          },
                        );
                      },
                    ),
                  ),
                const Divider(color: Colors.white12, height: 16),
                const SizedBox(height: 8),

                TextField(
                  controller: _uuidController,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(labelText: 'کلید شناسایی کاربر (UUID)', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _workerController,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(labelText: 'دامنه ورکر (Worker Domain)', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pathController,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(labelText: 'مسیر کانفیگ (WebSocket Path)', border: OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090B10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildScanStatBadge('کل بررسی‌شده', '$_scannedTotal', const Color(0xFF00D2FF)),
                      Container(width: 1, height: 24, color: Colors.white12),
                      _buildScanStatBadge('آی‌پی‌های سالم', '$_scannedAlive', const Color(0xFF2DCA73)),
                      Container(width: 1, height: 24, color: Colors.white12),
                      _buildScanStatBadge('مسدود / تایم‌اوت', '$_scannedDead', Colors.redAccent),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                Center(
                  child: _isScanning
                      ? ElevatedButton.icon(
                          onPressed: _stopCloudflareScan,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          icon: const Icon(Icons.stop_rounded, color: Colors.white, size: 18),
                          label: const Text('توقف اسکن', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () => _startCloudflareScan(mode: "quick", earlyStop: false),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF8008),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.flash_on_rounded, color: Colors.white, size: 16),
                              label: const Text('اسکن سریع', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton.icon(
                              onPressed: () => _startCloudflareScan(mode: "deep", earlyStop: false),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFFC837).withValues(alpha: 0.2),
                                foregroundColor: const Color(0xFFFFC837),
                                side: const BorderSide(color: Color(0xFFFFC837), width: 1.2),
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.saved_search_rounded, size: 18),
                              label: const Text('اسکن عمیق (Deep Scan)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          _buildGlassContainer(
            padding: const EdgeInsets.all(14),
            borderRadius: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('وضعیت و لاگ‌های اسکنر:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 6),
                Text(
                  _statusMessage,
                  style: const TextStyle(fontFamily: 'monospace', color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildScanStatBadge(String label, String value, Color color) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color, fontFamily: 'monospace')),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _buildSettingsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('تنظیمات برنامه', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        const Text('پیکربندی هسته‌های سیستم و مسیر فایل‌های باینری', style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: _buildGlassContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('تنظیمات آدرس هسته شبکه اِتر (Aether MASQUE)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF))),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _aetherPathController,
                    decoration: const InputDecoration(
                      labelText: 'مسیر فایل هسته aether.exe',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.bolt_rounded, color: Color(0xFF00D2FF)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 16),

                  const Text('تنظیمات آدرس هسته V2Ray (sing-box)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _binaryPathController,
                    decoration: const InputDecoration(
                      labelText: 'مسیر فایل هسته sing-box.exe',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.code_rounded),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 16),

                  const Text('تنظیمات آدرس هسته تور (Tor)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _torPathController,
                    decoration: const InputDecoration(
                      labelText: 'مسیر فایل هسته tor.exe',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.blur_circular_rounded),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white12),
                  const SizedBox(height: 16),

                  const Text('تنظیمات آدرس هسته سایفون (Psiphon)', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _psiphonPathController,
                    decoration: const InputDecoration(
                      labelText: 'مسیر فایل هسته psiphon-tunnel-core.exe',
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
          ),
        ),
      ],
    );
  }

  Widget _buildHelpPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFF9D423), Color(0xFFFF4E50)]),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(color: const Color(0xFFF9D423).withValues(alpha: 0.35), blurRadius: 10),
                ],
              ),
              child: const Icon(Icons.menu_book_rounded, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('راهنمای جامع کاربری و ترفندهای RedCloud', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text('آموزش گام‌به‌گام تمامی ابزارها، پروتکل‌ها و تکنیک‌های دور زدن فیلترینگ', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              children: [
                _buildHelpAccordion(
                  title: '۱. داشبورد و حالت اتصال هیبریدی (پیشنهاد اصلی)',
                  icon: Icons.hub_rounded,
                  iconColor: const Color(0xFF00D2FF),
                  content: '''
• اتصال هیبریدی (Aether + VLESS):
این حالت پیشرفته‌ترین متد ضدسانسور برنامه است. در این حالت ترافیک شما ابتدا از پل فوق‌العاده پایدار اتر (MASQUE) رد شده و سپس وارد هسته ویتوری (Sing-box) می‌شود. با این کار فیلترینگ متوجه هویت ترافیک شما نمی‌شود و سرعت آپلود و دانلود بسیار پایداری خواهید داشت.

• ویتوری مستقیم (Direct):
اگر سوییچ اتصال هیبریدی را خاموش کنید، برنامه مستقیماً با سرور انتخابی شما در تب پیکربندی ارتباط برقرار می‌کند.

• چرخش خودکار اکانت‌ها (Auto-Rotation):
در صورتی که حجم ۵ گیگابایتی اکانت اشتراکی فعال تمام شود، برنامه بدون نیاز به دخالت شما به‌طور خودکار اکانت تازه از سرور گیت‌هاب دریافت کرده و ترافیک را متصل نگه می‌دارد.
''',
                ),
                _buildHelpAccordion(
                  title: '۲. تفاوت کارت شبکه مجازی (TUN Mode) و پروکسی سیستم',
                  icon: Icons.alt_route_rounded,
                  iconColor: const Color(0xFF2DCA73),
                  content: '''
• حالت پروکسی سیستم‌عامل (System Proxy):
این گزینه رجیستری ویندوز را تنظیم می‌کند تا ترافیک تمام مرورگرها (کروم، فایرفاکس، ادج) و نرم‌افزارها به‌طور خودکار از فیلترشکن عبور کنند.

• کارت شبکه مجازی (TUN Mode):
یک کارت شبکه مجازی روی ویندوز می‌سازد و کل ترافیک اینترنت رایانه شما (شامل بازی‌های آنلاین، برنامه‌های بدون قابلیت پروکسی، CMD، گیت و کلاینت‌های دسکتاپ) را بدون استثنا از تونل عبور می‌دهد. برای گیمینگ و جلوگیری از هرگونه نشت DNS و WebRTC این گزینه پیشنهاد می‌شود.
''',
                ),
                _buildHelpAccordion(
                  title: '۳. شبکه ضدسانسور اِتر (MASQUE Aether Engine)',
                  icon: Icons.bolt_rounded,
                  iconColor: const Color(0xFF00D2FF),
                  content: '''
این تب به شما امکان اتصال مستقل به شبکه Zero Trust کلودفلر را بدون نیاز به هیچ کانفیگ، دامنه یا سرور خارجی می‌دهد!

• حالت خودکار (Auto Failover):
بهترین حالت پیشنهادی است که پروتکل‌های مختلف را به‌صورت زنده تست کرده و روی پایدارترین مسیر قفل می‌شود.

• حالت MASQUE H3 (QUIC):
پرسرعت‌ترین حالت ممکن بر بستر HTTP/3 که بدون تاخیر دست‌دهی اولیه (0-RTT) استریم‌های 4K و وب‌گردی پرسرعت را فراهم می‌کند.

• حالت MASQUE H2 + Fragment:
مناسب زمان‌هایی که اینترنت اپراتورها ترافیک UDP را به‌شدت محدود یا مختل کرده‌اند.

• تنظیمات پارازیت (Noize):
گزینه Firewall برای مقاومت در برابر فیلترینگ شدید و گزینه Light برای حداکثر سرعت و حداقل پینگ کاربرد دارد.
''',
                ),
                _buildHelpAccordion(
                  title: '۴. پیکربندی و مدیریت سرورها (VLESS / Reality / Hysteria 2)',
                  icon: Icons.tune_rounded,
                  iconColor: const Color(0xFF6C5DD3),
                  content: '''
• وارد کردن کانفیگ یا سابسکریپشن:
کافیست لینک ساب (https://) یا لینک‌های تک‌کانفیگ (vless://، hysteria2://، hy2://، trojan://) یا متن Base64 را در کادر بالای این تب قرار دهید و دکمه «وارد کردن» را بزنید.

• تست پینگ دسته‌جمعی و مرتب‌سازی:
با زدن دکمه «پینگ دسته‌جمعی و مرتب‌سازی»، هسته باینری راست تمام سرورها را به‌طور موازی در کمتر از ۲ ثانیه پایش کرده و سرورهای سالم و پرسرعت را به صدر لیست می‌آورد.

• ویرایش دستی و فعال‌سازی Reality و ECH:
با کلیک روی آیکون مداد هر سرور، می‌توانید پارامترهای پیشرفته مثل کلید عمومی Reality (pbk)، شناسه (sid)، مسیر (Path) و هدرهای ECH را ویرایش و ذخیره کنید.
''',
                ),
                _buildHelpAccordion(
                  title: '۵. شبکه‌های پیاز تور (Tor over MASQUE) و سایفون (Psiphon over MASQUE)',
                  icon: Icons.blur_circular_rounded,
                  iconColor: const Color(0xFFE94057),
                  content: '''
• اتصال تور بر بستر مسک (Tor over MASQUE):
گره‌های گارد تور از پل ضدسانسور MASQUE عبور کرده و فیلترینگ گاردها را دور می‌زنند تا ارتباط شما با کشور خروجی دلخواه (آلمان، آمریکا، هلند، بریتانیا و...) ۱۰۰٪ برقرار شود.

• اتصال سایفون بر بستر مسک (Psiphon over MASQUE):
ترافیک اولیه و هندشیک‌های سایفون از درون پل MASQUE عبور کرده و به کشور انتخابی تحویل داده می‌شود.
''',
                ),
                _buildHelpAccordion(
                  title: '۶. اسکنر دوحالته کلودفلر (Quick & Deep Scanner)',
                  icon: Icons.radar_rounded,
                  iconColor: const Color(0xFFFF8008),
                  content: '''
• اسکن سریع (Quick Scan):
تست چندثانیه‌ای روی لیست منتخب از آی‌پی‌های پرسرعت برای اتصالات فوری.

• اسکن عمیق و جامع (Deep Scan):
استفاده از فایل cloudflare_IPs.txt و اسکن موازی هزاران آی‌پی از دل رنج‌های CIDR ابری.

• کنترل زنده و دکمه توقف (Stop):
در حین اسکن آمار آی‌پی‌های کل، سالم و مرده نمایش داده می‌شود و هر زمان دکمه Stop را بزنید، با آی‌پی‌های سفید کشف‌شده تا همان لحظه کانفیگ ساخته می‌شود.
''',
                ),
                _buildHelpAccordion(
                  title: '۷. تغییر دهنده هوشمند دی‌ان‌اس (DNS Changer)',
                  icon: Icons.dns_rounded,
                  iconColor: const Color(0xFF6DD5ED),
                  content: '''
این تب به شما اجازه می‌دهد بدون روشن کردن فیلترشکن، تحریم‌های اینترنتی علیه کاربران ایرانی (مثل سایت‌های هوش مصنوعی، دیسکورد، اپیک گیمز، ادوبی، داکر و بازی‌های آنلاین) را دور بزنید!
دی‌ان‌اس‌های معروف مانند شکن، الکترو، ۴۰۳ آنلاین، رادار گیم و همچنین DNSهای فوق امن رمزنگاری‌شده DoH (کلودفلر، ادگارد، نکست‌دی‌ان‌اس) در این تب آماده انتخاب هستند.
''',
                ),
                _buildHelpAccordion(
                  title: '۸. تنظیمات فوق‌پیشرفته ضدسانسور (Anti-DPI)',
                  icon: Icons.security_rounded,
                  iconColor: const Color(0xFFED213A),
                  content: '''
• شبیه‌ساز اثر انگشت (uTLS Fingerprint):
دست‌دهی کلاینت شما را کاملاً شبیه مرورگر گوگل کروم واقعی نشان می‌دهد تا فیلترینگ نتواند ترافیک نرم‌افزار را از وب‌گردی عادی تفکیک کند.

• قطعه‌بندی پکت‌ها (TLS Fragmentation):
پکت ClientHello حاوی نام دامنه (SNI) را به قطعات چند بایتی خرد می‌کند تا سیستم فیلترینگ DPI نتواند مقصد شما را بخواند و مسدود کند.

• جعل تزریقی دامنه (TLS Spoofing):
قبل از ارسال درخواست اصلی، یک پکت فیک با دامنه کاملاً باز و مجاز (مانند zoom.us یا microsoft.com) ارسال می‌کند تا حسگرهای فیلترینگ دور بخورند.
''',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHelpAccordion({
    required String title,
    required IconData icon,
    required Color iconColor,
    required String content,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      child: _buildGlassContainer(
        padding: EdgeInsets.zero,
        borderRadius: 16,
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
          childrenPadding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF090B10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                content.trim(),
                style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.8),
                textAlign: TextAlign.justify,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAntiDpiSettingsPage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('تنظیمات فوق پیشرفته ضدسانسور (Anti-DPI)', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text('تکنیک‌های جعل دست‌دهی TLS و قطعه‌بندی ترافیک', style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded, color: Colors.grey),
              onPressed: () {
                setState(() {
                  _selectedMenuIndex = 0;
                });
              },
            )
          ],
        ),
        const SizedBox(height: 28),
        Expanded(
          child: SingleChildScrollView(
            child: _buildGlassContainer(
              borderColor: const Color(0xFFED213A).withValues(alpha: 0.35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('۱. شبیه‌ساز اثر انگشت مرورگر (uTLS Fingerprint)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008))),
                  const SizedBox(height: 8),
                  Text(
                    'تغییر اثر انگشت امنیتی ClientHello به شکل مرورگرهای واقعی دسکتاپ',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090B10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: DropdownButton<String>(
                      value: _selectedUtlsFingerprint,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF0D101A),
                      underline: const SizedBox(),
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      onChanged: (String? val) {
                        if (val != null) {
                          setState(() {
                            _selectedUtlsFingerprint = val;
                          });
                        }
                      },
                      items: const [
                        DropdownMenuItem(value: 'chrome', child: Text('Google Chrome (پیشنهادی)')),
                        DropdownMenuItem(value: 'firefox', child: Text('Mozilla Firefox')),
                        DropdownMenuItem(value: 'safari', child: Text('Apple Safari')),
                        DropdownMenuItem(value: 'edge', child: Text('Microsoft Edge')),
                        DropdownMenuItem(value: 'randomized', child: Text('Randomized (تصادفی)')),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 40),

                  const Text('۲. قطعه‌بندی پکت‌های امنیتی (Fragmentation)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008))),
                  const SizedBox(height: 8),
                  Text(
                    'خرد کردن پکت ClientHello برای ممانعت از خوانده شدن SNI توسط DPI',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('فعال‌سازی قطعه‌بندی (TLS Fragmentation)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    subtitle: const Text('خرد کردن بسته سلام برای مهار تشخیص SNI', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    value: _enableFragment,
                    activeThumbColor: const Color(0xFFED213A),
                    onChanged: (bool value) {
                      setState(() {
                        _enableFragment = value;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('فعال‌سازی قطعه‌بندی رکوردها (TLS Record Fragmentation)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    subtitle: const Text('تکه‌تکه کردن داده‌ها در لایه رکوردهای رمزنگاری', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    value: _enableRecordFragment,
                    activeThumbColor: const Color(0xFFED213A),
                    onChanged: (bool value) {
                      setState(() {
                        _enableRecordFragment = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _fallbackDelayController,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: 'تاخیر زمانی فالبک قطعه‌بندی (fallback delay)',
                      hintText: 'مثلاً 500ms یا 100ms',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 40),

                  const Text('۳. جعل تزریقی اس‌ان‌آی (TLS Spoofing)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008))),
                  const SizedBox(height: 8),
                  Text(
                    'تزریق هدر سلام فیک با دامنه مجاز (مانند zoom.us) پیش از پکت اصلی',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('فعال‌سازی سیستم جعل تزریقی SNI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    subtitle: const Text('دور زدن DPI با ارسال اس‌ان‌آی فیک مجاز', style: TextStyle(fontSize: 10, color: Colors.grey)),
                    value: _enableTlsSpoof,
                    activeThumbColor: const Color(0xFFED213A),
                    onChanged: (bool value) {
                      setState(() {
                        _enableTlsSpoof = value;
                      });
                    },
                  ),
                  if (_enableTlsSpoof) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tlsSpoofController,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'نام دامنه مجاز (مانند zoom.us یا microsoft.com)',
                        hintText: 'دامنه‌ای که در فیلترینگ کاملاً باز باشد',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 36),

                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        await _saveAntiDpiToDisk();
                        scaffoldMessenger.showSnackBar(
                          const SnackBar(
                            content: Text('تنظیمات پیشرفته Anti-DPI با موفقیت اعمال شد.'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                        setState(() {
                          _selectedMenuIndex = 0;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFED213A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 12,
                        shadowColor: const Color(0xFFED213A).withValues(alpha: 0.4),
                      ),
                      icon: const Icon(Icons.check_circle_rounded, color: Colors.white),
                      label: const Text('ثبت و اعمال تنظیمات ضدسانسور', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocationCard() {
    final bool isAnyConnected = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning;
    if (!isAnyConnected) return const SizedBox.shrink();

    return _buildGlassContainer(
      padding: const EdgeInsets.all(16),
      borderRadius: 18,
      borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.3),
      child: _isLoadingIpInfo
          ? const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)),
                ),
                SizedBox(width: 16),
                Text('در حال استعلام هویت و موقعیت جغرافیایی سرور...', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            )
          : Row(
              children: [
                if (_countryCode != null && _countryCode!.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      'https://flagcdn.com/w80/${_countryCode!.toLowerCase()}.png',
                      width: 48,
                      height: 32,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.flag, size: 28),
                    ),
                  )
                else
                  const Icon(Icons.public_rounded, size: 32, color: Color(0xFF00D2FF)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _publicIp ?? 'در حال دریافت آی‌پی...',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_publicIp != null)
                            InkWell(
                              onTap: () {
                                Clipboard.setData(ClipboardData(text: _publicIp!));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('آی‌پی کپی شد!'), duration: Duration(seconds: 1)),
                                );
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
                  onPressed: () => _fetchIpInfo(retryCount: 1),
                )
              ],
            ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return _buildGlassContainer(
      padding: const EdgeInsets.all(18),
      borderRadius: 18,
      borderColor: color.withValues(alpha: 0.3),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
            ),
            child: Icon(icon, color: color, size: 22),
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
}

class _TabTheme {
  final List<Color> gradient;
  final Color accent;
  final Color glow;
  final IconData icon;
  final String title;

  const _TabTheme({
    required this.gradient,
    required this.accent,
    required this.glow,
    required this.icon,
    required this.title,
  });
}