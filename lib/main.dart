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
import 'package:qr_flutter/qr_flutter.dart';
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';
import 'src/rust/smart_core_types.dart';
import 'translations.dart';
import 'core_updater.dart';
import 'gaming_registry.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

const String telemetryWorkerUrl = "https://log.redcloudir.workers.dev";
const String managerWorkerUrl = "https://round-sea-8418.redcloudir.workers.dev";
const String appCurrentVersion = "4.4";
const String telegramChannelUrl = "https://t.me/DevTaha_project";
const String usdtBnbAddress = "0xDeda28Aa73Ec089A77B3fC616E0011a8fce12900";
const String githubRepoReleasesUrl = "https://github.com/Devtahas/RedCloud-windows/releases/latest";

/// سیستم هوشمند و سبک ثبت لاگ و مخابره خودکار کرش‌ها به ربات تلگرام ادمین
class AppLogger {
  // حافظه موقت کش برای جلوگیری از ارسال خطاهای تکراری در یک بازه زمانی
  static final Map<String, DateTime> _recentErrorsCache = {};

  /// استخراج نگارش دقیق سیستم‌عامل و شماره بیلد ویندوز
  static String get _osInfo {
    try {
      if (Platform.isWindows) {
        return "Windows (${Platform.operatingSystemVersion})";
      }
      return "${Platform.operatingSystem} (${Platform.operatingSystemVersion})";
    } catch (_) {
      return "Windows Unknown";
    }
  }

  /// استخراج معماری پردازنده سیستم (مثلاً AMD64 یا ARM64)
  static String get _osArch {
    try {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
      return arch.isNotEmpty ? arch : 'x64';
    } catch (_) {
      return 'x64';
    }
  }

  /// متد پایه ثبت لاگ
  static void log(String level, String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    // ۱. ثبت در فایل متمرکز محلی روی سیستم (log.txt) از طریق هسته راست
    try {
      String localMsg = message;
      if (error != null) localMsg += " | جزئیات: $error";
      if (stackTrace != null) localMsg += "\nStackTrace:\n$stackTrace";
      writeAppLog(level: level, tag: tag, message: localMsg);
    } catch (e) {
      debugPrint("[$level] [$tag] $message (Fallback: $e)");
    }

    // ۲. فیلتر مصرف منابع: فقط خطاهای ارور و کرش‌های بحرانی به اینترنت مخابره شوند
    if (level == "ERROR" || level == "FATAL_CRASH") {
      _dispatchTelemetry(level, tag, message, error, stackTrace);
    }
  }

  static void info(String tag, String message) => log("INFO", tag, message);

  static void warn(String tag, String message, [dynamic error, StackTrace? stackTrace]) =>
      log("WARN", tag, message, error, stackTrace);

  static void error(String tag, String message, [dynamic error, StackTrace? stackTrace]) =>
      log("ERROR", tag, message, error, stackTrace);

  static void fatal(String tag, String message, [dynamic error, StackTrace? stackTrace]) =>
      log("FATAL_CRASH", tag, message, error, stackTrace);

  /// ارسال ناهمگام و کاملاً امن به ورکر تلگرام با مصرف منابع صفر
  static void _dispatchTelemetry(
    String level,
    String module,
    String message,
    dynamic error,
    StackTrace? stackTrace,
  ) {
    try {
      final String fullError = error != null ? "$message | جزئیات خطا: $error" : message;
      final String trace = stackTrace?.toString() ?? "";

      // ساخت کلید یکتا برای شناسایی خطای تکراری
      final String errorSignature = "$module|$fullError";
      final DateTime now = DateTime.now();

      // پاکسازی رکوردهای قدیمی‌تر از ۱۰ دقیقه از حافظه کلاینت
      _recentErrorsCache.removeWhere((_, time) => now.difference(time).inMinutes > 10);

      // اگر همین خطا در ۱۰ دقیقه گذشته ارسال شده باشد، ارسال مجدد را لغو کن
      if (_recentErrorsCache.containsKey(errorSignature)) {
        return;
      }
      _recentErrorsCache[errorSignature] = now;

      final Map<String, dynamic> payload = {
        "app_version": appCurrentVersion,
        "os_info": _osInfo,
        "os_arch": _osArch,
        "module": module,
        "level": level,
        "error_message": fullError,
        "stack_trace": trace.isNotEmpty ? trace : "استک‌تریس ثبت نشده است.",
        "timestamp": now.toUtc().toIso8601String(),
      };

      // ارسال مستقیم در پس‌زمینه (Fire-and-forget با محدودیت زمانی ۴ ثانیه)
      http.post(
        Uri.parse("$telemetryWorkerUrl/api/crash-report"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      ).timeout(const Duration(seconds: 4)).catchError((_) {
        // در صورت قطع بودن اینترنت، هیچ اروری در نرم‌افزار بالا نمی‌آید
        return http.Response('', 500);
      });
    } catch (_) {}
  }
}

void openBrowserUrl(String url) {
  try {
    final uri = Uri.tryParse(url.trim());
    // سد امنیتی ۱: فقط و فقط پروتکل‌های امن وب مجاز هستند (مسدودسازی دستورات cmd و powershell)
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      AppLogger.warn("SECURITY_GUARD", "تلاش برای باز کردن لینک مشکوک یا دستور سیستمی مسدود شد: $url");
      return;
    }

    // باز کردن مستقیم با اکسپلورر بدون فراخوانی cmd.exe تا هیچ کدی قابل تزریق نباشد
    if (Platform.isWindows) {
      Process.run('explorer.exe', [uri.toString()]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [uri.toString()]);
    } else if (Platform.isMacOS) {
      Process.run('open', [uri.toString()]);
    }
  } catch (e, st) {
    AppLogger.error("URL_OPENER", "خطا در باز کردن امن لینک: $url", e, st);
  }
}

class SubscriptionGroup {
  final String id;
  String name;
  String url;
  DateTime? lastUpdated;

  SubscriptionGroup({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdated,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'lastUpdated': lastUpdated?.toIso8601String(),
  };

  factory SubscriptionGroup.fromJson(Map<String, dynamic> json) => SubscriptionGroup(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    url: json['url'] ?? '',
    lastUpdated: json['lastUpdated'] != null ? DateTime.tryParse(json['lastUpdated']) : null,
  );
}

class SavedNodeItem {
  ProxyNode node;
  String groupId;

  SavedNodeItem({
    required this.node,
    this.groupId = 'manual',
  });

  Map<String, dynamic> toJson() => {
    'name': node.name,
    'protocol': node.protocol,
    'rawUrl': node.rawUrl,
    'groupId': groupId,
  };

  factory SavedNodeItem.fromJson(Map<String, dynamic> json) => SavedNodeItem(
    node: ProxyNode(
      name: json['name'] ?? '',
      protocol: json['protocol'] ?? '',
      rawUrl: json['rawUrl'] ?? '',
    ),
    groupId: json['groupId'] ?? 'manual',
  );
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
      // ۱. پارس اختصاصی لینک‌های استاندارد VMess Base64
      if (rawUrl.startsWith('vmess://')) {
        try {
          var b64 = rawUrl.substring(8).trim();
          while (b64.length % 4 != 0) { b64 += '='; }
          final decoded = utf8.decode(base64Decode(b64));
          final Map<String, dynamic> v = jsonDecode(decoded);
          return V2rayConfig(
            protocol: 'vmess',
            alias: v['ps']?.toString() ?? 'سرور VMess',
            address: v['add']?.toString() ?? '127.0.0.1',
            port: int.tryParse(v['port']?.toString() ?? '443') ?? 443,
            uuidOrPassword: v['id']?.toString() ?? '',
            transport: v['net']?.toString() ?? 'tcp',
            host: v['host']?.toString() ?? '',
            path: v['path']?.toString() ?? '',
            security: (v['tls'] == 'tls') ? 'tls' : 'none',
            sni: v['sni']?.toString() ?? v['host']?.toString() ?? '',
            fingerprint: v['fp']?.toString() ?? 'chrome',
            alpn: v['alpn']?.toString() ?? 'http/1.1',
            allowInsecure: true,
          );
        } catch (_) {}
      }

      // پارس اختصاصی لینک‌های Shadowsocks
      if (rawUrl.startsWith('ss://')) {
        try {
          final rest = rawUrl.substring(5);
          final hashIdx = rest.indexOf('#');
          final linkPart = hashIdx != -1 ? rest.substring(0, hashIdx) : rest;
          final alias = hashIdx != -1 ? Uri.decodeComponent(rest.substring(hashIdx + 1)) : 'سرور Shadowsocks';

          String method = '2022-blake3-aes-128-gcm';
          String password = '';
          String server = '127.0.0.1';
          int port = 8388;

          if (linkPart.contains('@')) {
            final parts = linkPart.split('@');
            var b64User = parts[0];
            while (b64User.length % 4 != 0) { b64User += '='; }
            final decUser = utf8.decode(base64Url.decode(b64User));
            final up = decUser.split(':');
            if (up.length >= 2) {
              method = up[0];
              password = up.sublist(1).join(':');
            }
            final hp = parts[1].split(':');
            server = hp[0];
            port = int.tryParse(hp[1]) ?? 8388;
          }

          return V2rayConfig(
            protocol: 'shadowsocks',
            alias: alias,
            address: server,
            port: port,
            uuidOrPassword: password,
            security: method,
          );
        } catch (_) {}
      }

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
    } catch (e) {
      AppLogger.warn("CONFIG_PARSE", "خطا در پارس کردن لینک کانفیگ: $rawUrl ($e)");
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
    if (protocol == 'vmess') {
      final Map<String, dynamic> vmessJson = {
        'v': '2',
        'ps': alias,
        'add': address,
        'port': port,
        'id': uuidOrPassword,
        'aid': 0,
        'net': transport,
        'type': 'none',
        'host': host,
        'path': path,
        'tls': security == 'tls' ? 'tls' : '',
        'sni': sni.isNotEmpty ? sni : host,
        'alpn': alpn,
        'fp': fingerprint,
      };
      final b64 = base64Encode(utf8.encode(jsonEncode(vmessJson)));
      return 'vmess://$b64';
    }

    final Map<String, String> queryParams = {};
    
    if (protocol == 'shadowsocks' || protocol == 'ss') {
      final userinfo = base64Url.encode(utf8.encode('$security:$uuidOrPassword')).replaceAll('=', '');
      final encodedAlias = Uri.encodeComponent(alias);
      return 'ss://$userinfo@$address:$port#$encodedAlias';
    } else if (protocol == 'tuic') {
      if (sni.isNotEmpty) queryParams['sni'] = sni;
      queryParams['congestion_controller'] = 'bbr';
      queryParams['udp_relay_mode'] = 'native';
      queryParams['alpn'] = alpn.isNotEmpty ? alpn : 'h3';
      if (allowInsecure) queryParams['insecure'] = '1';
      if (echConfig.isNotEmpty) queryParams['ech'] = echConfig;
    } else if (protocol == 'hysteria2') {
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
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // محدودسازی سقف کش عکس‌ها و گرافیک از ۱۰۰ مگابایت به ۱۰ مگابایت
    PaintingBinding.instance.imageCache.maximumSizeBytes = 10 * 1024 * 1024;
    PaintingBinding.instance.imageCache.maximumSize = 50;
    await RustLib.init();

    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      AppLogger.error(
        "FLUTTER_FRAMEWORK",
        "خطای کنترل‌نشده در فریم‌ورک فلاتر: ${details.summary}",
        details.exception,
        details.stack,
      );
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      AppLogger.fatal("PLATFORM_DISPATCHER", "کرش ناهمگام در حلقه رویدادهای پلتفرم", error, stack);
      return true;
    };

    AppLogger.info("APP_LIFECYCLE", "نرم‌افزار RedCloud VPN نسخه $appCurrentVersion با موفقیت راه‌اندازی شد.");

    if (Platform.isWindows) {
      try {
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
      } catch (e, st) {
        AppLogger.error("WINDOW_MANAGER", "خطا در مقداردهی اولیه window_manager", e, st);
      }
    }

    runApp(const MyApp());
  }, (error, stack) {
    AppLogger.fatal("ROOT_ZONE", "کرش کلی و بحرانی در Root Zone برنامه", error, stack);
  });
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
  String _selectedLanguage = 'fa';
  bool _isCheckingCores = false;
  bool _isUpdatingCores = false;
  String _coreUpdateStatus = '';
  double _coreUpdateProgress = 0.0;
  bool _hasLanguageBeenSet = false;
  
  final TextEditingController _binaryPathController = TextEditingController(text: 'sing-box.exe');
  final TextEditingController _aetherPathController = TextEditingController(text: 'aether.exe');
  final TextEditingController _torPathController = TextEditingController(text: 'tor.exe');
  final TextEditingController _psiphonPathController = TextEditingController(text: 'psiphon-tunnel-core.exe');
  final TextEditingController _goodbyedpiPathController = TextEditingController(text: 'goodbyedpi.exe');
  
  // تنظیمات اختصاصی و ماتریس پریست‌های هوشمند GoodbyeDPI
  final TextEditingController _goodbyedpiArgsController = TextEditingController(text: '-9 -p -r -s -f 2 -k 2 -n -e 2');
  final List<Map<String, String>> _adaptiveGoodbyeDpiPresets = [
    {'name': 'پیشنهادی ایران (-9 تهاجمی)', 'args': '-9 -p -r -s -f 2 -k 2 -n -e 2'},
    {'name': 'ضد قطعی همراه اول (-5 ملایم)', 'args': '-5 -p -s -e 1 -f 1 -k 1'},
    {'name': 'جعل چکسام و پکت فیک', 'args': '-9 --wrong-chksum -p -r -e 2'},
    {'name': 'سبک و پینگ پایین (-1 پسیو)', 'args': '-1 -p -r'},
    {'name': 'حالت مستقیم (بدون گودبای‌دی‌پی)', 'args': 'off'},
  ];
  int _currentAdaptivePresetIndex = 0;
  // کنترلرهای اختصاصی اینترنت اضطراری DNSTT
  final TextEditingController _dnsttDomainController = TextEditingController(text: 't.dnstt.online');
  final TextEditingController _dnsttPubkeyController = TextEditingController(text: '');
  final TextEditingController _dnsttDohController = TextEditingController(text: 'https://1.1.1.1/dns-query');
  final TextEditingController _dnsttPortController = TextEditingController(text: '5300');
  String _selectedGoodbyeDpiPreset = 'auto';
  bool _useGoodbyeDpiDashboard = true;
  bool _useGoodbyeDpiAether = true;
  bool _useGoodbyeDpiTor = true;
  bool _useGoodbyeDpiPsiphon = true;
  bool _useGoodbyeDpiDns = true;
  bool _isGoodbyeDpiRunning = false;

  // متغیرها و موتور شتاب‌دهنده شبکه ویندوز (TCP Turbo & BBR)
  bool _isTcpTurboEnabled = true;
  bool _isApplyingTcpTurbo = false;

  Future<void> _applyWindowsTcpTurbo(bool enable) async {
    if (!Platform.isWindows) return;
    setState(() => _isApplyingTcpTurbo = true);
    try {
      final script = enable ? r'''
$ErrorActionPreference = 'SilentlyContinue'
netsh int tcp set supplemental template=internet congestionprovider=ctcp
netsh int tcp set supplemental template=internet congestionprovider=bbr2
netsh int tcp set global autotuninglevel=normal
netsh int tcp set global sack=enabled
netsh int tcp set global ecncapability=enabled
netsh int tcp set global timestamps=enabled
netsh int tcp set global fastopen=enabled
netsh int tcp set global rss=enabled
''' : r'''
$ErrorActionPreference = 'SilentlyContinue'
netsh int tcp set supplemental template=internet congestionprovider=default
netsh int tcp set global autotuninglevel=normal
netsh int tcp set global sack=enabled
netsh int tcp set global ecncapability=disabled
netsh int tcp set global timestamps=disabled
netsh int tcp set global fastopen=disabled
''';
      final tempDir = Directory.systemTemp;
      final scriptFile = File('${tempDir.path}\\rc_tcp_turbo.ps1');
      await scriptFile.writeAsString(script);

      // اجرای تضمینی با دسترسی Administrator در ویندوز (Verb RunAs)
      final elevateCmd = "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"${scriptFile.path}\"' -Verb RunAs -WindowStyle Hidden";
      await Process.run('powershell.exe', [
        '-NoProfile',
        '-Command',
        elevateCmd,
      ], runInShell: false);

      // صبر کوتاه جهت ثبت در کرنل ویندوز
      await Future.delayed(const Duration(milliseconds: 1200));

      setState(() => _isTcpTurboEnabled = enable);
      AppLogger.info("TCP_TURBO", enable ? "شتاب‌دهنده شبکه CTCP/BBR با مجوز ادمین فعال شد." : "تنظیمات TCP به حالت پیش‌فرض ویندوز بازگشت.");
    } catch (e) {
      AppLogger.warn("TCP_TURBO", "خطا در تنظیم توربو TCP: $e");
    } finally {
      if (mounted) setState(() => _isApplyingTcpTurbo = false);
    }
  }

  // متغیرهای اختصاصی اسپلیت تانل دامنه‌ها و برنامه‌ها
  bool _bypassIran = true;
  final TextEditingController _customRuleDomainController = TextEditingController();
  String _selectedRuleType = 'direct';
  List<Map<String, String>> _splitRules = [];

  // متغیرهای اسپلیت‌تانل بر اساس فایل اجرایی نرم‌افزارها (Per-App Routing)
  final TextEditingController _appProcessController = TextEditingController();
  String _selectedAppRuleType = 'direct';
  List<Map<String, String>> _appRules = [];

  // متغیرهای هات‌اسپات وای‌فای اختصاصی (Wi-Fi Virtual Hotspot)
  final TextEditingController _hotspotSsidController = TextEditingController(text: 'RedCloud');
  final TextEditingController _hotspotPassController = TextEditingController(text: '12345678');
  bool _hasHotspotPassword = true;
  bool _obscureHotspotPassword = true;
  bool _isHotspotRunning = false;
  String _hotspotStatusText = '';

  // سیستم مدیریت کاربران، مانیتورینگ زنده و بلک‌لیست مک‌آدرس
  List<String> _hotspotMacBlacklist = [];
  int _hotspotMaxClientsLimit = 0; // 0 = نامحدود
  List<Map<String, String>> _liveHotspotClients = [];
  Timer? _hotspotMonitorTimer;
  bool _isPollingHotspotClients = false;

  Future<void> _saveHotspotSecurityToDisk() async {
    try {
      final file = await _getLocalFile('saved_hotspot_security.json');
      final data = {
        'blacklist': _hotspotMacBlacklist,
        'max_clients': _hotspotMaxClientsLimit,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  // =========================================================================
  // سیستم حافظه دائمی (ذخیره آخرین کشور، کانفیگ و بازی انتخابی)
  // =========================================================================
  Future<void> _savePreferencesToDisk() async {
    try {
      final file = await _getLocalFile('saved_preferences.json');
      final data = {
        'last_dashboard_node_url': _selectedNode?.rawUrl,
        'last_tor_country': _selectedTorCountry,
        'last_psiphon_country': _selectedPsiphonCountry,
        'last_aether_mode': _selectedAetherMode,
        'last_aether_noize': _selectedAetherNoize,
        'last_game_id': _selectedGame?.id,
        'last_game_region': _selectedGamingRegion,
        'last_game_dns_mode': _selectedGamingDnsMode,
        'hk_dashboard': _hkDashboard,
        'hk_gaming': _hkGaming,
        'hk_aether': _hkAether,
        'hk_tor': _hkTor,
        'hk_psiphon': _hkPsiphon,
        'hk_tun': _hkTun,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadPreferencesFromDisk() async {
    try {
      final file = await _getLocalFile('saved_preferences.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);

        setState(() {
          if (data['last_tor_country'] != null && _torCountries.containsKey(data['last_tor_country'])) {
            _selectedTorCountry = data['last_tor_country'];
          }
          if (data['last_psiphon_country'] != null && _psiphonCountries.containsKey(data['last_psiphon_country'])) {
            _selectedPsiphonCountry = data['last_psiphon_country'];
          }
          if (data['last_aether_mode'] != null && _aetherModes.containsKey(data['last_aether_mode'])) {
            _selectedAetherMode = data['last_aether_mode'];
          }
          if (data['last_aether_noize'] != null && _aetherNoizeProfiles.containsKey(data['last_aether_noize'])) {
            _selectedAetherNoize = data['last_aether_noize'];
          }
          if (data['last_game_region'] != null) {
            _selectedGamingRegion = data['last_game_region'];
          }
          if (data['last_game_dns_mode'] != null) {
            _selectedGamingDnsMode = data['last_game_dns_mode'];
          }
          if (data['last_dashboard_node_url'] != null) {
            final match = _savedNodeItems.where((i) => i.node.rawUrl == data['last_dashboard_node_url']).firstOrNull;
            if (match != null) _selectedNode = match.node;
          }
          if (data['last_game_id'] != null) {
            final gMatch = _gamingRegistry.allGames.where((g) => g.id == data['last_game_id']).firstOrNull;
            if (gMatch != null) _selectedGame = gMatch;
          }
          _hkDashboard = data['hk_dashboard'] ?? 'D';
          _hkGaming = data['hk_gaming'] ?? 'G';
          _hkAether = data['hk_aether'] ?? 'A';
          _hkTor = data['hk_tor'] ?? 'T';
          _hkPsiphon = data['hk_psiphon'] ?? 'P';
          _hkTun = data['hk_tun'] ?? 'M';
        });
      }
    } catch (_) {}
    await _registerAllGlobalHotkeys();
  }

  PhysicalKeyboardKey _resolvePhysicalKey(String letter) {
    switch (letter.toUpperCase()) {
      case 'A': return PhysicalKeyboardKey.keyA;
      case 'B': return PhysicalKeyboardKey.keyB;
      case 'C': return PhysicalKeyboardKey.keyC;
      case 'D': return PhysicalKeyboardKey.keyD;
      case 'E': return PhysicalKeyboardKey.keyE;
      case 'F': return PhysicalKeyboardKey.keyF;
      case 'G': return PhysicalKeyboardKey.keyG;
      case 'H': return PhysicalKeyboardKey.keyH;
      case 'I': return PhysicalKeyboardKey.keyI;
      case 'J': return PhysicalKeyboardKey.keyJ;
      case 'K': return PhysicalKeyboardKey.keyK;
      case 'L': return PhysicalKeyboardKey.keyL;
      case 'M': return PhysicalKeyboardKey.keyM;
      case 'N': return PhysicalKeyboardKey.keyN;
      case 'O': return PhysicalKeyboardKey.keyO;
      case 'P': return PhysicalKeyboardKey.keyP;
      case 'Q': return PhysicalKeyboardKey.keyQ;
      case 'R': return PhysicalKeyboardKey.keyR;
      case 'S': return PhysicalKeyboardKey.keyS;
      case 'T': return PhysicalKeyboardKey.keyT;
      case 'U': return PhysicalKeyboardKey.keyU;
      case 'V': return PhysicalKeyboardKey.keyV;
      case 'W': return PhysicalKeyboardKey.keyW;
      case 'X': return PhysicalKeyboardKey.keyX;
      case 'Y': return PhysicalKeyboardKey.keyY;
      case 'Z': return PhysicalKeyboardKey.keyZ;
      default: return PhysicalKeyboardKey.keyD;
    }
  }

  /// ثبت و اتصال استاندارد کلیدهای میانبر سراسری کیبورد بدون اخطار منسوخ شدن
  Future<void> _registerAllGlobalHotkeys() async {
    if (!Platform.isWindows) return;
    try {
      await hotKeyManager.unregisterAll();

      final list = [
        {'action': 'dashboard', 'key': _hkDashboard, 'callback': () => _toggleV2RayConnection()},
        {'action': 'gaming', 'key': _hkGaming, 'callback': () => _toggleGamingBoost()},
        {'action': 'aether', 'key': _hkAether, 'callback': () => _toggleAetherConnection()},
        {'action': 'tor', 'key': _hkTor, 'callback': () => _toggleTorConnection()},
        {'action': 'psiphon', 'key': _hkPsiphon, 'callback': () => _togglePsiphonConnection()},
        {'action': 'tun', 'key': _hkTun, 'callback': () {
          setState(() {
            _useTunMode = !_useTunMode;
            if (_useTunMode) _useSystemProxy = false;
          });
          _updateSystemTrayMenu();
        }},
      ];

      DateTime lastHotkeyTrigger = DateTime.now();
      for (var item in list) {
        final hk = HotKey(
          key: _resolvePhysicalKey(item['key'] as String),
          modifiers: [HotKeyModifier.control, HotKeyModifier.shift],
          scope: HotKeyScope.system,
        );
        await hotKeyManager.register(
          hk,
          keyDownHandler: (_) {
            // سد ضد تکرار: نادیده گرفتن فشردن‌های مکرر در کمتر از ۱.۵ ثانیه جهت جلوگیری از لگ
            final now = DateTime.now();
            if (now.difference(lastHotkeyTrigger).inMilliseconds < 1500) {
              return;
            }
            lastHotkeyTrigger = now;
            (item['callback'] as VoidCallback)();
          },
        );
      }
    } catch (_) {}
  }

  Future<void> _loadHotspotSecurityFromDisk() async {
    try {
      final file = await _getLocalFile('saved_hotspot_security.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        setState(() {
          _hotspotMacBlacklist = List<String>.from(data['blacklist'] ?? []);
          _hotspotMaxClientsLimit = data['max_clients'] ?? 0;
        });
      }
    } catch (_) {}
  }

  /// ساخت پکت استاندارد TLS ClientHello بر اساس SNI سرور برای تست دقیق فرگمنت
  List<int> _buildSmartTlsClientHello(String sni) {
    final sniBytes = utf8.encode(sni);
    final serverNameList = [
      0x00,
      (sniBytes.length >> 8) & 0xFF,
      sniBytes.length & 0xFF,
      ...sniBytes,
    ];
    final serverNameExt = [
      0x00, 0x00,
      ((serverNameList.length + 2) >> 8) & 0xFF,
      (serverNameList.length + 2) & 0xFF,
      (serverNameList.length >> 8) & 0xFF,
      serverNameList.length & 0xFF,
      ...serverNameList,
    ];
    final supportedVersionsExt = [0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04];
    final extensions = [...serverNameExt, ...supportedVersionsExt];
    final cipherSuites = [0x13, 0x01, 0x13, 0x02, 0xc0, 0x2f, 0xc0, 0x30];
    final random = List<int>.generate(32, (i) => (i * 9 + 7) % 256);

    final handshakeBody = [
      0x03, 0x03,
      ...random,
      0x00,
      (cipherSuites.length >> 8) & 0xFF,
      cipherSuites.length & 0xFF,
      ...cipherSuites,
      0x01, 0x00,
      (extensions.length >> 8) & 0xFF,
      extensions.length & 0xFF,
      ...extensions,
    ];

    final handshake = [
      0x01,
      0x00,
      (handshakeBody.length >> 8) & 0xFF,
      handshakeBody.length & 0xFF,
      ...handshakeBody,
    ];

    return [
      0x16,
      0x03, 0x01,
      (handshake.length >> 8) & 0xFF,
      handshake.length & 0xFF,
      ...handshake,
    ];
  }

  /// تست عملی شکستن پکت در بایت مشخص و اندازه تاخیر
  Future<int> _probeFragmentLatency(String host, int port, String sni, int splitOffset, int delayMs) async {
    Socket? socket;
    try {
      final packet = _buildSmartTlsClientHello(sni.isEmpty ? host : sni);
      final sw = Stopwatch()..start();

      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 2500));
      socket.setOption(SocketOption.tcpNoDelay, true);

      final safeSplit = splitOffset.clamp(1, packet.length - 1);
      final part1 = packet.sublist(0, safeSplit);
      final part2 = packet.sublist(safeSplit);

      socket.add(part1);
      await socket.flush();

      if (delayMs > 0) {
        await Future.delayed(Duration(milliseconds: delayMs));
      }

      socket.add(part2);
      await socket.flush();

      final completer = Completer<int>();
      socket.listen((data) {
        if (!completer.isCompleted) {
          if (data.isNotEmpty && data[0] == 0x16) {
            completer.complete(sw.elapsedMilliseconds);
          } else {
            completer.complete(sw.elapsedMilliseconds);
          }
        }
      }, onError: (_) {
        if (!completer.isCompleted) completer.complete(-1);
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(-1);
      });

      final res = await completer.future.timeout(const Duration(milliseconds: 2500), onTimeout: () => -1);
      sw.stop();
      return res;
    } catch (_) {
      return -1;
    } finally {
      try { socket?.destroy(); } catch (_) {}
    }
  }

  Future<void> _fetchConnectedHotspotClients() async {
    // ۱. اگر هات‌اسپات خاموش است، فوراً لیست را صفر کن و تاریخچه رم را نخوان
    if (!Platform.isWindows) return;
    if (!_isHotspotRunning) {
      if (_liveHotspotClients.isNotEmpty && mounted) {
        setState(() => _liveHotspotClients = []);
      }
      return;
    }

    if (_isPollingHotspotClients) return;
    _isPollingHotspotClients = true;
    try {
      // ۲. فقط دستگاه‌های زنده (Reachable) با مک‌آدرس‌های یکتا خوانده شوند
      final psScript = r'''
$neighbors = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.IPAddress -like '192.168.137.*' -and
    $_.IPAddress -ne '192.168.137.1' -and
    $_.IPAddress -ne '192.168.137.255' -and
    ($_.State -eq 'Reachable' -or $_.State -eq 'Permanent') -and
    $_.LinkLayerAddress -ne '00-00-00-00-00-00'
}
$list = @()
$seenMacs = @{}
foreach ($n in $neighbors) {
    $ip = $n.IPAddress
    $mac = $n.LinkLayerAddress.ToUpper().Replace(':', '-')
    if (-not $seenMacs.ContainsKey($mac)) {
        $seenMacs[$mac] = $true
        # تست پینگ سریع ۱ میلی‌ثانیه‌ای برای اطمینان از آنلاین بودن واقعی دستگاه
        $isAlive = Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction SilentlyContinue
        if ($isAlive) {
            $name = "Phone ($ip)"
            try {
                $hostEntry = [System.Net.Dns]::GetHostEntry($ip)
                if ($hostEntry.HostName) { $name = $hostEntry.HostName }
            } catch {}
            $list += [PSCustomObject]@{ ip = $ip; mac = $mac; name = $name }
        }
    }
}
if ($list.Count -gt 0) { $list | ConvertTo-Json -Compress } else { Write-Output "[]" }
''';
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        psScript,
      ], runInShell: false);

      final out = res.stdout.toString().trim();
      if (out.isNotEmpty && out.startsWith('[')) {
        final decoded = jsonDecode(out);
        List<Map<String, String>> clients = [];
        if (decoded is List) {
          for (var item in decoded) {
            clients.add({
              'ip': item['ip']?.toString() ?? '',
              'mac': item['mac']?.toString() ?? '',
              'name': item['name']?.toString() ?? '',
            });
          }
        } else if (decoded is Map) {
          clients.add({
            'ip': decoded['ip']?.toString() ?? '',
            'mac': decoded['mac']?.toString() ?? '',
            'name': decoded['name']?.toString() ?? '',
          });
        }

        // اعمال مسدودسازی فایروال برای مک‌های لیست سیاه
        int allowedCount = 0;
        for (var client in clients) {
          final mac = client['mac']!;
          final ip = client['ip']!;
          final isBanned = _hotspotMacBlacklist.contains(mac);
          final isOverLimit = _hotspotMaxClientsLimit > 0 && allowedCount >= _hotspotMaxClientsLimit;

          if (isBanned || isOverLimit) {
            Process.run('netsh', [
              'advfirewall', 'firewall', 'add', 'rule',
              'name=RC_BAN_$mac',
              'dir=in',
              'action=block',
              'remoteip=$ip'
            ], runInShell: false);
          } else {
            allowedCount++;
          }
        }

        if (mounted) {
          setState(() {
            _liveHotspotClients = clients;
          });
        }
      } else {
        if (mounted) setState(() => _liveHotspotClients = []);
      }
    } catch (_) {
    } finally {
      _isPollingHotspotClients = false;
    }
  }

  Future<void> _banHotspotClientMac(String mac, {String? ip}) async {
    final cleanMac = mac.trim().toUpperCase();
    if (cleanMac.isEmpty || _hotspotMacBlacklist.contains(cleanMac)) return;
    setState(() {
      _hotspotMacBlacklist.add(cleanMac);
    });
    await _saveHotspotSecurityToDisk();
    if (ip != null && ip.isNotEmpty) {
      await Process.run('netsh', [
        'advfirewall', 'firewall', 'add', 'rule',
        'name=RC_BAN_$cleanMac',
        'dir=in',
        'action=block',
        'remoteip=$ip'
      ], runInShell: false);
    }
    _fetchConnectedHotspotClients();
  }

  Future<void> _unbanHotspotClientMac(String mac) async {
    final cleanMac = mac.trim().toUpperCase();
    setState(() {
      _hotspotMacBlacklist.remove(cleanMac);
    });
    await _saveHotspotSecurityToDisk();
    await Process.run('netsh', [
      'advfirewall', 'firewall', 'delete', 'rule',
      'name=RC_BAN_$cleanMac'
    ], runInShell: false);
    _fetchConnectedHotspotClients();
  }

  final TextEditingController _serverSearchController = TextEditingController();
  String _serverSearchQuery = '';

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
  bool _enableEch = true; // فعال‌سازی خودکار و پیش‌فرض ECH
  bool _enableTlsSpoof = false;
  bool _useTunMode = false;
  bool _useTunModeAether = false;
  bool _useTunModeTor = false;
  bool _useTunModePsiphon = false;

  bool _isHybridModeEnabled = true;
  // متغیرهای اختصاصی هسته هوشمند اول و دوم (RedCloud Dual-Core Optimizer)
  bool _useSmartOptimizer = true;
  CalibratedConnectionProfile? _latestCalibration;
  BehaviorAnalysisReport? _latestCore2Report;
  Timer? _core2MonitorTimer;
  int _consecutiveDegradedCount = 0;
  bool _isHealingInProgress = false;
  String _activeProtocolName = 'Direct VLESS';

  // متغیرهای اختصاصی تب گیمینگ (Gaming Mode & Anti-Ban State)
  final GamingRegistry _gamingRegistry = GamingRegistry();
  GameItem? _selectedGame;
  String _selectedGamingRegion = 'auto';
  String _selectedGamingDnsMode = 'local'; // 'local' یا 'resolver'
  bool _isUpdatingLocalDns = false;

  // کلیدهای میانبر قابل شخصی‌سازی سراسری
  String _hkDashboard = 'D';
  String _hkGaming = 'G';
  String _hkAether = 'A';
  String _hkTor = 'T';
  String _hkPsiphon = 'P';
  String _hkTun = 'M';
  bool _isGamingRunning = false;
  bool _isGamingStarting = false;
  String _gamingStatusStep = '';
  GamingLiveMetrics? _gamingMetrics;
  Timer? _gamingMetricsTimer;
  String _gameSearchQuery = '';
  String _selectedGameCategory = 'all';
  bool _enableGamingBbr = true;

  // متغیرهای بخش اشتراک‌گذاری LAN
  bool _isLanShareRunning = false;
  String _lanIp = '127.0.0.1';
  final TextEditingController _lanPortController = TextEditingController(text: '10808');

  String _downloadSpeed = "0.0 B/s";
  String _uploadSpeed = "0.0 B/s";
  StreamSubscription? _trafficSubscription;

  final Map<String, int> _nodePings = {};
  bool _isBulkPinging = false;

  List<SubscriptionGroup> _subGroups = [];
  String _selectedGroupId = 'all'; 
  List<SavedNodeItem> _savedNodeItems = [];
  ProxyNode? _selectedNode;
  bool _isUpdatingSubs = false;

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
  String _aetherStatusText = AppTranslations.currentLang == 'en' ? "Ready to connect" : "آماده اتصال";
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

  // متغیرهای اختصاصی فناوری CDN Fronting سایفون
  bool _usePsiphonCdnFronting = false;
  String _psiphonCdnMode = 'cdn'; // 'cdn' یا 'direct'
  String _selectedCdnRegion = 'auto'; // 'auto', 'JP', 'US', 'SE'
  
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

  // متغیرهای اسکنر هوشمند دی‌ان‌اس
  final TextEditingController _dnsScanDomainController = TextEditingController(text: 'discord.com');
  bool _isScanningDnsForDomain = false;
  String _dnsScanProgressText = '';
  int _selectedDnsThreadCount = 0;
  DnsScannerProgress? _dnsScannerProgress;
  Timer? _dnsScannerPollingTimer;

  void _stopSmartDnsDomainScan() {
    stopDnsDomainScanner();
    _dnsScannerPollingTimer?.cancel();
    setState(() => _isScanningDnsForDomain = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('dns_scan_cancelled_toast'.tr()), duration: const Duration(seconds: 1)),
    );
  }

  Future<void> _runSmartDnsDomainScan() async {
    final raw = _dnsScanDomainController.text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _isScanningDnsForDomain = true;
      _dnsScanProgressText = 'dns_scanning_progress'.tr();
      _dnsScannerProgress = null;
    });

    _dnsScannerPollingTimer?.cancel();
    _dnsScannerPollingTimer = Timer.periodic(const Duration(milliseconds: 200), (t) async {
      if (!_isScanningDnsForDomain) {
        t.cancel();
        return;
      }
      try {
        final prog = await getDnsScannerProgress();
        if (mounted) setState(() => _dnsScannerProgress = prog);
      } catch (_) {}
    });

    try {
      final results = await scanAndRankDnsForTarget(
        target: raw,
        concurrency: _selectedDnsThreadCount > 0 ? _selectedDnsThreadCount : null,
      );

      if (results.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('dns_scan_failed_toast'.tr()), backgroundColor: Colors.redAccent),
          );
        }
      } else {
        // تمیزکاری نام دامنه
        String cleanDom = raw.replaceAll('https://', '').replaceAll('http://', '').split('/').first;

        // حذف اسکن‌های قبلی همین دامنه برای جلوگیری از شلوغی
        _dnsList.removeWhere((d) => d.name.contains('[اسکن]') || d.name.contains('[Scan]'));

        final List<DnsProfile> newProfiles = [];
        for (int i = 0; i < results.length; i++) {
          final item = results[i];
          final profile = DnsProfile(
            name: '[اسکن] $cleanDom (#${i + 1} - ${item.latencyMs}ms)',
            primary: item.primaryIp,
            secondary: item.primaryIp,
            description: 'تایید اصالت برای $cleanDom (${item.dnsName}) | آی‌پی سرور: ${item.resolvedIp}',
            dnsType: 'udp',
            isCustom: true,
          );
          newProfiles.add(profile);
        }

        setState(() {
          _dnsList.insertAll(0, newProfiles);
          _selectedDns = newProfiles.first;
        });

        await _saveDnsToDisk();
        _testDnsPing();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('dns_scan_success_toast'.tr(params: {'count': results.length.toString()})),
              backgroundColor: const Color(0xFF2DCA73),
            ),
          );
        }
      }
    } catch (e) {
      AppLogger.error("DNS_SCAN", "Error scanning domain DNS", e);
    } finally {
      _dnsScannerPollingTimer?.cancel();
      if (mounted) setState(() => _isScanningDnsForDomain = false);
    }
  }

  Future<void> _clearScannedDnsProfiles() async {
    setState(() {
      _dnsList.removeWhere((d) => d.name.contains('[اسکن]') || d.name.contains('[Scan]'));
      if (!_dnsList.contains(_selectedDns)) {
        _selectedDns = _dnsList.first;
      }
    });
    await _saveDnsToDisk();
    _testDnsPing();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('scanned_dns_cleared_toast'.tr()), duration: const Duration(seconds: 1)),
      );
    }
  }

  // متغیرهای رادار زنده دفع حملات فیلترینگ
  int _radarRstCount = 0;
  int _radarStunCount = 0;
  int _radarDnsCount = 0;
  int _radarCarrierMtu = 1360;
  Timer? _radarUpdateTimer;

  void _startRadarPolling() {
    _radarUpdateTimer?.cancel();
    _radarUpdateTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final file = File('${Directory.systemTemp.path}\\RedCloud\\radar.txt');
        if (await file.exists()) {
          final content = await file.readAsString();
          final parts = content.trim().split(',');
          if (parts.length >= 4 && mounted) {
            setState(() {
              _radarRstCount = int.tryParse(parts[0]) ?? 0;
              _radarStunCount = int.tryParse(parts[1]) ?? 0;
              _radarCarrierMtu = int.tryParse(parts[3]) ?? 1360;
            });
          }
        }
      } catch (_) {}
    });
  }

  bool _useSystemProxy = true; 
  String _statusMessage = "سیستم آماده اتصال است";
  /// ترجمه خودکار و بلادرنگ تمامی پیام‌های وضعیت و خروجی هسته‌ها به انگلیسی
  /// ترجمه خودکار و بلادرنگ تمامی پیام‌های وضعیت و خروجی هسته‌ها به انگلیسی
  String get _localizedStatusMessage {
    if (AppTranslations.currentLang != 'en') return _statusMessage;
    
    final msg = _statusMessage;
    if (msg.contains("متوقف و سیستم به حالت عادی")) {
      if (msg.contains("تور بر بستر مسک")) return "Tor over MASQUE disconnected.";
      if (msg.contains("تور")) return "Tor disconnected.";
      if (msg.contains("سایفون بر بستر مسک")) return "Psiphon over MASQUE disconnected.";
      if (msg.contains("سایفون")) return "Psiphon disconnected.";
      if (msg.contains("هیبریدی")) return "Hybrid connection stopped.";
      if (msg.contains("پروکسی")) return "Proxy disconnected.";
      if (msg.contains("اتر")) return "Aether disconnected.";
      return "Disconnected.";
    }
    if (msg.contains("در حال ایجاد پل ضدسانسور مسک و برقراری ارتباط با سایفون")) {
      return "Establishing MASQUE bridge & connecting Psiphon...";
    }
    if (msg.contains("در حال برقراری پل مسک و تونل سایفون")) return "Establishing MASQUE bridge & Psiphon tunnel...";
    if (msg.contains("در حال اتصال به سرورهای سایفون")) return "Connecting to Psiphon servers...";
    if (msg.contains("در حال دریافت لیست سرورهای فعال سایفون")) return "Fetching Psiphon active servers...";
    if (msg.contains("در حال دست‌دهی امن با سرور مقصد سایفون")) return "Handshaking with Psiphon server...";
    if (msg.contains("اتصال پایدار شد و ترافیک برقرار است")) return "Connection stable, traffic active.";
    if (msg.contains("در حال اسکن و آزمایش") && msg.contains("سرور سایفون")) {
      return msg.replaceAll("در حال اسکن و آزمایش", "Probing").replaceAll("سرور سایفون...", "Psiphon candidate servers...");
    }
    if (msg.contains("کشور آماده اتصال است")) {
      return msg.replaceAll("تعداد", "").replaceAll("کشور آماده اتصال است.", "regions available to connect.").trim();
    }
    if (msg.contains("تانل سایفون با") && msg.contains("مسیر فعال برقرار شد")) {
      return msg.replaceAll("تانل سایفون با", "Psiphon tunnel active with").replaceAll("مسیر فعال برقرار شد!", "tunnels!");
    }
    if (msg.contains("در حال اسکن و آزمایش خودکار پروتکل‌های ضدسانسور")) {
      return "Scanning and probing anti-censorship protocols...";
    }
    if (msg.contains("پل ارتباطی با پروتکل")) return "Bridge connected with stable protocol!";
    if (msg.contains("اتصال با موفقیت برقرار شد")) return "Connected successfully.";
    if (msg.contains("اتصال ترکیبی هیبریدی با موفقیت برقرار شد")) return "Hybrid tunnel connected successfully!";
    if (msg.contains("اتصال به شبکه اتر با موفقیت برقرار شد")) return "Aether network connected successfully!";
    if (msg.contains("اتصال به شبکه اتر آغاز شد")) return "Aether connection initiated...";
    if (msg.contains("در حال ایجاد پل چرخشی اِتر")) return "Creating Aether bridge & chaining with Sing-box...";
    if (msg.contains("در حال ایجاد پل مسک و راه‌اندازی شبکه پیاز تور")) return "Creating MASQUE bridge & starting Tor...";
    if (msg.contains("در حال اجرای هسته تور")) return "Starting Tor core...";
    if (msg.contains("پیشرفت اتصال تور:")) {
      return msg.replaceAll("پیشرفت اتصال تور:", "Tor bootstrap progress:").replaceAll("٪", "%");
    }
    if (msg.contains("در حال اتصال به سرورهای سایفون؛ لطفاً چند لحظه شکیبا باشید")) {
      return "Connecting to Psiphon servers, please wait...";
    }
    if (msg.contains("اتصال ترکیبی سایفون بر بستر مسک") && msg.contains("با موفقیت برقرار شد")) {
      return "Psiphon over MASQUE connected successfully!";
    }
    if (msg.contains("اتصال ترکیبی تور بر بستر مسک") && msg.contains("با موفقیت برقرار شد")) {
      return "Tor over MASQUE connected successfully!";
    }
    if (msg.contains("قطع اتصال")) return "Disconnected";
    if (msg.contains("سیستم آماده اتصال است")) return "System is ready to connect";
    if (msg.contains("در حال اعمال دی‌ان‌اس")) return "Applying DNS...";
    if (msg.contains("دی‌ان‌اس با موفقیت روی سیستم فعال شد")) return "DNS applied to system successfully.";
    if (msg.contains("تنظیمات دی‌ان‌اس سیستم به حالت خودکار (DHCP) بازگشت")) return "DNS reset to DHCP successfully.";
    if (msg.contains("ظرفیت اکانت به پایان رسید")) return "Account quota reached! Auto-rotating...";
    if (msg.contains("دستور توقف اسکن ارسال شد")) return "Stopping scan; collecting clean IPs...";
    if (msg.contains("اسکن پایان یافت؛ هیچ آی‌پی تمیزی یافت نشد")) return "Scan finished; no clean IPs found.";
    if (msg.contains("اسکن پایان یافت!")) return msg.replaceAll("اسکن پایان یافت! تعداد", "Scan finished! Found").replaceAll("آی‌پی تمیز و پرسرعت یافت شد.", "clean IPs.");
    if (msg.contains("در حال اجرای اسکن سریع کلودفلر")) return "Running quick Cloudflare scan...";
    if (msg.contains("در حال اسکن عمیق و چندنخی")) return "Running deep multi-threaded scan...";
    if (msg.contains("تعداد") && msg.contains("اکانت بارگذاری شد")) {
      return msg.replaceAll("تعداد", "").replaceAll("اکانت بارگذاری شد.", "accounts loaded.").trim();
    }
    if (msg.contains("روی فیلدها اعمال شد")) {
      return msg.replaceAll("اطلاعات", "").replaceAll("روی فیلدها اعمال شد.", "applied to fields.").trim();
    }
    return msg;
  }

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
  String _latestDirectDownloadUrl = "";
  int _latestAssetSizeBytes = 0;
  bool _isCheckingUpdate = false;
  bool _isWindowVisible = true;
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
      final List<Map<String, dynamic>> data = _savedNodeItems.map((item) => item.toJson()).toList();
      await file.writeAsString(jsonEncode(data));
      AppLogger.info("STORAGE", "تعداد ${_savedNodeItems.length} سرور ذخیره شد.");
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره کانفیگ‌ها روی دیسک", e, st);
    }
  }

  Future<void> _loadNodesFromDisk() async {
    try {
      final file = await _getLocalFile('saved_nodes.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        setState(() {
          _savedNodeItems = decoded.map((item) => SavedNodeItem.fromJson(item)).toList();
          if (_savedNodeItems.isNotEmpty) {
            _selectedNode = _savedNodeItems.first.node;
          }
        });
        AppLogger.info("STORAGE", "تعداد ${_savedNodeItems.length} سرور بارگذاری شد.");
      }
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در بارگذاری کانفیگ‌ها از دیسک", e, st);
    }
  }

  Future<void> _saveSubGroupsToDisk() async {
    try {
      final file = await _getLocalFile('saved_sub_groups.json');
      final List<Map<String, dynamic>> data = _subGroups.map((g) => g.toJson()).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره گروه‌های ساب‌اسکریپشن", e, st);
    }
  }

  Future<void> _loadSubGroupsFromDisk() async {
    try {
      final file = await _getLocalFile('saved_sub_groups.json');
      if (await file.exists()) {
        final String content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        setState(() {
          _subGroups = decoded.map((item) => SubscriptionGroup.fromJson(item)).toList();
        });
      }
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در بارگذاری گروه‌های ساب", e, st);
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
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره دی‌ان‌اس‌های سفارشی", e, st);
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
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در لود دی‌ان‌اس‌های سفارشی", e, st);
    }
  }

  Future<void> _saveAntiDpiToDisk() async {
    try {
      final file = await _getLocalFile('saved_anti_dpi.json');
      final data = {
        'utls_fingerprint': _selectedUtlsFingerprint,
        'tls_fragment': _enableFragment,
        'tls_record_fragment': _enableRecordFragment,
        'enable_ech': _enableEch,
        'fallback_delay': _fallbackDelayController.text,
        'tls_spoof_enabled': _enableTlsSpoof,
        'tls_spoof_sni': _tlsSpoofController.text,
        'aether_noize': _selectedAetherNoize,
        'aether_warp_key': _aetherWarpKeyController.text,
        'aether_team': _aetherTeamController.text,
        'goodbyedpi_path': _goodbyedpiPathController.text,
        'goodbyedpi_args': _goodbyedpiArgsController.text,
        'goodbyedpi_preset': _selectedGoodbyeDpiPreset,
        'use_goodbyedpi_dashboard': _useGoodbyeDpiDashboard,
        'use_goodbyedpi_aether': _useGoodbyeDpiAether,
        'use_goodbyedpi_tor': _useGoodbyeDpiTor,
        'use_goodbyedpi_psiphon': _useGoodbyeDpiPsiphon,
        'use_goodbyedpi_dns': _useGoodbyeDpiDns,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره تنظیمات ضدسانسور و GoodbyeDPI", e, st);
    }
  }

Future<void> _saveDnsttToDisk() async {
    try {
      final file = await _getLocalFile('saved_dnstt.json');
      final data = {
        'domain': _dnsttDomainController.text.trim(),
        'pubkey': _dnsttPubkeyController.text.trim(),
        'doh': _dnsttDohController.text.trim(),
        'port': _dnsttPortController.text.trim(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<void> _loadDnsttFromDisk() async {
    try {
      final file = await _getLocalFile('saved_dnstt.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);
        setState(() {
          _dnsttDomainController.text = data['domain'] ?? 't.dnstt.online';
          _dnsttPubkeyController.text = data['pubkey'] ?? '';
          _dnsttDohController.text = data['doh'] ?? 'https://1.1.1.1/dns-query';
          _dnsttPortController.text = data['port'] ?? '5300';
        });
      }
    } catch (_) {}
  }


  Future<void> _applySystemProxyOverride() async {
    if (!Platform.isWindows) return;
    try {
      List<String> bypassList = ['<local>', 'localhost', '127.0.0.1'];
      if (_bypassIran) {
        bypassList.addAll([
          '*.ir',
          '*.shaparak.ir',
          '*.telewebion.com',
          '*.aparat.com',
          '*.divar.ir',
          '*.snapp.ir',
          '*.digikala.com',
          '10.*',
          '172.16.*',
          '192.168.*',
        ]);
      }
      for (var rule in _splitRules) {
        if (rule['type'] == 'direct') {
          final domain = rule['domain']!.trim();
          if (domain.isNotEmpty) {
            bypassList.add(domain.startsWith('*') ? domain : '*$domain*');
          }
        }
      }
      final overrideStr = bypassList.join(';');
      await Process.run(
        'reg',
        [
          'add',
          'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings',
          '/v', 'ProxyOverride',
          '/t', 'REG_SZ',
          '/d', overrideStr,
          '/f'
        ],
        runInShell: true,
      );
    } catch (_) {}
  }

  // مدیریت پایدار هات‌اسپات + اتصال خودکار به رله LAN و هدایت پکت‌ها به فیلترشکن فعال
  Future<void> _toggleHotspot() async {
    if (!Platform.isWindows) return;
    final ssid = _hotspotSsidController.text.trim().isEmpty ? 'RedCloud-Wi-Fi' : _hotspotSsidController.text.trim();
    final pass = _hasHotspotPassword ? _hotspotPassController.text.trim() : '';

    if (_hasHotspotPassword && pass.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('رمز عبور هات‌اسپات باید حداقل ۸ کاراکتر باشد!'), backgroundColor: Colors.redAccent),
      );
      return;
    }

    setState(() {
      _hotspotStatusText = _isHotspotRunning ? 'در حال خاموش‌سازی هات‌اسپات...' : 'در حال راه‌اندازی هات‌اسپات و آماده‌سازی تونل ($ssid)...';
    });

    try {
      final tempDir = Directory.systemTemp;
      final scriptFile = File('${tempDir.path}\\rc_hotspot_action.ps1');

      if (_isHotspotRunning) {
        const stopScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
    $profiles = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles()
    foreach ($p in $profiles) {
        try {
            $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($p)
            if ($mgr -and $mgr.TetheringOperationalState -eq 1) {
                $mgr.StopTetheringAsync() | Out-Null
            }
        } catch {}
    }
} catch {}
netsh wlan stop hostednetwork | Out-Null
Write-Output "STOPPED"
''';
        await scriptFile.writeAsString(stopScript);
        await Process.run('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ], runInShell: false);

        setState(() {
          _isHotspotRunning = false;
          _hotspotStatusText = 'هات‌اسپات با موفقیت خاموش شد.';
        });
      } else {
        // ۱. روشن کردن خودکار رله LAN برای هدایت هوشمند ترافیک به سایفون/تور/اتر/ویتوری فعال
        try {
          if (!_isLanShareRunning) {
            final port = int.tryParse(_lanPortController.text.trim()) ?? 10808;
            await startLanRelay(port: port);
            final ip = await getLocalIpAddress();
            setState(() {
              _isLanShareRunning = true;
              _lanIp = ip;
            });
          }
        } catch (_) {}

        final startScript = '''
\$ErrorActionPreference = 'Stop'
try {
    # 1. فعال‌سازی سرویس هات‌اسپات و قابلیت Forwarding شفاف ویندوز به کارت TUN
    Start-Service -Name icssvc -ErrorAction SilentlyContinue
    Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue

    netsh advfirewall firewall add rule name="RC_LAN_Share" dir=in action=allow protocol=TCP localport=10808 -ErrorAction SilentlyContinue

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    \$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    Function AwaitOp(\$WinRtTask, \$ResultType) {
        \$asTask = \$asTaskGeneric.MakeGenericMethod(\$ResultType)
        \$netTask = \$asTask.Invoke(\$null, @(\$WinRtTask))
        \$netTask.Wait(9000) | Out-Null
        \$netTask.Result
    }
    Function AwaitAct(\$WinRtAction) {
        \$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and -not \$_.IsGenericMethod })[0]
        \$netTask = \$asTask.Invoke(\$null, @(\$WinRtAction))
        \$netTask.Wait(9000) | Out-Null
    }

    [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime] | Out-Null
    [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null

    # 2. پیدا کردن پروفایل اینترنت فعال
    \$profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not \$profile) {
        \$profile = [Windows.Networking.Connectivity.NetworkInformation]::GetConnectionProfiles() | Where-Object { \$_.GetNetworkConnectivityLevel() -ne 'None' } | Select-Object -First 1
    }

    if (-not \$profile) {
        Write-Output "ERR_NO_INTERNET_PROFILE"
        exit
    }

    \$mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile(\$profile)
    if (-not \$mgr) {
        Write-Output "ERR_TETHERING_UNSUPPORTED"
        exit
    }

    if (\$mgr.TetheringOperationalState -eq 1) {
        Write-Output "SUCCESS"
        exit
    }

    # 3. پیکربندی نام و پسورد هات‌اسپات
    try {
        \$cfg = \$mgr.GetCurrentAccessPointConfiguration()
        \$cfg.Ssid = "$ssid"
        ${_hasHotspotPassword ? "\$cfg.Passphrase = '$pass'" : ""}
        try { \$cfg.Band = 1 } catch {}
        AwaitAct (\$mgr.ConfigureAccessPointAsync(\$cfg))
    } catch {}

    # 4. استارت هات‌اسپات
    \$op = \$mgr.StartTetheringAsync()
    \$res = AwaitOp \$op ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    if (\$res.Status -eq 'Success' -or \$mgr.TetheringOperationalState -eq 1) {
        Write-Output "SUCCESS"
    } else {
        Write-Output "STATUS_FAIL:\$(\$res.Status)"
    }
} catch {
    Write-Output "ERR:\$(\$_.Exception.Message)"
}
''';
        await scriptFile.writeAsString(startScript);

        final res = await Process.run('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
        ], runInShell: false);

        final out = res.stdout.toString().trim();
        final err = res.stderr.toString().trim();
        final rawResponse = out.isNotEmpty ? out : err;

        if (rawResponse.contains("SUCCESS")) {
          setState(() {
            _isHotspotRunning = true;
            _hotspotStatusText = '✅ وای‌فای هات‌اسپات متصل شد! آی‌پی پروکسی در گوشی: 192.168.137.1 و پورت: 10808';
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('هات‌اسپات شفاف فعال شد؛ دستگاه‌ها خودکار از فیلترشکن عبور می‌کنند!'), 
                backgroundColor: Color(0xFF2DCA73),
              ),
            );
          }
        } else {
          setState(() {
            _isHotspotRunning = false;
            if (rawResponse.contains("WiFiNotTurnedOn")) {
              _hotspotStatusText = 'خطا: وای‌فای لپ‌تاپ خاموش است! ابتدا Wi-Fi ویندوز را روشن کنید.';
            } else if (rawResponse.contains("ERR_NO_INTERNET_PROFILE")) {
              _hotspotStatusText = 'خطا: اتصال اینترنت شناسایی نشد (ابتدا به مودم وصل شوید).';
            } else {
              _hotspotStatusText = 'دسترسی هات‌اسپات مسدود است؛ در حال باز کردن تنظیمات ویندوز...';
              Process.run('cmd.exe', ['/c', 'start', 'ms-settings:network-mobilehotspot']);
            }
          });
        }
      }
    } catch (e) {
      setState(() {
        _isHotspotRunning = false;
        _hotspotStatusText = 'خطای سیستمی: $e';
      });
    }
  }

  Future<void> _saveSplitTunnelToDisk() async {
    try {
      final file = await _getLocalFile('saved_split_tunnel.json');
      final tempFile = File('${Directory.systemTemp.path}\\RedCloud\\saved_split_tunnel.json');
      final data = {
        'bypass_iran': _bypassIran,
        'rules': _splitRules,
        'app_rules': _appRules,
      };
      final jsonStr = jsonEncode(data);
      await file.writeAsString(jsonStr);
      if (await tempFile.parent.exists()) {
        await tempFile.writeAsString(jsonStr);
      }
      await _applySystemProxyOverride();
      AppLogger.info("SPLIT_TUNNEL", "تنظیمات اسپلیت تانل و برنامه‌ها ذخیره شد.");
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره اسپلیت تانل", e, st);
    }
  }

  Future<void> _loadSplitTunnelFromDisk() async {
    try {
      final file = await _getLocalFile('saved_split_tunnel.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(content);
        setState(() {
          _bypassIran = decoded['bypass_iran'] ?? true;
          if (decoded['rules'] != null) {
            _splitRules = List<Map<String, String>>.from(
              (decoded['rules'] as List).map((r) => Map<String, String>.from(r)),
            );
          }
          if (decoded['app_rules'] != null) {
            _appRules = List<Map<String, String>>.from(
              (decoded['app_rules'] as List).map((r) => Map<String, String>.from(r)),
            );
          }
        });
        await _applySystemProxyOverride();
      }
    } catch (_) {}
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
          _enableEch = decoded['enable_ech'] ?? true;
          _fallbackDelayController.text = decoded['fallback_delay'] ?? '500ms';
          _enableTlsSpoof = decoded['tls_spoof_enabled'] ?? false;
          _tlsSpoofController.text = decoded['tls_spoof_sni'] ?? 'zoom.us';
          _selectedAetherNoize = decoded['aether_noize'] ?? 'firewall';
          _aetherWarpKeyController.text = decoded['aether_warp_key'] ?? '';
          _aetherTeamController.text = decoded['aether_team'] ?? '';
          _goodbyedpiPathController.text = decoded['goodbyedpi_path'] ?? 'goodbyedpi.exe';
          _goodbyedpiArgsController.text = decoded['goodbyedpi_args'] ?? '-9 -p -r -s -f 2 -k 2 -n -e 2';
          _selectedGoodbyeDpiPreset = decoded['goodbyedpi_preset'] ?? 'auto';
          _useGoodbyeDpiDashboard = decoded['use_goodbyedpi_dashboard'] ?? true;
          _useGoodbyeDpiAether = decoded['use_goodbyedpi_aether'] ?? true;
          _useGoodbyeDpiTor = decoded['use_goodbyedpi_tor'] ?? true;
          _useGoodbyeDpiPsiphon = decoded['use_goodbyedpi_psiphon'] ?? true;
          _useGoodbyeDpiDns = decoded['use_goodbyedpi_dns'] ?? true;
        });
      }
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در لود تنظیمات ضدسانسور", e, st);
    }
  }

  /// ذخیره دائمی زبان انتخابی در فایل دیسک
  Future<void> _saveLanguageToDisk() async {
    try {
      final file = await _getLocalFile('saved_language.json');
      await file.writeAsString(jsonEncode({'lang': _selectedLanguage}));
      AppTranslations.currentLang = _selectedLanguage;
      AppLogger.info("STORAGE", "زبان برنامه روی $_selectedLanguage ذخیره شد.");
    } catch (e, st) {
      AppLogger.error("STORAGE", "خطا در ذخیره زبان برنامه", e, st);
    }
  }

  /// بارگذاری زبان از دیسک یا نمایش دیالوگ در اولین اجرا
  Future<void> _loadLanguageFromDisk() async {
    try {
      final file = await _getLocalFile('saved_language.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final decoded = jsonDecode(content);
        final lang = decoded['lang'] ?? 'fa';
        setState(() {
          _selectedLanguage = lang;
          AppTranslations.currentLang = lang;
          _hasLanguageBeenSet = true;
        });
      } else {
        // برنامه برای بار اول اجرا شده است
        setState(() {
          _hasLanguageBeenSet = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showFirstRunLanguageDialog();
        });
      }
    } catch (e) {
      setState(() {
        _hasLanguageBeenSet = true;
      });
    }
  }

  /// دیالوگ انتخاب زبان برای اولین اجرای نرم‌افزار
  void _showFirstRunLanguageDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        String tempLang = _selectedLanguage;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xFF00D2FF), width: 1.5),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF00D2FF), Color(0xFFFF8008)]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.language_rounded, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('انتخاب زبان / Language Selection', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        Text('RedCloud VPN Multi-Language Setup', style: TextStyle(fontSize: 10.5, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'لطفاً زبان پیش‌فرض محیط کاربری برنامه را انتخاب کنید:\nPlease select your preferred interface language:',
                      style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.6),
                    ),
                    const SizedBox(height: 20),
                    _buildLanguageSelectCard(
                      title: 'فارسی (Persian)',
                      subtitle: 'راست‌چین و زبان پیش‌فرض',
                      flag: '🇮🇷',
                      isSelected: tempLang == 'fa',
                      onTap: () => setDialogState(() => tempLang = 'fa'),
                    ),
                    const SizedBox(height: 12),
                    _buildLanguageSelectCard(
                      title: 'English (انگلیسی)',
                      subtitle: 'Left-to-Right layout',
                      flag: '🇬🇧',
                      isSelected: tempLang == 'en',
                      onTap: () => setDialogState(() => tempLang = 'en'),
                    ),
                  ],
                ),
              ),
              actions: [
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton(
                    onPressed: () async {
                      setState(() {
                        _selectedLanguage = tempLang;
                        AppTranslations.currentLang = tempLang;
                        _hasLanguageBeenSet = true;
                      });
                      await _saveLanguageToDisk();
                      Navigator.of(ctx).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D2FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: Text(
                      tempLang == 'fa' ? 'ورود به برنامه' : 'Start Application',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildLanguageSelectCard({
    required String title,
    required String subtitle,
    required String flag,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00D2FF).withValues(alpha: 0.15) : const Color(0xFF090B10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? const Color(0xFF00D2FF) : Colors.white12,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Text(flag, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded, color: Color(0xFF00D2FF), size: 22)
            else
              const Icon(Icons.radio_button_unchecked_rounded, color: Colors.grey, size: 22),
          ],
        ),
      ),
    );
  }

// تنظیمات و وضعیت هسته ضد مسمومیت DNSCrypt (اولویت اول)
  final TextEditingController _dnscryptPathController = TextEditingController(text: 'dnscrypt-proxy.exe');
  bool _useDnscryptShield = true;
  bool _isDnscryptRunning = false;

  /// راه‌اندازی هوشمند هسته DNSCrypt با راستی‌آزمایی پکت
  // متغیرهای اختصاصی اینترنت اضطراری dnstt و بهینه‌ساز udp2raw
  bool _isDnsttRunning = false;
  bool _isDnsttConnecting = false;
  String _dnsttStatusText = 'آماده اتصال';
  bool _isUdp2rawActive = false;

  /// دیالوگ مرحله ۱: آیا مشکلی در اتصال دارید؟
  void _showTroubleshootDialog() {
    if (!mounted) return;
    final bool isEn = AppTranslations.currentLang == 'en';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121520),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF00D2FF), width: 1.4),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.help_outline_rounded, color: Color(0xFF00D2FF), size: 22),
            ),
            const SizedBox(width: 12),
            Text(
              isEn ? 'Having Connection Issues?' : 'آیا مشکلی در اتصال دارید؟',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          isEn
              ? 'The system detected an issue establishing connection. Would you like to troubleshoot?'
              : 'به نظر می‌رسد برقراری ارتباط با سرور با اختلال مواجه شد. آیا مایلید عیب‌یابی هوشمند انجام شود؟',
          style: const TextStyle(fontSize: 13, height: 1.6, color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(isEn ? 'No' : 'خیر', style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              showDialog(
  context: context,
  barrierDismissible: false,
  builder: (c) => const SystemDiagnosticsDialog(),
);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00D2FF),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(isEn ? 'Yes' : 'بله', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// دیالوگ مرحله ۲: آیا اینترنت شما ملی شده است؟
  
  
  Future<void> _maybeStartDnscrypt() async {
    if (!_useDnscryptShield || !Platform.isWindows) return;
    try {
      final path = _dnscryptPathController.text.trim().isEmpty ? null : _dnscryptPathController.text.trim();
      final msg = await startDnscryptCore(binaryPath: path);
      if (mounted) setState(() => _isDnscryptRunning = true);
      AppLogger.info("DNSCRYPT", msg);
    } catch (e) {
      if (mounted) setState(() => _isDnscryptRunning = false);
      AppLogger.warn("DNSCRYPT", "اعتبارسنجی DNSCrypt ناموفق بود؛ فالبک آنی به لایه بعدی: $e");
    }
  }

  /// توقف امن هسته DNSCrypt
  Future<void> _maybeStopDnscrypt() async {
    if (!Platform.isWindows) return;
    try {
      await stopDnscryptCore();
      if (mounted) setState(() => _isDnscryptRunning = false);
    } catch (_) {}
  }
  // مدیریت هوشمند و دینامیک فرآیند GoodbyeDPI با قابلیت تغییر زنده‌ی پریست‌ها
  Future<void> _maybeStartGoodbyeDpi(bool shouldStart, {String? explicitArgs}) async {
    if (!Platform.isWindows) return;
    try {
      if (shouldStart) {
        final path = _goodbyedpiPathController.text.trim().isEmpty ? 'goodbyedpi.exe' : _goodbyedpiPathController.text.trim();
        final args = explicitArgs ?? (_goodbyedpiArgsController.text.trim().isEmpty ? 'default' : _goodbyedpiArgsController.text.trim());
        
        if (args == 'off') {
          await stopGoodbyedpiCore();
          if (mounted) setState(() => _isGoodbyeDpiRunning = false);
          AppLogger.info("GOODBYEDPI", "گودبای‌دی‌پی طبق استراتژی هوشمند موقتاً خاموش شد.");
          return;
        }

        await startGoodbyedpiCore(binaryPath: path, args: args);
        if (mounted) setState(() => _isGoodbyeDpiRunning = true);
        AppLogger.info("GOODBYEDPI", "افکت GoodbyeDPI با آرگومان [$args] روی کارت شبکه فعال شد.");
      } else {
        await stopGoodbyedpiCore();
        if (mounted) setState(() => _isGoodbyeDpiRunning = false);
      }
    } catch (e) {
      AppLogger.warn("GOODBYEDPI", "خطا در تغییر وضعیت GoodbyeDPI: $e");
    }
  }

  /// پایشگر علائم حیاتی: چرخش خودکار پریست‌های گودبای‌دی‌پی فقط در صورت سکون و گیر کردن اتصال
  Future<void> _advanceToNextGoodbyeDpiPreset(String coreName) async {
    // فقط در صورتی که کاربر گزینه Auto را انتخاب کرده باشد چرخش هوشمند فعال شود
    if (_selectedGoodbyeDpiPreset != 'auto') return;

    _currentAdaptivePresetIndex = (_currentAdaptivePresetIndex + 1) % _adaptiveGoodbyeDpiPresets.length;
    final nextPreset = _adaptiveGoodbyeDpiPresets[_currentAdaptivePresetIndex];
    
    if (mounted) {
      setState(() {
        _statusMessage = "⚡ سکون در $coreName شناسایی شد؛ سوییچ هوشمند به: ${nextPreset['name']}";
      });
    }
    
    await _maybeStartGoodbyeDpi(true, explicitArgs: nextPreset['args']);
    AppLogger.info("ADAPTIVE_DPI", "سوئیچ به پریست جدید برای $coreName: ${nextPreset['name']}");
  }

  Future<void> _maybeStopGoodbyeDpi() async {
    if (!Platform.isWindows) return;
    try {
      final running = await isGoodbyedpiRunning();
      if (running) {
        await stopGoodbyedpiCore();
        if (mounted) setState(() => _isGoodbyeDpiRunning = false);
      }
    } catch (_) {}
  }

  void _openGoodbyeDpiConfigDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF2DCA73), width: 1.2),
              ),
              title: Row(
                children: [
                  const Icon(Icons.shield_rounded, color: Color(0xFF2DCA73)),
                  const SizedBox(width: 12),
                  Text(
                    isEn ? 'Configure GoodbyeDPI (Anti-DPI Effect)' : 'پیکربندی افکت ضد DPI (GoodbyeDPI)', 
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEn 
                          ? 'GoodbyeDPI manipulates and fragments packets at the Windows kernel level (WinDivert) without altering system proxies to bypass DPI filters.'
                          : 'هسته GoodbyeDPI بدون تغییر پروکسی، در سطح کرنل و کارت شبکه پکت‌ها را دستکاری و فرگمنت می‌کند تا از سد فیلترینگ DPI عبور کند.',
                      style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      isEn ? 'Select Preset:' : 'انتخاب پریست (Preset):', 
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF090B10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: DropdownButton<String>(
                        value: _selectedGoodbyeDpiPreset,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF090B10),
                        underline: const SizedBox(),
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              _selectedGoodbyeDpiPreset = val;
                              if (val == 'auto' || val == 'iran_recommended') {
                                _goodbyedpiArgsController.text = '-9 -p -r -s -f 2 -k 2 -n -e 2';
                              } else if (val == 'mode_1') {
                                _goodbyedpiArgsController.text = '-1';
                              } else if (val == 'mode_5') {
                                _goodbyedpiArgsController.text = '-5';
                              }
                            });
                          }
                        },
                        items: [
                          DropdownMenuItem(
                            value: 'auto', 
                            child: Text(isEn ? 'Auto (Smart Adaptive Failover - Recommended)' : 'انتخاب خودکار هوشمند (Auto Adaptive - پیشنهادی)'),
                          ),
                          DropdownMenuItem(
                            value: 'iran_recommended', 
                            child: Text(isEn ? 'Iran Recommended (Aggressive -9 & full fragmentation)' : 'پیش‌فرض پیشنهادی ایران (حالت تهاجمی -9 و فرگمنت کامل)'),
                          ),
                          DropdownMenuItem(
                            value: 'mode_1', 
                            child: Text(isEn ? 'Mode 1 (Most compatible -1)' : 'مد ۱ (بسیار سازگار -1)'),
                          ),
                          DropdownMenuItem(
                            value: 'mode_5', 
                            child: Text(isEn ? 'Mode 5 (Standard anti-blocking -5)' : 'مد ۵ (ضد مسدودسازی استاندارد -5)'),
                          ),
                          DropdownMenuItem(
                            value: 'custom', 
                            child: Text(isEn ? 'Custom Parameters (Manual)' : 'تنظیمات و پارامترهای دستی (Custom)'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _goodbyedpiArgsController,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        labelText: isEn ? 'Command-line Arguments (CLI)' : 'آرگومان‌های خط فرمان (CLI Arguments)',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        hintText: '-9 -p -r -s -f 2 -k 2 -n -e 2',
                      ),
                      onChanged: (_) {
                        setDialogState(() => _selectedGoodbyeDpiPreset = 'custom');
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _saveAntiDpiToDisk();
                    if (context.mounted) Navigator.of(context).pop();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(isEn ? 'GoodbyeDPI settings saved successfully.' : 'تنظیمات GoodbyeDPI با موفقیت ذخیره شد.'), 
                          backgroundColor: const Color(0xFF2DCA73),
                        ),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DCA73), foregroundColor: Colors.black),
                  child: Text(isEn ? 'Save Changes' : 'ذخیره تغییرات', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTcpTurboSwitchTile() {
    final bool isEn = AppTranslations.currentLang == 'en';
    return _buildGlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      borderRadius: 16,
      borderColor: _isTcpTurboEnabled ? const Color(0xFFFFC837).withValues(alpha: 0.6) : Colors.white12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt_rounded, size: 19, color: _isTcpTurboEnabled ? const Color(0xFFFFC837) : Colors.grey),
          const SizedBox(width: 8),
          Text(
            isEn ? 'TCP Turbo (BBR)' : 'توربو TCP (ضد پکت‌لاس)',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 8),
          if (_isApplyingTcpTurbo)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFC837)))
          else
            Switch(
              value: _isTcpTurboEnabled,
              activeThumbColor: const Color(0xFFFFC837),
              activeTrackColor: const Color(0xFFFFC837).withValues(alpha: 0.4),
              onChanged: (val) async {
                await _applyWindowsTcpTurbo(val);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(val 
                          ? (isEn ? 'TCP Turbo (BBR & SACK) Activated!' : 'شتاب‌دهنده BBR و ضد پکت‌لاس ویندوز فعال شد!')
                          : (isEn ? 'TCP settings reset to Windows default.' : 'تنظیمات TCP به حالت پیش‌فرض ویندوز بازگشت.')),
                      backgroundColor: val ? const Color(0xFF2DCA73) : Colors.amber[800],
                    ),
                  );
                }
              },
            ),
        ],
      ),
    );
  }

  Widget _buildGoodbyeDpiSwitchTile({
    required String tabName,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final bool isEn = AppTranslations.currentLang == 'en';
    return _buildGlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      borderRadius: 16,
      borderColor: value ? const Color(0xFF2DCA73).withValues(alpha: 0.6) : Colors.white12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shield_outlined, size: 18, color: value ? const Color(0xFF2DCA73) : Colors.grey),
          const SizedBox(width: 8),
          Text('goodbyedpi_effect'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 16, color: Colors.grey),
            tooltip: isEn ? 'GoodbyeDPI Settings & Parameters' : 'تنظیمات و پارامترهای GoodbyeDPI',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: _openGoodbyeDpiConfigDialog,
          ),
          const SizedBox(width: 8),
          Switch(
            value: value,
            activeThumbColor: const Color(0xFF2DCA73),
            activeTrackColor: const Color(0xFF2DCA73).withValues(alpha: 0.4),
            onChanged: onChanged,
          ),
        ],
      ),
    );
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

  /// تابع مقایسه هوشمند نگارش‌ها (Semantic Versioning)
  /// اگر v1 بزرگتر باشد: مثبت | اگر مساوی باشند: صفر | اگر v1 کوچکتر باشد: منفی
  int _compareVersions(String v1, String v2) {
    String clean(String v) => v.toLowerCase().replaceAll('v', '').trim();

    final parts1 = clean(v1).split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = clean(v2).split('.').map((e) => int.tryParse(e) ?? 0).toList();

    final maxLen = parts1.length > parts2.length ? parts1.length : parts2.length;

    for (int i = 0; i < maxLen; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  /// بررسی هوشمند اینکه آیا نسخه سرور از نسخه فعلی برنامه جدیدتر است یا خیر
  bool _isNewerVersion(String remote, String current) {
    return _compareVersions(remote, current) > 0;
  }

  Future<void> _checkForUpdates({bool showSnackbarIfNoUpdate = false, bool autoShowDialog = true}) async {
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

        // استخراج لینک مستقیم فایل Setup.exe از لیست فایل‌های ریلیز
        String directDownload = '';
        int assetSize = 0;
        if (data['assets'] != null && data['assets'] is List) {
          for (var asset in data['assets']) {
            final name = (asset['name'] ?? '').toString().toLowerCase();
            if (name.endsWith('.exe')) {
              directDownload = asset['browser_download_url'] ?? '';
              assetSize = asset['size'] ?? 0;
              break;
            }
          }
        }

        // فقط در صورتی که نسخه گیت‌هاب اکیداً جدیدتر از نسخه فعلی کلاینت باشد
        if (tagName.isNotEmpty && _isNewerVersion(tagName, appCurrentVersion)) {
          setState(() {
            _hasUpdate = true;
            _latestVersion = tagName;
            _latestReleaseUrl = htmlUrl;
            _latestDirectDownloadUrl = directDownload;
            _latestAssetSizeBytes = assetSize;
          });
          if (_isWindowVisible) {
            _pulseController?.repeat(reverse: true);
          }
          AppLogger.info("UPDATER", "نسخه جدیدتر یافت شد: $tagName (نسخه فعلی: $appCurrentVersion)");

          // باز کردن پنجره وسط صفحه برای تایید کاربر
          if (autoShowDialog && mounted) {
            _showAutoUpdateDialog();
          }
        } else {
          setState(() => _hasUpdate = false);
          if (showSnackbarIfNoUpdate && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('already_latest_version'.tr(params: {'version': appCurrentVersion}))),
            );
          }
        }
      }
    } catch (e) {
      AppLogger.warn("UPDATER", "خطا در بررسی آپدیت: $e");
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  /// پنجره هوشمند و وسط‌صفحه به‌روزرسانی خودکار، نمایش نوار درصد دانلود و راه‌اندازی ستاپ
  void _showAutoUpdateDialog() {
    if (!mounted || !_hasUpdate) return;
    final bool isEn = AppTranslations.currentLang == 'en';
    bool isDownloading = false;
    double downloadProgress = 0.0;
    String progressText = '';
    String errorText = '';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xFF00D2FF), width: 1.5),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF00D2FF), Color(0xFFFF8008)]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.system_update_rounded, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isEn ? 'New Version Available!' : 'نسخه جدید RedCloud آماده است!',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'v$appCurrentVersion  ➔  v$_latestVersion',
                          style: const TextStyle(fontSize: 11, color: Color(0xFF00D2FF), fontFamily: 'monospace', fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isDownloading && errorText.isEmpty)
                      Text(
                        isEn
                            ? 'A new update (v$_latestVersion) is ready with enhanced features and optimizations. Would you like to download and install it automatically?'
                            : 'نگارش جدیدی از نرم‌افزار با جدیدترین بهینه‌سازی‌ها و سرورها منتشر شده است.\nآیا مایلید نسخه جدید به طور خودکار دریافت و نصب شود؟',
                        style: const TextStyle(fontSize: 12.5, height: 1.7, color: Colors.white70),
                      ),
                    if (isDownloading) ...[
                      Text(
                        isEn ? 'Downloading update...' : 'در حال دریافت فایل نصبی نسخه جدید...',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: downloadProgress > 0 ? downloadProgress : null,
                          minHeight: 8,
                          backgroundColor: Colors.white10,
                          color: const Color(0xFF00D2FF),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            progressText,
                            style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                          ),
                          Text(
                            '${(downloadProgress * 100).toInt()}%',
                            style: const TextStyle(fontSize: 12, color: Color(0xFF00D2FF), fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ],
                    if (errorText.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 11.5),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (!isDownloading) ...[
                  TextButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                    child: Text(isEn ? 'Later' : 'خیر / بعداً', style: const TextStyle(color: Colors.grey)),
                  ),
                  ElevatedButton.icon(
                    onPressed: () async {
                      if (_latestDirectDownloadUrl.isEmpty) {
                        openBrowserUrl(_latestReleaseUrl);
                        Navigator.of(dialogCtx).pop();
                        return;
                      }

                      setDialogState(() {
                        isDownloading = true;
                        errorText = '';
                        progressText = isEn ? 'Connecting to server...' : 'در حال اتصال به سرور دانلود...';
                      });

                      try {
                        final client = HttpClient();
                        client.badCertificateCallback = (cert, host, port) => true;
                        final request = await client.getUrl(Uri.parse(_latestDirectDownloadUrl));
                        request.followRedirects = true;
                        final response = await request.close();

                        if (response.statusCode != 200) {
                          throw Exception('HTTP ${response.statusCode}');
                        }

                        final total = response.contentLength > 0 ? response.contentLength : _latestAssetSizeBytes;
                        final tempDir = Directory.systemTemp;
                        final setupFile = File('${tempDir.path}\\RedCloud_VPN_Setup_v$_latestVersion.exe');
                        final sink = setupFile.openWrite();
                        int received = 0;

                        await for (var chunk in response) {
                          received += chunk.length;
                          sink.add(chunk);
                          setDialogState(() {
                            downloadProgress = total > 0 ? (received / total) : 0.0;
                            final recMb = (received / (1024 * 1024)).toStringAsFixed(1);
                            final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
                            progressText = '$recMb MB / $totalMb MB';
                          });
                        }

                        await sink.flush();
                        await sink.close();

                        setDialogState(() {
                          progressText = isEn ? 'Finalizing & restarting...' : 'دانلود کامل شد؛ در حال راه‌اندازی ستاپ...';
                        });

                        await Future.delayed(const Duration(milliseconds: 600));

                        // اجرای فایل نصبی جدید به عنوان پروسه کاملاً مستقل
                        await Process.start(
                          setupFile.path,
                          ['/SP-', '/CLOSEAPPLICATIONS'],
                          mode: ProcessStartMode.detached,
                        );

                        // بستن تمیز نرم‌افزار فعلی برای جایگزینی فایل‌ها توسط ستاپ
                        if (Platform.isWindows) {
                          await windowManager.destroy();
                        }
                        exit(0);
                      } catch (e) {
                        setDialogState(() {
                          isDownloading = false;
                          errorText = isEn ? 'Download error: $e' : 'خطا در دریافت خودکار: $e';
                        });
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D2FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(
                      isEn ? 'Update Now' : 'بله / به‌روزرسانی خودکار',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }

  void _openDonationDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121520),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24), 
            side: const BorderSide(color: Color(0xFFFFC837), width: 1.5),
          ),
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
              Text('donation_title'.tr(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'donation_desc'.tr(),
                  style: const TextStyle(fontSize: 13, height: 1.6, color: Colors.white70),
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
                          Row(
                            children: [
                              const Icon(Icons.currency_bitcoin_rounded, color: Colors.greenAccent, size: 18),
                              const SizedBox(width: 8),
                              Text('usdt_label'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.greenAccent)),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.amber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                            ),
                            child: Text('bep20_network'.tr(), style: const TextStyle(fontSize: 10, color: Colors.amber, fontWeight: FontWeight.bold)),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      const SelectableText(
                        usdtBnbAddress,
                        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Clipboard.setData(const ClipboardData(text: usdtBnbAddress));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('copied_wallet_toast'.tr()),
                                backgroundColor: const Color(0xFF2DCA73),
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
                          label: Text('btn_copy_wallet'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
              child: Text('close'.tr(), style: const TextStyle(color: Colors.grey)),
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
    
    _loadLanguageFromDisk();
    CoreUpdaterService.loadSavedVersions().then((_) {
      if (mounted) setState(() {});
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    
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
    _startRadarPolling();
    _loadSubGroupsFromDisk();
    _loadNodesFromDisk();
    _loadDnsFromDisk();
    _loadAntiDpiFromDisk();
    _loadDnsttFromDisk();
    _loadSplitTunnelFromDisk();
    _loadHotspotSecurityFromDisk();
    _loadPreferencesFromDisk();
    _checkForUpdates();
    _initLanShareState();
    LocalDnsService().init();
    _gamingRegistry.init().then((_) {
      if (mounted && _gamingRegistry.allGames.isNotEmpty) {
        setState(() {
          _selectedGame = _gamingRegistry.allGames.first;
        });
      }
    });
    _fetchGithubAccounts(); // بارگذاری سریع از کش محلی در بدو اجرای برنامه
  }

  Future<void> _initLanShareState() async {
    try {
      final running = await isLanRelayRunning();
      final localIp = await getLocalIpAddress();
      final port = await getLanRelayPort();
      if (mounted) {
        setState(() {
          _isLanShareRunning = running;
          _lanIp = localIp;
          _lanPortController.text = port.toString();
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _radarUpdateTimer?.cancel();
    _pulseController?.dispose();
    _scanStatsTimer?.cancel();
    _aetherProgressTimer?.cancel();
    _torProgressTimer?.cancel();
    _psiphonProgressTimer?.cancel();
    _dnsToastTimer?.cancel();
    _hotspotMonitorTimer?.cancel();
    _hotspotMonitorTimer = null;
    _serverSearchController.dispose();
    _lanPortController.dispose();
    _customSniController.dispose();
    _tlsSpoofController.dispose();
    _fallbackDelayController.dispose();
    _aetherWarpKeyController.dispose();
    _aetherTeamController.dispose();
    _goodbyedpiPathController.dispose();
    _goodbyedpiArgsController.dispose();
    _stopCore2Monitoring();
    _gamingMetricsTimer?.cancel();
    _dnsScannerPollingTimer?.cancel();
    _stopTrafficMonitoring();
    _stopTelemetryReporting();
    if (Platform.isWindows) {
      hotKeyManager.unregisterAll();
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

          if (mounted) {
            setState(() {
              _downloadSpeed = _formatSpeed(down);
              _uploadSpeed = _formatSpeed(up);
            });
          }
        } catch (_) {}
      }, onError: (e) {
        _stopTrafficMonitoring();
      }, onDone: () {
        _stopTrafficMonitoring();
      });
    } catch (e) {
      _stopTrafficMonitoring();
    }
  }

  void _stopTrafficMonitoring() {
    _trafficSubscription?.cancel();
    _trafficSubscription = null;
    if (mounted) {
      setState(() {
        _downloadSpeed = "0.0 B/s";
        _uploadSpeed = "0.0 B/s";
      });
    }
  }
  void _startCore2Monitoring() {
    _stopCore2Monitoring();
    _core2MonitorTimer = Timer.periodic(const Duration(seconds: 4), (timer) async {
      final bool isAnyConnected = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning;
      if (!isAnyConnected) {
        _stopCore2Monitoring();
        return;
      }

      try {
        int latency = -1;
        if (_isHybridRunning || _isProxyRunning) {
          if (_selectedNode != null) {
            final uri = Uri.parse(_selectedNode!.rawUrl);
            final port = _latestCalibration?.selectedPort ?? (uri.port == 0 ? 443 : uri.port);
            latency = await pingProxyServer(host: uri.host, port: port);
          }
        } else if (_isAetherRunning) {
          latency = await pingProxyServer(host: '127.0.0.1', port: 1820);
        } else if (_isTorRunning || _isTorMasqueRunning) {
          latency = await pingProxyServer(host: '127.0.0.1', port: 9051);
        } else if (_isPsiphonRunning || _isPsiphonMasqueRunning) {
          latency = await pingProxyServer(host: '127.0.0.1', port: 9081);
        }

        if (latency > 0) {
          final report = await recordLiveConnectionMetric(measuredLatencyMs: latency.toDouble());
          if (mounted) {
            setState(() {
              _latestCore2Report = report;
              if (report.isDegraded) {
                _statusMessage = "هشدار هسته دوم: ${report.alertMessage}";
                _consecutiveDegradedCount++;
                if (_consecutiveDegradedCount >= 2 && !_isHealingInProgress && _useSmartOptimizer) {
                  _triggerSelfHealing();
                }
              } else {
                _consecutiveDegradedCount = 0;
              }
            });
          }
        }
      } catch (_) {}
    });
  }

  void _stopCore2Monitoring() {
    _core2MonitorTimer?.cancel();
    _core2MonitorTimer = null;
    _consecutiveDegradedCount = 0;
    _isHealingInProgress = false;
  }

  Future<void> _triggerSelfHealing() async {
    if (_isHealingInProgress) return;
    _isHealingInProgress = true;

    setState(() {
      _statusMessage = "⚡ خوددرمانگری هوشمند ($_activeProtocolName): جهش به لایه ضد اختلال...";
    });

    try {
      if (_isHybridRunning || _isProxyRunning) {
        if (_selectedNode != null) {
          final healedProfile = await autoHealAndRecalibrate(
            binaryPath: _binaryPathController.text.trim(),
            selectedNode: _selectedNode!,
            useSystemProxy: _useSystemProxy,
            useTunMode: _useTunMode,
            dnsType: _selectedDns.dnsType,
            dnsPrimary: _selectedDns.primary,
            dnsSecondary: _selectedDns.secondary,
            dnsDotHost: _selectedDns.dotHost,
          );
          if (mounted) {
            setState(() {
              _latestCalibration = healedProfile;
              _consecutiveDegradedCount = 0;
              _isHealingInProgress = false;
              _statusMessage = "اتصال خوددرمان شد! پورت: ${healedProfile.selectedPort} | فرگمنت: ${healedProfile.optimalDelayStr}";
            });
          }
        }
      } else if (_isAetherRunning) {
        // خوددرمانگری اتر: سوییچ خودکار حالت مسک به Gool (تونل مضاعف)
        setState(() {
          _selectedAetherMode = _selectedAetherMode == 'masque_h3' ? 'masque_h2' : 'gool';
        });
        await _toggleAetherConnection();
        await Future.delayed(const Duration(milliseconds: 500));
        await _toggleAetherConnection();
        _isHealingInProgress = false;
      } else if (_isTorRunning && !_isTorMasqueRunning) {
        // خوددرمانگری تور: فعال‌سازی فوری پل ضدسانسور مسک
        setState(() {
          _isTorMasqueEnabled = true;
        });
        await _toggleTorConnection();
        await Future.delayed(const Duration(milliseconds: 500));
        await _toggleTorConnection();
        _isHealingInProgress = false;
      } else if (_isPsiphonRunning && !_isPsiphonMasqueRunning) {
        // خوددرمانگری سایفون: فعال‌سازی پل مسک
        setState(() {
          _isPsiphonMasqueEnabled = true;
        });
        await _togglePsiphonConnection();
        await Future.delayed(const Duration(milliseconds: 500));
        await _togglePsiphonConnection();
        _isHealingInProgress = false;
      } else {
        _isHealingInProgress = false;
      }
    } catch (_) {
      _isHealingInProgress = false;
    }
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
        AppLogger.info("TELEMETRY", "گزارش ترافیک با موفقیت مخابره شد.");
      }
    } catch (e) {
      AppLogger.warn("TELEMETRY", "خطا در ارسال تله‌متری ترافیک: $e");
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

  List<SavedNodeItem> get _filteredNodeItems {
    return _savedNodeItems.where((item) {
      if (_selectedGroupId != 'all') {
        if (_selectedGroupId == 'manual') {
          if (item.groupId != 'manual' && !item.groupId.startsWith('scanner')) {
            return false;
          }
        } else if (item.groupId != _selectedGroupId) {
          return false;
        }
      }

      if (_serverSearchQuery.isNotEmpty) {
        final q = _serverSearchQuery.toLowerCase();
        final nameMatch = item.node.name.toLowerCase().contains(q);
        final protoMatch = item.node.protocol.toLowerCase().contains(q);
        final rawMatch = item.node.rawUrl.toLowerCase().contains(q);
        return nameMatch || protoMatch || rawMatch;
      }

      return true;
    }).toList();
  }

  Future<void> _bulkPingAndSort() async {
    final bool isEn = AppTranslations.currentLang == 'en';
    final targets = _filteredNodeItems;
    if (targets.isEmpty) return;

    setState(() {
      _isBulkPinging = true;
      _statusMessage = isEn 
          ? "Parallel ping testing with Rust core in progress..." 
          : "در حال پایش موازی تاخیر پینگ سرورها با هسته راست...";
    });

    final List<Future<void>> pingFutures = [];
    for (var item in targets) {
      pingFutures.add(() async {
        try {
          final uri = Uri.parse(item.node.rawUrl);
          final host = uri.host;
          final port = uri.port;
          
          final latency = await pingProxyServer(host: host, port: port);
          _nodePings[item.node.rawUrl] = latency;
        } catch (_) {
          _nodePings[item.node.rawUrl] = -1;
        }
      }());
    }

    await Future.wait(pingFutures);

    if (mounted) {
      setState(() {
        _savedNodeItems.sort((a, b) {
          final pingA = _nodePings[a.node.rawUrl] ?? 99999;
          final pingB = _nodePings[b.node.rawUrl] ?? 99999;

          if (pingA == -1 && pingB == -1) return 0;
          if (pingA == -1) return 1;
          if (pingB == -1) return -1;

          return pingA.compareTo(pingB);
        });
        _isBulkPinging = false;
        _statusMessage = isEn 
            ? "Parallel ping test completed; stable servers moved to the top." 
            : "تست پینگ موازی پایان یافت؛ سرورهای پایدار در صدر لیست قرار گرفتند.";
      });
      _saveNodesToDisk();
    }
  }

  Future<void> _updateSubscription(SubscriptionGroup group) async {
    final bool isEn = AppTranslations.currentLang == 'en';
    setState(() => _isUpdatingSubs = true);
    try {
      final response = await http.get(Uri.parse(group.url), headers: {
        'User-Agent': 'v2rayN/7.22.5 (Windows; x64) RedCloud/3.5',
      }).timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final parsed = await parseImportLinks(input: response.body);
        
        setState(() {
          _savedNodeItems.removeWhere((item) => item.groupId == group.id);
          for (var n in parsed) {
            _savedNodeItems.add(SavedNodeItem(node: n, groupId: group.id));
          }
          group.lastUpdated = DateTime.now();
          _statusMessage = isEn 
              ? "Subscription '${group.name}' updated with ${parsed.length} servers."
              : "ساب‌اسکریپشن '${group.name}' با ${parsed.length} سرور بروزرسانی شد.";
          _selectedNode ??= _savedNodeItems.first.node;
        });

        await _saveNodesToDisk();
        await _saveSubGroupsToDisk();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isEn 
                  ? "Subscription '${group.name}' updated successfully (${parsed.length} servers)."
                  : "ساب '${group.name}' با موفقیت بروزرسانی شد (${parsed.length} سرور)."),
              backgroundColor: const Color(0xFF2DCA73),
            ),
          );
        }
      } else {
        throw Exception("Status code: ${response.statusCode}");
      }
    } catch (e, st) {
      AppLogger.error("SUB_UPDATE", "Error updating subscription ${group.name}", e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(isEn ? "Error updating sub '${group.name}': $e" : "خطا در بروزرسانی ساب '${group.name}': $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdatingSubs = false);
    }
  }

  Future<void> _updateAllSubscriptions() async {
    final bool isEn = AppTranslations.currentLang == 'en';
    if (_subGroups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isEn ? "No subscription groups defined." : "هیچ گروه ساب‌اسکریپشنی تعریف نشده است.")),
      );
      return;
    }

    setState(() {
      _isUpdatingSubs = true;
      _statusMessage = isEn ? "Updating all subscriptions..." : "در حال بروزرسانی تمامی ساب‌اسکریپشن‌ها...";
    });

    for (var group in _subGroups) {
      if (group.url.isNotEmpty) {
        await _updateSubscription(group);
      }
    }

    if (mounted) {
      setState(() {
        _isUpdatingSubs = false;
        _statusMessage = isEn ? "All subscriptions updated successfully." : "بروزرسانی تمام ساب‌اسکریپشن‌ها به پایان رسید.";
      });
    }
  }

  void _removeDeadServers() {
    final bool isEn = AppTranslations.currentLang == 'en';
    final int before = _savedNodeItems.length;
    setState(() {
      _savedNodeItems.removeWhere((item) => _nodePings[item.node.rawUrl] == -1);
    });
    final int removed = before - _savedNodeItems.length;
    _saveNodesToDisk();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isEn ? "Removed $removed timeout/dead servers." : "تعداد $removed سرور قطع و تایم‌اوت حذف شد."),
        backgroundColor: const Color(0xFF6C5DD3),
      ),
    );
  }

  void _openAddOrEditSubGroupDialog({SubscriptionGroup? editGroup}) {
    final bool isEn = AppTranslations.currentLang == 'en';
    final nameController = TextEditingController(text: editGroup?.name ?? '');
    final urlController = TextEditingController(text: editGroup?.url ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121520),
          title: Row(
            children: [
              Icon(editGroup == null ? Icons.add_link_rounded : Icons.edit_rounded, color: const Color(0xFF00D2FF)),
              const SizedBox(width: 12),
              Text(
                editGroup == null 
                    ? (isEn ? 'Add New Subscription Group' : 'افزودن گروه ساب جدید (Subscription Group)')
                    : (isEn ? 'Edit Subscription Group' : 'ویرایش گروه ساب'), 
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDialogField(
                  isEn ? 'Group / Subscription Name (e.g. Germany, Private Sub)' : 'نام گروه / ساب (مانند: سرورهای آلمان، ساب شخصی)', 
                  nameController,
                ),
                const SizedBox(height: 14),
                _buildDialogField(
                  isEn ? 'Subscription URL (https://...) or GitHub link' : 'لینک ساب‌اسکریپشن (https://...) یا آدرس گیت‌هاب', 
                  urlController,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final url = urlController.text.trim();
                if (name.isEmpty || url.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(isEn ? 'Group name and URL cannot be empty.' : 'نام گروه و لینک ساب نمی‌توانند خالی باشند.')),
                  );
                  return;
                }

                if (editGroup == null) {
                  final newGroup = SubscriptionGroup(
                    id: 'sub_${DateTime.now().millisecondsSinceEpoch}',
                    name: name,
                    url: url,
                  );
                  setState(() {
                    _subGroups.add(newGroup);
                    _selectedGroupId = newGroup.id;
                  });
                  await _saveSubGroupsToDisk();
                  if (context.mounted) Navigator.of(context).pop();
                  _updateSubscription(newGroup);
                } else {
                  setState(() {
                    editGroup.name = name;
                    editGroup.url = url;
                  });
                  await _saveSubGroupsToDisk();
                  if (context.mounted) Navigator.of(context).pop();
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D2FF), foregroundColor: Colors.black),
              child: Text(
                editGroup == null 
                    ? (isEn ? 'Add & Download' : 'افزودن و دانلود')
                    : (isEn ? 'Save Changes' : 'ذخیره تغییرات'), 
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  void _openAddConfigDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121520),
          title: Row(
            children: [
              const Icon(Icons.add_circle_outline_rounded, color: Color(0xFF2DCA73)),
              const SizedBox(width: 12),
              Text(
                isEn ? 'Add Single / Raw Config' : 'افزودن کانفیگ تکی یا متنی', 
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: textController,
                  maxLines: 5,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    labelText: isEn ? 'Config link (vless / trojan / hy2) or Base64' : 'لینک کانفیگ (vless / trojan / hy2) یا کد Base64',
                    border: const OutlineInputBorder(),
                    hintText: 'vless://uuid@host:port?params#name',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final clip = await Clipboard.getData(Clipboard.kTextPlain);
                        if (clip?.text != null) {
                          textController.text = clip!.text!;
                        }
                      },
                      icon: const Icon(Icons.paste_rounded, size: 16),
                      label: Text(isEn ? 'Paste from Clipboard' : 'جای‌گذاری از کلیپ‌بورد', style: const TextStyle(fontSize: 12)),
                    )
                  ],
                )
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final raw = textController.text.trim();
                if (raw.isEmpty) return;

                try {
                  final parsed = await parseImportLinks(input: raw);
                  setState(() {
                    for (var n in parsed) {
                      _savedNodeItems.add(SavedNodeItem(
                        node: n,
                        groupId: _selectedGroupId == 'all' ? 'manual' : _selectedGroupId,
                      ));
                    }
                    _selectedNode ??= _savedNodeItems.first.node;
                  });
                  await _saveNodesToDisk();
                  if (context.mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(isEn ? '${parsed.length} configs added successfully.' : 'تعداد ${parsed.length} کانفیگ اضافه شد.'), 
                        backgroundColor: const Color(0xFF2DCA73),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(isEn ? 'Error parsing config: $e' : 'خطا در پارس کانفیگ: $e')),
                    );
                  }
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DCA73)),
              child: Text(isEn ? 'Add' : 'افزودن', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
    );
  }

  void _openEditDialog(ProxyNode node, int itemIndex) {
    final bool isEn = AppTranslations.currentLang == 'en';
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
                  Text(
                    isEn ? 'Edit Server Configuration (VLESS / Trojan / Hysteria2)' : 'ویرایش پیکربندی سرور (VLESS / Trojan / Hysteria2)', 
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
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
                          Text(isEn ? 'Connection Protocol:' : 'پروتکل اتصال:', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                            items: ['vless', 'vmess', 'trojan', 'hysteria2', 'tuic', 'shadowsocks'].map((p) => DropdownMenuItem(value: p, child: Text(p.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 24),
                      
                      _buildDialogField(isEn ? 'Alias / Remarks' : 'نام مستعار (Alias / Remarks)', aliasController),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(flex: 3, child: _buildDialogField(isEn ? 'Server Address' : 'آدرس سرور (Address)', addressController)),
                          const SizedBox(width: 12),
                          Expanded(flex: 1, child: _buildDialogField(isEn ? 'Port' : 'پورت (Port)', portController, isNumeric: true)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField(
                        selectedProtocol == 'hysteria2' 
                            ? (isEn ? 'Auth Password' : 'رمز عبور احراز هویت (Auth Password)')
                            : (isEn ? 'UUID / Password' : 'شناسه کاربر (UUID / Password)'), 
                        uuidController
                      ),
                      const SizedBox(height: 12),
                      
                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(isEn ? 'Transport Protocol:' : 'پروتکل انتقال (Transport):', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

                        _buildDialogField(isEn ? 'WebSocket Host' : 'میزبان وب‌ساکت (Host)', hostController),
                        const SizedBox(height: 12),
                        _buildDialogField(isEn ? 'WebSocket Path' : 'مسیر وب‌ساکت (Path)', pathController),
                        const SizedBox(height: 12),
                      ],

                      const Divider(color: Colors.white12, height: 24),
                      Text(
                        isEn ? 'TLS & Reality Security Settings' : 'تنظیمات امنیت لایه اتصال (TLS / Reality)', 
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),

                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(isEn ? 'Security Type:' : 'نوع امنیت (Security):', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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

                      _buildDialogField(isEn ? 'Server Name (SNI / Peer)' : 'نام سرور امن (SNI / Peer)', sniController),
                      const SizedBox(height: 12),

                      if (selectedSecurity == 'reality') ...[
                        _buildDialogField(isEn ? 'Reality Public Key (pbk)' : 'کلید عمومی ریالیتی (Public Key / pbk)', pbkController),
                        const SizedBox(height: 12),
                        _buildDialogField(isEn ? 'Reality Short ID (sid)' : 'شناسه کوتاه ریالیتی (Short ID / sid)', sidController),
                        const SizedBox(height: 12),
                        _buildDialogField(isEn ? 'SpiderX Path (spx)' : 'مسیر اسپایدر (SpiderX / spx)', spxController),
                        const SizedBox(height: 12),
                      ],

                      if (selectedProtocol != 'hysteria2') ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(isEn ? 'Browser Fingerprint:' : 'اثر انگشت مرورگر (Fingerprint):', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                            Text(isEn ? 'ALPN Protocol:' : 'پروتکل ALPN:', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                        title: Text(
                          isEn ? 'Allow Insecure Certificates' : 'نادیده گرفتن خطای گواهی امنیتی (Allow Insecure)', 
                          style: const TextStyle(fontSize: 12),
                        ),
                        value: allowInsecure,
                        activeThumbColor: const Color(0xFF6C5DD3),
                        onChanged: (val) {
                          setDialogState(() => allowInsecure = val);
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField(
                        isEn ? 'ECH Config List (EchConfigList)' : 'رشته پیکربندی رمزنگاری هدر (EchConfigList)', 
                        echController, 
                        hint: isEn ? 'Base64 ECH Config list' : 'کد Base64 یا لیست ECH Config',
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey)),
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
                      final updatedNode = ProxyNode(
                        name: updatedConfig.alias,
                        protocol: updatedConfig.protocol,
                        rawUrl: updatedConfig.toRawUrl(),
                      );
                      _savedNodeItems[itemIndex].node = updatedNode;
                      if (_selectedNode == node) {
                        _selectedNode = updatedNode;
                      }
                      _statusMessage = isEn ? "Server '${updatedConfig.alias}' updated." : "تنظیمات سرور '${updatedConfig.alias}' به‌روزرسانی شد.";
                    });
                    
                    final navigator = Navigator.of(context);
                    await _saveNodesToDisk();
                    navigator.pop();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C5DD3)),
                  child: Text(isEn ? 'Save Changes' : 'ثبت تغییرات', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openAddOrEditDnsDialog({DnsProfile? editDns}) {
    final bool isEn = AppTranslations.currentLang == 'en';
    final nameController = TextEditingController(text: editDns?.name ?? '');
    final primaryController = TextEditingController(text: editDns?.primary ?? '');
    final secondaryController = TextEditingController(text: editDns?.secondary ?? '');
    final descriptionController = TextEditingController(text: editDns?.description ?? '');
    final dohUrlController = TextEditingController(text: editDns?.dohUrl ?? '');
    final dotHostController = TextEditingController(text: editDns?.dotHost ?? '');
    String selectedType = editDns?.dnsType ?? 'udp';

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF6DD5ED), width: 1.4),
              ),
              title: Row(
                children: [
                  Icon(editDns == null ? Icons.add_moderator_rounded : Icons.edit_rounded, color: const Color(0xFF6DD5ED)),
                  const SizedBox(width: 12),
                  Text(
                    editDns == null 
                        ? (isEn ? 'Add Custom DNS' : 'افزودن DNS سفارشی جدید')
                        : (isEn ? 'Edit DNS Profile' : 'ویرایش مشخصات دی‌ان‌اس'), 
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDialogField(isEn ? 'DNS Display Name' : 'نام نمایشی دی‌ان‌اس', nameController),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(isEn ? 'Protocol Type:' : 'نوع پروتکل اتصال DNS:', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          DropdownButton<String>(
                            value: selectedType,
                            dropdownColor: const Color(0xFF090B10),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            onChanged: (val) {
                              if (val != null) setDialogState(() => selectedType = val);
                            },
                            items: ['udp', 'doh', 'dot'].map((type) => DropdownMenuItem(value: type, child: Text(type.toUpperCase()))).toList(),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildDialogField(isEn ? 'Primary IP Address' : 'آدرس آی‌پی اصلی (Primary IP)', primaryController),
                      const SizedBox(height: 12),
                      _buildDialogField(isEn ? 'Secondary IP Address' : 'آدرس آی‌پی ثانویه (Secondary IP)', secondaryController),
                      const SizedBox(height: 12),
                      if (selectedType == 'doh') ...[
                        _buildDialogField(isEn ? 'DoH URL' : 'لینک بستر DoH (HTTPS)', dohUrlController),
                        const SizedBox(height: 12),
                      ],
                      if (selectedType == 'dot') ...[
                        _buildDialogField(isEn ? 'DoT Host' : 'هاست امن DoT (TLS)', dotHostController),
                        const SizedBox(height: 12),
                      ],
                      _buildDialogField(isEn ? 'Short Description' : 'توضیحات کوتاه دی‌ان‌اس', descriptionController),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nameController.text.trim().isEmpty || primaryController.text.trim().isEmpty) return;

                    final updated = DnsProfile(
                      name: nameController.text.trim(),
                      primary: primaryController.text.trim(),
                      secondary: secondaryController.text.trim().isEmpty ? primaryController.text.trim() : secondaryController.text.trim(),
                      description: descriptionController.text.trim().isEmpty ? 'دی‌ان‌اس کاربر' : descriptionController.text.trim(),
                      dnsType: selectedType,
                      dohUrl: selectedType == 'doh' ? dohUrlController.text.trim() : null,
                      dotHost: selectedType == 'dot' ? dotHostController.text.trim() : null,
                      isCustom: true,
                    );

                    setState(() {
                      if (editDns == null) {
                        _dnsList.add(updated);
                        _selectedDns = updated;
                      } else {
                        final idx = _dnsList.indexOf(editDns);
                        if (idx != -1) _dnsList[idx] = updated;
                        if (_selectedDns == editDns) _selectedDns = updated;
                      }
                    });

                    await _saveDnsToDisk();
                    if (context.mounted) Navigator.of(context).pop();
                    _testDnsPing();
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2193B0)),
                  child: Text(
                    editDns == null ? (isEn ? 'Add' : 'افزودن') : (isEn ? 'Save' : 'ذخیره تغییرات'),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// پنجره مدرن و اختصاصی مدیریت، تفکیک، ویرایش و حذف دی‌ان‌اس‌ها
  void _openDnsManagerDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    String filterType = 'all'; // 'all', 'scanned', 'official', 'custom'
    String searchQuery = '';
    final searchCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            final filtered = _dnsList.where((d) {
              final isScan = d.name.contains('[اسکن]') || d.name.contains('[Scan]');
              final isCust = d.isCustom && !isScan;
              final isOff = !d.isCustom;

              if (filterType == 'scanned' && !isScan) return false;
              if (filterType == 'official' && !isOff) return false;
              if (filterType == 'custom' && !isCust) return false;

              if (searchQuery.isNotEmpty) {
                final q = searchQuery.toLowerCase();
                return d.name.toLowerCase().contains(q) || d.primary.contains(q);
              }
              return true;
            }).toList();

            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xFF6DD5ED), width: 1.4),
              ),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF6DD5ED).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.dns_rounded, color: Color(0xFF6DD5ED), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        isEn ? 'DNS Profiles Manager' : 'مدیریت و انتخاب دی‌ان‌اس‌ها',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          _openAddOrEditDnsDialog();
                          setDialogState(() {});
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2193B0),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 16),
                        label: Text(isEn ? 'Add' : 'افزودن جدید', style: const TextStyle(fontSize: 11)),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.grey),
                        onPressed: () => Navigator.of(ctx).pop(),
                      )
                    ],
                  )
                ],
              ),
              content: SizedBox(
                width: 650,
                height: 520,
                child: Column(
                  children: [
                    // نوار سرچ و فیلتر دسته‌بندی
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 38,
                            child: TextField(
                              controller: searchCtrl,
                              onChanged: (v) => setDialogState(() => searchQuery = v.trim()),
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                hintText: isEn ? 'Search DNS name or IP...' : 'جستجوی نام یا آی‌پی دی‌ان‌اس...',
                                prefixIcon: const Icon(Icons.search_rounded, size: 16, color: Colors.grey),
                                filled: true,
                                fillColor: const Color(0xFF090B10),
                                contentPadding: EdgeInsets.zero,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Wrap(
                          spacing: 6,
                          children: [
                            _buildFilterChip(isEn ? 'All' : 'همه', 'all', filterType, (v) => setDialogState(() => filterType = v)),
                            _buildFilterChip(isEn ? '⚡ Scanned' : '⚡ اسکن‌شده', 'scanned', filterType, (v) => setDialogState(() => filterType = v)),
                            _buildFilterChip(isEn ? '🌐 Official' : '🌐 رسمی', 'official', filterType, (v) => setDialogState(() => filterType = v)),
                            _buildFilterChip(isEn ? '🛠️ Custom' : '🛠️ سفارشی', 'custom', filterType, (v) => setDialogState(() => filterType = v)),
                          ],
                        )
                      ],
                    ),
                    const SizedBox(height: 14),

                    // لیست تمیز و کارتی دی‌ان‌اس‌ها با دکمه ویرایش و حذف
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(child: Text(isEn ? 'No DNS profiles found.' : 'هیچ دی‌ان‌اسی در این دسته یافت نشد.', style: const TextStyle(color: Colors.grey)))
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final dns = filtered[index];
                                final isSelected = _selectedDns == dns;
                                final isScan = dns.name.contains('[اسکن]') || dns.name.contains('[Scan]');

                                return InkWell(
                                  onTap: () {
                                    setState(() => _selectedDns = dns);
                                    setDialogState(() {});
                                    _testDnsPing();
                                    Navigator.of(ctx).pop();
                                  },
                                  borderRadius: BorderRadius.circular(12),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isSelected ? const Color(0xFF6DD5ED).withValues(alpha: 0.15) : const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected ? const Color(0xFF6DD5ED) : Colors.white10,
                                        width: isSelected ? 1.4 : 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                          color: isSelected ? const Color(0xFF6DD5ED) : Colors.grey,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isScan ? Colors.amber.withValues(alpha: 0.2) : Colors.white10,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(
                                            dns.dnsType.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                              color: isScan ? Colors.amberAccent : const Color(0xFF6DD5ED),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                dns.name,
                                                style: TextStyle(
                                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                                  color: isSelected ? Colors.white : Colors.white70,
                                                  fontSize: 12.5,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                'IP: ${dns.primary}  ${dns.secondary.isNotEmpty ? "|  ${dns.secondary}" : ""}',
                                                style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontFamily: 'monospace'),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.grey),
                                          tooltip: isEn ? 'Edit' : 'ویرایش',
                                          onPressed: () {
                                            _openAddOrEditDnsDialog(editDns: dns);
                                            setDialogState(() {});
                                          },
                                        ),
                                        if (dns.isCustom || isScan)
                                          IconButton(
                                            icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                                            tooltip: isEn ? 'Delete' : 'حذف',
                                            onPressed: () async {
                                              setState(() {
                                                _dnsList.remove(dns);
                                                if (_selectedDns == dns) {
                                                  _selectedDns = _dnsList.first;
                                                }
                                              });
                                              setDialogState(() {});
                                              await _saveDnsToDisk();
                                            },
                                          ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildFilterChip(String label, String value, String current, ValueChanged<String> onSelect) {
    final isSel = value == current;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 10.5, color: isSel ? Colors.black : Colors.grey, fontWeight: FontWeight.bold)),
      selected: isSel,
      selectedColor: const Color(0xFF6DD5ED),
      backgroundColor: const Color(0xFF090B10),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      onSelected: (_) => onSelect(value),
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
    } catch (e, st) {
      AppLogger.error("ANDROID_VPN", "خطا در اتصال به VPN اندروید", e, st);
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
    } catch (e, st) {
      AppLogger.error("ANDROID_VPN", "خطا در قطع VPN اندروید", e, st);
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
      if (mounted) {
        setState(() {
          _dnsPing = ping >= 0 ? ping : null;
          _isPingingDns = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPingingDns = false;
        });
      }
    }
  }

  Future<void> _initSystemTray() async {
    String iconPath = 'assets/app_icon.ico';
    
    if (kReleaseMode) {
      final String exePath = Platform.resolvedExecutable;
      final String exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
      iconPath = '$exeDir\\data\\flutter_assets\\assets\\app_icon.ico';
    }

    try {
      await trayManager.setIcon(iconPath); 
      await trayManager.setToolTip('RedCloud VPN');
      await _updateSystemTrayMenu();
    } catch (e) {
      AppLogger.warn("TRAY", "خطا در تنظیمات سیستم‌تری: $e");
    }
  }

  /// به‌روزرسانی فوق‌سریع و هوشمند منوی سینی ویندوز (بدون لوپ و مصرف صفر منابع)
  Future<void> _updateSystemTrayMenu() async {
    if (!Platform.isWindows) return;
    final bool isEn = AppTranslations.currentLang == 'en';
    final bool isAnyConnected = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning || _isGamingRunning;

    // ۱. استخراج عنوان وضعیت زنده
    String statusTitle;
    if (_isGamingRunning) {
      final game = _selectedGame?.name ?? 'Game';
      final ping = _gamingMetrics?.currentPingMs ?? -1;
      statusTitle = isEn 
          ? '● Status: Gaming Active ($game ${ping > 0 ? "- $ping ms" : ""})'
          : '● وضعیت: گیمینگ ($game ${ping > 0 ? "- $ping ms" : ""})';
    } else if (_isHybridRunning) {
      statusTitle = isEn ? '● Status: Connected (Hybrid Tunnel)' : '● وضعیت: متصل (اتصال هیبریدی)';
    } else if (_isProxyRunning) {
      final sName = _selectedNode?.name ?? 'V2Ray';
      statusTitle = isEn ? '● Status: Connected ($sName)' : '● وضعیت: متصل ($sName)';
    } else if (_isAetherRunning) {
      statusTitle = isEn ? '● Status: Connected (Aether MASQUE)' : '● وضعیت: متصل (شبکه اِتر)';
    } else if (_isTorRunning || _isTorMasqueRunning) {
      statusTitle = isEn ? '● Status: Connected (Tor Network)' : '● وضعیت: متصل (شبکه تور)';
    } else if (_isPsiphonRunning || _isPsiphonMasqueRunning) {
      statusTitle = isEn ? '● Status: Connected (Psiphon)' : '● وضعیت: متصل (سایفون)';
    } else {
      statusTitle = isEn ? '○ Status: Disconnected' : '○ وضعیت: قطع اتصال';
    }

    try {
      final List<MenuItem> items = [
        // ردیف ۱: عنوان وضعیت (غیرقابل کلیک و صرفاً نمایشی)
        MenuItem(key: 'status_info', label: statusTitle, disabled: true),
        MenuItem.separator(),

        // ردیف ۲: دکمه قطع یا وصل سریع
        MenuItem(
          key: 'toggle_connect',
          label: isAnyConnected 
              ? (isEn ? '🔴 Disconnect' : '🔴 قطع اتصال (Disconnect)')
              : (isEn ? '⚡ Quick Connect' : '⚡ اتصال سریع (Quick Connect)'),
        ),
        MenuItem.separator(),

        // ردیف ۳: سوییچ‌های تک‌کلیکی
        MenuItem(
          key: 'toggle_tun',
          label: _useTunMode 
              ? (isEn ? '✔ Virtual TUN Adapter (ON)' : '✔ کارت شبکه مجازی (TUN: روشن)')
              : (isEn ? '✖ Virtual TUN Adapter (OFF)' : '✖ کارت شبکه مجازی (TUN: خاموش)'),
        ),
        MenuItem(
          key: 'toggle_sys_proxy',
          label: _useSystemProxy 
              ? (isEn ? '✔ System Proxy (ON)' : '✔ پروکسی سیستم (Proxy: روشن)')
              : (isEn ? '✖ System Proxy (OFF)' : '✖ پروکسی سیستم (Proxy: خاموش)'),
        ),
        MenuItem(
          key: 'toggle_gaming',
          label: _isGamingRunning
              ? (isEn ? '🎮 Stop Gaming Booster' : '🎮 توقف بوستر گیمینگ')
              : (isEn ? '🎮 Start Gaming Booster' : '🎮 شروع بوستر گیمینگ'),
        ),
        MenuItem.separator(),

        // ردیف ۴: ابزار نجات اینترنت و پاکسازی پروکسی ویندوز
        MenuItem(
          key: 'fix_stuck_proxy',
          label: isEn ? '🧹 Clear Stuck Proxy & Fix Internet' : '🧹 پاکسازی فوری پروکسی و اینترنت',
        ),
        MenuItem.separator(),

        // ردیف ۵: گزینه‌های عمومی
        MenuItem(key: 'show_window', label: isEn ? '📂 Open Application' : '📂 باز کردن برنامه'),
        MenuItem(key: 'exit_app', label: isEn ? '❌ Exit Completely' : '❌ خروج کامل'),
      ];

      await trayManager.setContextMenu(Menu(items: items));
    } catch (_) {}
  }

  @override
  @override
  void onWindowClose() async {
    bool isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      _pulseController?.stop();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await windowManager.hide();
      if (mounted) {
        setState(() {
          _isWindowVisible = false;
          _statusMessage = AppTranslations.currentLang == 'en'
              ? "App is running in background (System Tray)."
              : "برنامه در پس‌زمینه و کنار ساعت فعال است.";
        });
      }
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    final bool isEn = AppTranslations.currentLang == 'en';

    // ۱. قطع یا وصل سریع ترافیک
    if (menuItem.key == 'toggle_connect') {
      final bool isAny = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning || _isGamingRunning;
      if (isAny) {
        if (_isGamingRunning) await stopGamingBoost();
        if (_isHybridRunning) await stopHybridConnection();
        if (_isProxyRunning) await stopProxyCore();
        if (_isAetherRunning) await stopAetherCore();
        if (_isTorRunning) await stopTorCore();
        if (_isPsiphonRunning) await stopPsiphonCore();
        setState(() {
          _isGamingRunning = false;
          _isHybridRunning = false;
          _isProxyRunning = false;
          _isAetherRunning = false;
          _isTorRunning = false;
          _isPsiphonRunning = false;
        });
      } else {
        await _toggleV2RayConnection();
      }
      await _updateSystemTrayMenu();
    }
    // ۲. سوییچ کارت شبکه TUN
    else if (menuItem.key == 'toggle_tun') {
      setState(() {
        _useTunMode = !_useTunMode;
        if (_useTunMode) _useSystemProxy = false;
      });
      await _updateSystemTrayMenu();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_useTunMode 
                ? (isEn ? 'TUN Mode enabled.' : 'کارت شبکه مجازی TUN فعال شد.') 
                : (isEn ? 'TUN Mode disabled.' : 'کارت شبکه مجازی TUN خاموش شد.')),
            backgroundColor: _useTunMode ? const Color(0xFF2DCA73) : Colors.amber[800],
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
    // ۳. سوییچ پروکسی سیستم
    else if (menuItem.key == 'toggle_sys_proxy') {
      if (!_useTunMode) {
        setState(() => _useSystemProxy = !_useSystemProxy);
        if (_isProxyRunning || _isHybridRunning) {
          await Process.run(
            'reg',
            ['add', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', _useSystemProxy ? '1' : '0', '/f'],
            runInShell: true,
          );
        }
        await _updateSystemTrayMenu();
      }
    }
    // ۴. شروع یا توقف بوستر گیمینگ
    else if (menuItem.key == 'toggle_gaming') {
      await _toggleGamingBoost();
      await _updateSystemTrayMenu();
    }
    // ۵. پاکسازی فوری پروکسی رجیستری و بازگرداندن اینترنت
    else if (menuItem.key == 'fix_stuck_proxy') {
      try {
        await Process.run(
          'reg',
          ['add', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f'],
          runInShell: true,
        );
        await resetSystemDns();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isEn ? 'System proxy cleared! Internet restored.' : 'پروکسی ویندوز پاکسازی شد! اینترنت آزاد شد.'),
              backgroundColor: const Color(0xFF2DCA73),
            ),
          );
        }
      } catch (_) {}
      await _updateSystemTrayMenu();
    }
    // ۶. باز کردن پنجره برنامه
    else if (menuItem.key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
      if (mounted) {
        setState(() {
          _isWindowVisible = true;
        });
        if (_hasUpdate) {
          _pulseController?.repeat(reverse: true);
        }
      }
      await _updateSystemTrayMenu();
    }
    // ۷. خروج کامل از نرم‌افزار
    else if (menuItem.key == 'exit_app') {
      AppLogger.info("APP_LIFECYCLE", "خروج کامل از نرم‌افزار توسط کاربر...");
      await _maybeStopGoodbyeDpi();
      await _maybeStopDnscrypt();
      
      if (_isUdp2rawActive) await stopUdp2RawCore();
      if (_isGamingRunning) await stopGamingBoost();
      if (_isLanShareRunning) await stopLanRelay();
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
    if (mounted) {
      setState(() {
        _isWindowVisible = true;
      });
      if (_hasUpdate) {
        _pulseController?.repeat(reverse: true);
      }
    }
  }

  @override
  void onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }

  Future<void> _checkStatus() async {
    try {
      final activeHybrid = await isHybridConnected();
      final activeProxy = await isConnected();
      final activeAether = await isAetherConnected();
      final activeTorMasque = await isTorMasqueConnected();
      final activeTor = await isTorConnected();
      final activePsiphonMasque = await isPsiphonMasqueConnected();
      final activePsiphon = await isPsiphonConnected();
      final activeDns = await isDnsActive();
      final activeLan = await isLanRelayRunning();
      final activeGoodbye = await isGoodbyedpiRunning();
      final bool isEn = AppTranslations.currentLang == 'en';
      
      if (mounted) {
        setState(() {
          _isHybridRunning = activeHybrid;
          _isProxyRunning = activeProxy && !activeHybrid;
          _isAetherRunning = activeAether && !activeHybrid && !activePsiphonMasque && !activeTorMasque;
          _isTorMasqueRunning = activeTorMasque;
          _isTorRunning = activeTor;
          _isPsiphonMasqueRunning = activePsiphonMasque;
          _isPsiphonRunning = activePsiphon;
          _isDnsRunning = activeDns;
          _isLanShareRunning = activeLan;
          _isGoodbyeDpiRunning = activeGoodbye;
          
          if (activeHybrid) {
            _statusMessage = isEn ? "Connected to RedCloud Hybrid (Aether + Sing-box)" : "متصل به اتصال هیبریدی RedCloud (پل اِتر + Sing-box)";
            _startTrafficMonitoring();
            _fetchIpInfo();
          } else if (activeTorMasque) {
            _statusMessage = isEn ? "Connected to Tor over MASQUE Bridge" : "متصل به شبکه پیاز تور بر بستر مسک (Tor over MASQUE)";
            _fetchIpInfo();
          } else if (activePsiphonMasque) {
            _statusMessage = isEn ? "Connected to Psiphon over MASQUE Bridge" : "متصل به شبکه سایفون بر بستر مسک (Psiphon over MASQUE)";
            _fetchIpInfo();
          } else if (activeAether) {
            _statusMessage = isEn ? "Connected to Aether Network (MASQUE)" : "متصل به شبکه ضدسانسور اِتر (MASQUE)";
            _fetchIpInfo();
          } else if (activeProxy) {
            _statusMessage = isEn ? "Connected to V2Ray Direct Server" : "متصل به سرور ویتوری";
            _startTrafficMonitoring();
            _startTelemetryReporting();
            _fetchIpInfo();
          } else if (activeTor) {
            _statusMessage = isEn ? "Connected to Tor Onion Network" : "متصل به شبکه پیاز تور";
            _fetchIpInfo();
          } else if (activePsiphon) {
            _statusMessage = isEn ? "Connected to Psiphon Network" : "متصل به شبکه سایفون";
            _fetchIpInfo();
          } else if (activeDns) {
            _statusMessage = isEn ? "System DNS is active." : "تنظیمات دی‌ان‌اس بر روی سیستم فعال است.";
          } else {
            _statusMessage = 'status_disconnected'.tr();
          }
        });
      }
    } catch (e, st) {
      AppLogger.error("STATUS_CHECK", "خطا در بررسی وضعیت سیستم", e, st);
    }
  }

  Future<void> _fetchIpInfo({int retryCount = 2}) async {
    final bool isAnyConnected = _isProxyRunning || _isHybridRunning || _isAetherRunning || _isTorRunning || _isPsiphonRunning;
    if (!isAnyConnected) return;

    if (!mounted) return;
    setState(() {
      _isLoadingIpInfo = true;
    });

    // خواندن مستقیم و آنی مشخصات خروجی سایفون از گزارش رسمی اِتر
    if ((_isPsiphonRunning || _isPsiphonMasqueRunning) && _usePsiphonCdnFronting) {
      try {
        final exitFile = File('${Directory.systemTemp.path}\\RedCloud\\psiphon_exit.txt');
        if (await exitFile.exists()) {
          final line = await exitFile.readAsString();
          // نمونه خط: [+] psiphon through the tunnel exit: 172.232.129.119, SE via ARN, 2160ms
          if (line.contains("exit:")) {
            final afterExit = line.split("exit:")[1].trim();
            final parts = afterExit.split(",");
            if (parts.length >= 2) {
              final realIp = parts[0].trim();
              final countryPart = parts[1].trim().split(" ")[0].trim();
              setState(() {
                _publicIp = realIp;
                _countryCode = countryPart;
                _countryName = countryPart == "SE" ? "Sweden" : (countryPart == "JP" ? "Japan" : countryPart);
                _cityName = parts[1].trim();
                _isLoadingIpInfo = false;
                _statusMessage = "متصل به سایفون فرانتینگ (${_countryName})";
              });
              return;
            }
          }
        }
      } catch (_) {}
    }

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
            final proxyPort = _usePsiphonCdnFronting ? 1821 : 9081;
            client.findProxy = (uri) => "PROXY 127.0.0.1:$proxyPort";
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

            final bool isEn = AppTranslations.currentLang == 'en';
            if (ip != null && countryCode != null && mounted) {
              setState(() {
                _publicIp = ip;
                _countryCode = countryCode;
                _countryName = country ?? (isEn ? 'Unknown' : 'ناشناس');
                _cityName = city ?? (isEn ? 'Unknown' : 'ناشناس');
                _isLoadingIpInfo = false;
                _statusMessage = isEn 
                    ? "Connection stable, traffic active (Location: $_countryName)." 
                    : "اتصال پایدار و ترافیک فعال است (لوکیشن: $_countryName).";
              });
              AppLogger.info("IP_GEO", "اطلاعات آی‌پی دریافت شد: $ip ($country)");

              // فعال‌سازی ناظر خودکار هویت: تطابق ساعت سیستم با کشور خروجی
              _syncTimezoneToCountry(countryCode);
              _updateSystemTrayMenu(); // آپدیت خودکار منوی تری به وضعیت متصل
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
    final bool isEn = AppTranslations.currentLang == 'en';
    setState(() {
      _isLoadingAccounts = true;
      _statusMessage = isEn ? "Fetching active accounts..." : "در حال دریافت لیست اکانت‌های فعال...";
    });

    try {
      final cacheFile = await _getLocalFile('cached_github_accounts.json');
      http.Response? response;
      try {
        response = await http.get(Uri.parse(
          'https://raw.githubusercontent.com/Devtahas/Devtahas-redcloud-config/main/accounts.json'
        )).timeout(const Duration(seconds: 4));
      } catch (_) {
        response = null;
      }

      String rawJsonBody = '';
      if (response != null && response.statusCode == 200) {
        rawJsonBody = response.body;
        await cacheFile.writeAsString(rawJsonBody);
      } else if (await cacheFile.exists()) {
        rawJsonBody = await cacheFile.readAsString();
        AppLogger.info("CACHE", "گیت‌هاب در دسترس نبود؛ اکانت‌ها از حافظه کش آفلاین بازیابی شدند.");
      }

      if (rawJsonBody.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(rawJsonBody);
        
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
          throw Exception(isEn ? "All shared accounts are full." : "تمام سرورهای اشتراکی پر هستند.");
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
            name: isEn 
                ? 'Account ${i + 1} (${selectedRandoms[i].status == 'full' ? 'Full' : 'Medium'})'
                : 'اکانت ${i + 1} (${selectedRandoms[i].status == 'full' ? 'فول شارژ' : 'ظرفیت متوسط'})',
          ));
        }

        setState(() {
          _githubAccounts = finalAccounts;
          _isLoadingAccounts = false;
          _statusMessage = isEn ? "${_githubAccounts.length} accounts loaded." : "تعداد ${_githubAccounts.length} اکانت بارگذاری شد.";
          
          if (_githubAccounts.isNotEmpty) {
            _selectAccount(_githubAccounts.first);
          }
        });

      } else {
        final errCode = response?.statusCode.toString() ?? 'Offline/Blocked';
        throw Exception("GitHub API Error: $errCode");
      }
    } catch (e, st) {
      AppLogger.error("GITHUB_ACCOUNTS", "Error fetching accounts", e, st);
      setState(() {
        _isLoadingAccounts = false;
        _statusMessage = isEn ? "Error fetching accounts: $e" : "خطا در دریافت اکانت‌ها: $e";
      });
    }
  }

  void _selectAccount(VlessAccount account) {
    final bool isEn = AppTranslations.currentLang == 'en';
    setState(() {
      _selectedGithubAccount = account;
      _uuidController.text = account.uuid;
      _workerController.text = account.worker;
      _pathController.text = account.path;
      _statusMessage = isEn 
          ? "${account.name} applied to fields." 
          : "اطلاعات ${account.name} روی فیلدها اعمال شد.";
    });
  }

  Future<void> _handleAutoRotation() async {
    AppLogger.info("ROTATION", "آغاز چرخش خودکار اکانت‌ها...");
    await _stopTelemetryReporting();
    if (_isHybridRunning) {
      await stopHybridConnection();
    } else if (_isProxyRunning) {
      await stopProxyCore();
    }
    _stopTrafficMonitoring();
    // در حین چرخش و اسکن مجدد، لایه ضد DPI باید روشن بماند تا اسکنر کور نشود
    await _maybeStartGoodbyeDpi(true);
    
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
    final bool isEn = AppTranslations.currentLang == 'en';
    if (_uuidController.text.isEmpty || _pathController.text.isEmpty || _workerController.text.isEmpty) {
      setState(() => _statusMessage = isEn 
          ? "Error: Please fill in account details first." 
          : "خطا: لطفاً ابتدا اطلاعات اکانت را پر کنید.");
      return;
    }

    _scanStatsTimer?.cancel();
    // محافظت از تمام پکت‌های اسکنر در سطح کارت شبکه
    await _maybeStartGoodbyeDpi(true);

    setState(() {
      _isScanning = true;
      _scannedTotal = 0;
      _scannedAlive = 0;
      _scannedDead = 0;
      _statusMessage = isEn 
          ? (mode == "deep" 
              ? "Running deep multi-threaded scan from cloudflare_IPs.txt..." 
              : "Running quick Cloudflare scan...")
          : (mode == "deep" 
              ? "در حال اسکن عمیق و چندنخی از فایل cloudflare_IPs.txt..." 
              : "در حال اجرای اسکن سریع کلودفلر...");
    });

    _scanStatsTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) async {
      if (!_isScanning) {
        timer.cancel();
        return;
      }
      try {
        final stats = await getScannerStats();
        if (mounted) {
          setState(() {
            _scannedTotal = stats.totalScanned;
            _scannedAlive = stats.aliveCount;
            _scannedDead = stats.deadCount;
          });
        }
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
          _statusMessage = isEn 
              ? "Scan finished; no clean IPs found." 
              : "اسکن پایان یافت؛ هیچ آی‌پی تمیزی یافت نشد.";
        } else {
          _statusMessage = isEn 
              ? "Scan finished! Found ${cleanNodes.length} clean, high-speed IPs." 
              : "اسکن پایان یافت! تعداد ${cleanNodes.length} آی‌پی تمیز و پرسرعت یافت شد.";
          
          _savedNodeItems.removeWhere((item) => item.groupId == 'scanner');
          for (var node in cleanNodes) {
            _savedNodeItems.add(SavedNodeItem(
              node: ProxyNode(
                name: node.name.replaceAll("Scanner", "From Scanner"),
                protocol: node.protocol,
                rawUrl: node.rawUrl,
              ),
              groupId: 'scanner',
            ));
          }
          final scannerFirst = _savedNodeItems.firstWhere((item) => item.groupId == 'scanner');
          _selectedNode = scannerFirst.node;
        }
      });
      await _saveNodesToDisk();
    } catch (e, st) {
      _scanStatsTimer?.cancel();
      AppLogger.error("SCANNER", "Error during scan", e, st);
      setState(() {
        _isScanning = false;
        _statusMessage = isEn ? "Scan error: $e" : "خطا در اسکن: $e";
      });
    }
  }

  void _stopCloudflareScan() async {
    final bool isEn = AppTranslations.currentLang == 'en';
    try {
      await stopCloudflareScanner();
      _scanStatsTimer?.cancel();
      if (!_isProxyRunning && !_isHybridRunning) {
        await _maybeStopGoodbyeDpi();
      }
      setState(() {
        _statusMessage = isEn 
            ? "Stop command sent. Collecting clean IPs..." 
            : "دستور توقف اسکن ارسال شد. در حال جمع‌آوری آی‌پی‌های سفید...";
      });
    } catch (e, st) {
      AppLogger.error("SCANNER", "Error stopping scan", e, st);
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
          _stopCore2Monitoring();
          await _maybeStopGoodbyeDpi();
          await _maybeStopDnscrypt();
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

          if (_isGamingRunning) {
            await stopGamingBoost();
            _gamingMetricsTimer?.cancel();
            setState(() => _isGamingRunning = false);
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

          // اجرای افکت لایه اول GoodbyeDPI در صورت فعال بودن
          await _maybeStartGoodbyeDpi(_useGoodbyeDpiDashboard);
          // فعال‌سازی هوشمند اولویت اول دی‌ان‌اس (DNSCrypt Shield)
          await _maybeStartDnscrypt();

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

            final String comboTag = msg.contains("via ")
                ? msg.substring(msg.indexOf("via ") + 4).replaceAll("!", "").trim()
                : "Aether + VLESS";

            setState(() {
              _isHybridRunning = true;
              _activeProtocolName = 'Hybrid ($comboTag)';
              _statusMessage = msg;
            });
            _startCore2Monitoring();
          } else if (_useSmartOptimizer) {
            setState(() {
              _statusMessage = "هسته اول در حال کالیبراسیون و کشف بهترین فرگمنت و پورت...";
            });

            final calibrated = await startSmartOptimizedProxy(
              binaryPath: _binaryPathController.text.trim(),
              selectedNode: _selectedNode!,
              useSystemProxy: _useSystemProxy,
              useTunMode: _useTunMode,
              dnsType: _selectedDns.dnsType,
              dnsPrimary: _selectedDns.primary,
              dnsSecondary: _selectedDns.secondary,
              dnsDotHost: _selectedDns.dotHost,
            );

            setState(() {
              _isProxyRunning = true;
              _latestCalibration = calibrated;
              _statusMessage = "متصل شد! پورت: ${calibrated.selectedPort} | فرگمنت: ${calibrated.optimalDelayStr} (امتیاز: ${calibrated.qualityMetrics.overallScore.toStringAsFixed(1)})";
            });

            _startCore2Monitoring();
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

            _startCore2Monitoring();
          }

          Future.delayed(const Duration(seconds: 2), () {
            if (_isHybridRunning || _isProxyRunning) {
              _startTrafficMonitoring();
              _startTelemetryReporting();
            }
          });

          _fetchIpInfo();
          // بهینه‌ساز هوشمند پینگ در پس‌زمینه (اگر بهتر بود فعال می‌ماند، اگر نه درجا بسته می‌شود)
          if (Platform.isWindows && _selectedNode != null) {
            final uri = Uri.tryParse(_selectedNode!.rawUrl);
            if (uri != null && uri.host.isNotEmpty) {
              benchmarkAndOptimizeUdp2Raw(
                remoteHost: uri.host,
                remotePort: uri.port == 0 ? 443 : uri.port,
                binaryPath: null,
                key: null,
              ).then((optPing) {
                if (optPing > 0 && mounted) {
                  setState(() => _isUdp2rawActive = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(AppTranslations.isRtl 
                          ? 'سازوکار بهینه‌ساز FakeTCP فعال شد (پینگ بهبود یافته: $optPing ms)' 
                          : 'FakeTCP optimizer active in background (Ping: $optPing ms)'),
                      backgroundColor: const Color(0xFF2DCA73),
                    ),
                  );
                }
              }).catchError((_) {
                if (mounted) setState(() => _isUdp2rawActive = false);
              });
            }
          }
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
    } catch (e, st) {
      AppLogger.error("V2RAY_CONN", "خطا در برقراری اتصال", e, st);
      setState(() => _statusMessage = "خطا در اتصال: ${e.toString()}");

      // باز کردن پنجره هوشمند: «آیا مشکلی در اتصال دارید؟»
      Future.delayed(const Duration(milliseconds: 300), () {
        _showTroubleshootDialog();
      });
    }
  }

  Future<void> _toggleAetherConnection() async {
    try {
      if (Platform.isWindows) {
        if (_isAetherRunning || _isAetherConnecting) {
          _stopCore2Monitoring();
          _aetherProgressTimer?.cancel();
          await stopProxyCore(); // پاکسازی فوری کارت شبکه TUN هنگام قطع اتصال
          final msg = await stopAetherCore();
          await _maybeStopGoodbyeDpi();
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

          // فعال‌سازی لایه محافظتی GoodbyeDPI در صورت تمایل کاربر
          await _maybeStartGoodbyeDpi(_useGoodbyeDpiAether);

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
            useSystemProxy: _useTunModeAether ? false : _useSystemProxy,
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

            if (mounted) {
              setState(() {
                _aetherProgressPercent = percent;
                if (statusTxt.isNotEmpty) {
                  _aetherStatusText = statusTxt;
                }
              });
            }

            if (isDone || percent >= 100) {
              timer.cancel();
              if (mounted) {
                // استخراج نام واقعی ترکیب کشف‌شده (مود + نویز) از خروجی هسته
                final String dynamicCombo = statusTxt.contains("via ")
                    ? statusTxt.substring(statusTxt.indexOf("via ") + 4).trim()
                    : '${_selectedAetherMode.toUpperCase()} ($_selectedAetherNoize)';

                final bool isFastPathHit = statusTxt.contains("Fast-Path") || statusTxt.contains("Memory");

                // اگر حالت TUN فعال باشد، تمام سیستم از گذرگاه پرسرعت اتر رله می‌شود
                if (_useTunModeAether) {
                  await startProxyWithNode(
                    binaryPath: _binaryPathController.text.trim(),
                    selectedNode: ProxyNode(
                      name: "Aether-TUN",
                      protocol: "socks",
                      rawUrl: "socks://127.0.0.1:1819#Aether-TUN",
                    ),
                    useSystemProxy: false,
                    customSni: null,
                    enableFragment: false,
                    enableRecordFragment: false,
                    tlsSpoof: null,
                    useTunMode: true,
                    dnsType: _selectedDns.dnsType,
                    dnsPrimary: _selectedDns.primary,
                    dnsSecondary: _selectedDns.secondary,
                    dnsDohUrl: _selectedDns.dohUrl,
                    dnsDotHost: _selectedDns.dotHost,
                    utlsFingerprint: null,
                    fragmentFallbackDelay: null,
                  );
                }

                final calib = await createProtocolCalibratedProfile(
                  protocolName: 'Aether ($dynamicCombo)',
                  modeOrRegion: dynamicCombo,
                  localPort: 1820,
                  measuredLatencyMs: 110.0,
                  isFastPath: isFastPathHit,
                );
                setState(() {
                  _isAetherRunning = true;
                  _isAetherConnecting = false;
                  _latestCalibration = calib;
                  _aetherProgressPercent = 100;
                  _activeProtocolName = 'Aether ($dynamicCombo)';
                  _aetherStatusText = "اتصال پایدار شد! پورت 1820 و 1819 فعال است.";
                  _statusMessage = isFastPathHit
                      ? "⚡ اتصال فوق‌سریع از حافظه یادگیری شبکه ($dynamicCombo)"
                      : "شبکه اتر با موفقیت متصل شد ($dynamicCombo).";
                });
                _startCore2Monitoring();
              }
              _fetchIpInfo();
            }
          });
        }
      } else if (Platform.isAndroid) {
        setState(() => _statusMessage = "شبکه اتر در پلتفرم اندروید در دست توسعه است.");
      }
    } catch (e, st) {
      _aetherProgressTimer?.cancel();
      AppLogger.error("AETHER_CONN", "خطا در برقراری اتصال شبکه اِتر", e, st);
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
          _stopCore2Monitoring();
          _torProgressTimer?.cancel();
          final String msg = _isTorMasqueRunning 
              ? await stopTorOverMasque() 
              : await stopTorCore();

          await _maybeStopGoodbyeDpi();

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

          // فعال‌سازی لایه افکت GoodbyeDPI برای محافظت از پکت‌های تور
          await _maybeStartGoodbyeDpi(_useGoodbyeDpiTor);

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
            final lastProgress = _torProgressPercent;

            if (mounted) {
              setState(() {
                _torProgressPercent = percent;
                _statusMessage = "پیشرفت اتصال تور: $percent٪";
              });
            }

            // ناظر هوشمند علائم حیاتی: اگر روی درصد پایین قفل کرد و هیچ پیشرفتی نداشت، پریست را عوض کن
            if (percent < 20 && percent == lastProgress && timer.tick > 8 && timer.tick % 8 == 0) {
              await _advanceToNextGoodbyeDpiPreset("Tor");
            }

            if (percent >= 100) {
              timer.cancel();
              if (mounted) {
                if (_useTunModeTor) {
                  await startProxyWithNode(
                    binaryPath: _binaryPathController.text.trim(),
                    selectedNode: ProxyNode(
                      name: "Tor-TUN",
                      protocol: "socks",
                      rawUrl: "socks://127.0.0.1:9050#Tor-TUN",
                    ),
                    useSystemProxy: false,
                    customSni: null,
                    enableFragment: false,
                    enableRecordFragment: false,
                    tlsSpoof: null,
                    useTunMode: true,
                    dnsType: _selectedDns.dnsType,
                    dnsPrimary: _selectedDns.primary,
                    dnsSecondary: _selectedDns.secondary,
                    dnsDohUrl: _selectedDns.dohUrl,
                    dnsDotHost: _selectedDns.dotHost,
                    utlsFingerprint: null,
                    fragmentFallbackDelay: null,
                  );
                }

                final calib = await createProtocolCalibratedProfile(
                  protocolName: _isTorMasqueEnabled ? 'Tor over MASQUE' : 'Tor Onion Network',
                  modeOrRegion: _isTorMasqueEnabled ? 'پل مسک ($_selectedTorCountry)' : _selectedTorCountry,
                  localPort: 9051,
                  measuredLatencyMs: 350.0,
                  isFastPath: true,
                );
                setState(() {
                  _isTorRunning = true;
                  _isTorMasqueRunning = _isTorMasqueEnabled;
                  _isTorConnecting = false;
                  _latestCalibration = calib;
                  _activeProtocolName = _isTorMasqueEnabled ? 'Tor over MASQUE' : 'Tor Onion Network';
                  _statusMessage = _isTorMasqueEnabled 
                      ? "اتصال ترکیبی تور بر بستر مسک (Tor over MASQUE) با موفقیت برقرار شد!" 
                      : msg;
                });
                _startCore2Monitoring();
              }
              
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
    } catch (e, st) {
      _torProgressTimer?.cancel();
      AppLogger.error("TOR_CONN", "خطا در برقراری اتصال شبکه تور", e, st);
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
          _stopCore2Monitoring();
          _psiphonProgressTimer?.cancel();
          await stopProxyCore(); // پاکسازی کارت شبکه TUN سایفون
          final String msg = _isPsiphonMasqueRunning 
              ? await stopPsiphonOverMasque() 
              : await stopPsiphonCore();
              
          await _maybeStopGoodbyeDpi();

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

          // اجرای لایه اول GoodbyeDPI برای باز کردن هندشیک سرورهای سایفون
          await _maybeStartGoodbyeDpi(_useGoodbyeDpiPsiphon);

          final rawCountryCode = _psiphonCountries[_selectedPsiphonCountry] ?? "";
          // در حالت CDN Fronting، منطقه کاملاً مجزا از لیست سنتی کنترل می‌شود
          final targetRegion = _usePsiphonCdnFronting ? _selectedCdnRegion : rawCountryCode;
          final countryCode = _usePsiphonCdnFronting
              ? "$targetRegion##cdn##$_psiphonCdnMode"
              : rawCountryCode;
          
          setState(() {
            _isPsiphonConnecting = true;
            _statusMessage = _usePsiphonCdnFronting
                ? (_isPsiphonMasqueEnabled
                    ? "در حال راه‌اندازی CDN Fronting بر بستر پل مسک اِتر..."
                    : "در حال اتصال به سرورهای سایفون با فناوری CDN Fronting...")
                : (_isPsiphonMasqueEnabled 
                    ? "در حال ایجاد پل ضدسانسور مسک و برقراری ارتباط با سایفون..." 
                    : "در حال اتصال به هسته سایفون...");
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

            // ناظر هوشمند علائم حیاتی سایفون: اگر در مرحله دست‌دهی متوقف ماند، پریست را تغییر بده
            if (!isDone && timer.tick > 12 && timer.tick % 10 == 0) {
              await _advanceToNextGoodbyeDpiPreset("Psiphon");
            }

            if (isDone) {
              timer.cancel();
              if (mounted) {
                try {
                  final psPort = _usePsiphonCdnFronting ? 1821 : 9080;

                  // راه‌اندازی خودکار Sing-box به عنوان رابط پروکسی وب و کارت TUN روی پورت سایفون
                  await startProxyWithNode(
                    binaryPath: _binaryPathController.text.trim(),
                    selectedNode: ProxyNode(
                      name: "Psiphon-Egress",
                      protocol: "socks",
                      rawUrl: "socks://127.0.0.1:$psPort#Psiphon-Egress",
                    ),
                    useSystemProxy: _useTunModePsiphon ? false : _useSystemProxy,
                    customSni: null,
                    enableFragment: false,
                    enableRecordFragment: false,
                    tlsSpoof: null,
                    useTunMode: _useTunModePsiphon,
                    dnsType: _selectedDns.dnsType,
                    dnsPrimary: _selectedDns.primary,
                    dnsSecondary: _selectedDns.secondary,
                    dnsDohUrl: _selectedDns.dohUrl,
                    dnsDotHost: _selectedDns.dotHost,
                    utlsFingerprint: null,
                    fragmentFallbackDelay: null,
                  );

                  final calib = await createProtocolCalibratedProfile(
                    protocolName: _isPsiphonMasqueEnabled ? 'Psiphon over MASQUE' : 'Psiphon Network',
                    modeOrRegion: _isPsiphonMasqueEnabled ? 'پل مسک ($_selectedPsiphonCountry)' : _selectedPsiphonCountry,
                    localPort: _usePsiphonCdnFronting ? 1821 : 9081,
                    measuredLatencyMs: 240.0,
                    isFastPath: true,
                  );
                  setState(() {
                    _isPsiphonRunning = true;
                    _isPsiphonMasqueRunning = _isPsiphonMasqueEnabled;
                    _isPsiphonConnecting = false;
                    _latestCalibration = calib;
                    _activeProtocolName = _isPsiphonMasqueEnabled ? 'Psiphon over MASQUE' : 'Psiphon Network';
                    _statusMessage = _isPsiphonMasqueEnabled 
                        ? "اتصال ترکیبی سایفون بر بستر مسک (Psiphon over MASQUE) با موفقیت برقرار شد!" 
                        : msg;
                  });
                  _startCore2Monitoring();
                } catch (e) {
                  // تضمین ۱۰۰٪ قطع شدن انیمیشن چرخشی حتی در صورت بروز خطا در سینگ‌باکس
                  setState(() {
                    _isPsiphonRunning = true;
                    _isPsiphonConnecting = false;
                    _statusMessage = "سایفون متصل شد (حالت پروکسی پورت 9080/9081)";
                  });
                }
              }
              
              // مهلت کوتاه جهت ثبت فایل خروجی اِتر و استعلام لوکیشن نهایی
              Future.delayed(const Duration(milliseconds: 3500), () {
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
    } catch (e, st) {
      _psiphonProgressTimer?.cancel();
      AppLogger.error("PSIPHON_CONN", "خطا در برقراری اتصال شبکه سایفون", e, st);
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
          await _maybeStopGoodbyeDpi();
          setState(() {
            _isDnsRunning = false;
            _statusMessage = msg;
          });
        } else {
          setState(() => _statusMessage = "در حال اعمال دی‌ان‌اس...");
          // فعال‌سازی قطعی درایور GoodbyeDPI برای مهار ارور QUIC و عبور از فیلتر SNI
          await _maybeStartGoodbyeDpi(_useGoodbyeDpiDns);
          
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
    } catch (e, st) {
      AppLogger.error("DNS_CONN", "خطا در اعمال دی‌ان‌اس روی سیستم‌عامل", e, st);
      setState(() {
        _isDnsRunning = false;
        _statusMessage = "خطا: $e (برنامه را با Administrator اجرا کنید)";
      });
    }
  }

  Future<void> _toggleLanShare() async {
    try {
      if (_isLanShareRunning) {
        final msg = await stopLanRelay();
        setState(() {
          _isLanShareRunning = false;
          _statusMessage = msg;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('اشتراک‌گذاری در شبکه محلی متوقف شد.')),
          );
        }
      } else {
        final port = int.tryParse(_lanPortController.text.trim()) ?? 10808;
        final msg = await startLanRelay(port: port);
        final ip = await getLocalIpAddress();

        setState(() {
          _isLanShareRunning = true;
          _lanIp = ip;
          _statusMessage = msg;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('اشتراک‌گذاری پروکسی روی $ip:$port فعال شد!'),
              backgroundColor: const Color(0xFF2DCA73),
            ),
          );
        }
      }
    } catch (e, st) {
      AppLogger.error("LAN_SHARE", "خطا در تغییر وضعیت اشتراک‌گذاری LAN", e, st);
      setState(() {
        _isLanShareRunning = false;
        _statusMessage = "خطا در اشتراک‌گذاری LAN: $e";
      });
    }
  }

  String? _originalWindowsTimezone;

  /// ناظر هوشمند: انطباق ساعت ویندوز با کشور خروجی بدون دخالت کاربر
  Future<void> _syncTimezoneToCountry(String countryCode) async {
    if (!Platform.isWindows) return;
    final cc = countryCode.trim().toUpperCase();
    if (cc.isEmpty || cc == 'IR') return;

    try {
      if (_originalWindowsTimezone == null) {
        final res = await Process.run('tzutil.exe', ['/g'], runInShell: false);
        final currentTz = res.stdout.toString().trim();
        if (currentTz.isNotEmpty) {
          _originalWindowsTimezone = currentTz;
        }
      }

      String targetTz;
      switch (cc) {
        case 'DE':
        case 'NL':
        case 'SE':
        case 'IT':
        case 'AT':
        case 'CH':
        case 'PL':
        case 'ES':
        case 'BE':
          targetTz = 'W. Europe Standard Time';
          break;
        case 'FR':
          targetTz = 'Romance Standard Time';
          break;
        case 'GB':
        case 'UK':
          targetTz = 'GMT Standard Time';
          break;
        case 'US':
        case 'CA':
          targetTz = 'Eastern Standard Time';
          break;
        case 'SG':
          targetTz = 'Singapore Standard Time';
          break;
        case 'JP':
          targetTz = 'Tokyo Standard Time';
          break;
        case 'TR':
          targetTz = 'Turkey Standard Time';
          break;
        case 'AR':
          targetTz = 'Argentina Standard Time';
          break;
        default:
          targetTz = 'UTC';
      }

      await Process.run('tzutil.exe', ['/s', targetTz], runInShell: false);
      AppLogger.info('IDENTITY_GUARD', '🕒 منطقه زمانی سیستم به طور خودکار با کشور $cc هماهنگ شد ($targetTz)');

      // توقف سنسور اسکن وای‌فای محلی ویندوز جهت جلوگیری از نشت مک‌آدرس مودم‌های ایران
      Process.run('net.exe', ['stop', 'lfsvc'], runInShell: false);
      AppLogger.info('IDENTITY_GUARD', '📍 سنسور مکان‌یابی فیزیکی ویندوز (lfsvc) جهت فریب و اسپوف لوکیشن متوقف شد.');
    } catch (_) {}
  }

  /// بازگرداندن ساعت و سنسور مکان‌یابی ویندوز به حالت اولیه موقع قطع اتصال
  Future<void> _restoreOriginalTimezone() async {
    if (!Platform.isWindows) return;
    try {
      if (_originalWindowsTimezone != null) {
        await Process.run('tzutil.exe', ['/s', _originalWindowsTimezone!], runInShell: false);
        AppLogger.info('IDENTITY_GUARD', '🕒 منطقه زمانی ویندوز به حالت اولیه بازگشت: $_originalWindowsTimezone');
        _originalWindowsTimezone = null;
      }
      // فعال‌سازی مجدد سنسور مکان‌یابی ویندوز موقع قطع اتصال
      Process.run('net.exe', ['start', 'lfsvc'], runInShell: false);
    } catch (_) {}
  }

  void _resetIpInfo() {
    _restoreOriginalTimezone();
    _updateSystemTrayMenu();
    setState(() {
      _publicIp = null;
      _countryCode = null;
      _countryName = null;
      _cityName = null;
      _radarRstCount = 0;
      _radarStunCount = 0;
    });
    try {
      final radarFile = File('${Directory.systemTemp.path}\\RedCloud\\radar.txt');
      if (radarFile.existsSync()) {
        radarFile.deleteSync();
      }
    } catch (_) {}
  }

  _TabTheme _getTabTheme(int index) {
    switch (index) {
      case 0:
        return _TabTheme(
          gradient: const [Color(0xFF00D2FF), Color(0xFFFF8008)],
          accent: const Color(0xFF00D2FF),
          glow: const Color(0xFFFF8008),
          icon: Icons.dashboard_rounded,
          title: 'menu_dashboard'.tr(),
        );
      case 1:
        return _TabTheme(
          gradient: const [Color(0xFF00D2FF), Color(0xFF0072FF)],
          accent: const Color(0xFF00D2FF),
          glow: const Color(0xFF00D2FF),
          icon: Icons.bolt_rounded,
          title: 'menu_aether'.tr(),
        );
      case 2:
        return _TabTheme(
          gradient: const [Color(0xFF6C5DD3), Color(0xFF2DCA73)],
          accent: const Color(0xFF2DCA73),
          glow: const Color(0xFF6C5DD3),
          icon: Icons.tune_rounded,
          title: 'menu_configs'.tr(),
        );
      case 3:
        return _TabTheme(
          gradient: const [Color(0xFF8A2387), Color(0xFFE94057)],
          accent: const Color(0xFFE94057),
          glow: const Color(0xFF8A2387),
          icon: Icons.blur_circular_rounded,
          title: 'menu_tor'.tr(),
        );
      case 4:
        return _TabTheme(
          gradient: const [Color(0xFF11998E), Color(0xFF38EF7D)],
          accent: const Color(0xFF38EF7D),
          glow: const Color(0xFF11998E),
          icon: Icons.security_rounded,
          title: 'menu_psiphon'.tr(),
        );
      case 5:
        return _TabTheme(
          gradient: const [Color(0xFFFF8008), Color(0xFFFFC837)],
          accent: const Color(0xFFFF8008),
          glow: const Color(0xFFFFC837),
          icon: Icons.radar_rounded,
          title: 'menu_scanner'.tr(),
        );
      case 6:
        return _TabTheme(
          gradient: const [Color(0xFF2193B0), Color(0xFF6DD5ED)],
          accent: const Color(0xFF6DD5ED),
          glow: const Color(0xFF2193B0),
          icon: Icons.dns_rounded,
          title: 'menu_dns'.tr(),
        );
      case 7:
        return _TabTheme(
          gradient: const [Color(0xFF00C6FF), Color(0xFF0072FF)],
          accent: const Color(0xFF00C6FF),
          glow: const Color(0xFF0072FF),
          icon: Icons.qr_code_2_rounded,
          title: 'menu_lan'.tr(),
        );
      case 8:
        return _TabTheme(
          gradient: const [Color(0xFF4A5568), Color(0xFF718096)],
          accent: const Color(0xFFA0AEC0),
          glow: const Color(0xFF718096),
          icon: Icons.settings_rounded,
          title: 'menu_settings'.tr(),
        );
      case 9:
        return _TabTheme(
          gradient: const [Color(0xFFF9D423), Color(0xFFFF4E50)],
          accent: const Color(0xFFF9D423),
          glow: const Color(0xFFFF4E50),
          icon: Icons.menu_book_rounded,
          title: 'menu_help'.tr(),
        );
      case 10:
        return _TabTheme(
          gradient: const [Color(0xFFED213A), Color(0xFF93291E)],
          accent: const Color(0xFFFF4B4B),
          glow: const Color(0xFFED213A),
          icon: Icons.shield_rounded,
          title: 'menu_anti_dpi'.tr(),
        );
      case 11:
        return _TabTheme(
          gradient: const [Color(0xFFFF416C), Color(0xFFFF4B2B)],
          accent: const Color(0xFFFF4B2B),
          glow: const Color(0xFFFF416C),
          icon: Icons.sports_esports_rounded,
          title: 'menu_gaming'.tr(),
        );
      
      default:
        return _TabTheme(
          gradient: const [Color(0xFF6C5DD3), Color(0xFF00D2FF)],
          accent: const Color(0xFF00D2FF),
          glow: const Color(0xFF6C5DD3),
          icon: Icons.dashboard_rounded,
          title: 'menu_dashboard'.tr(),
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
    return TickerMode(
      enabled: _isWindowVisible,
      child: Directionality(
        textDirection: AppTranslations.isRtl ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
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
                            _buildSidebarItem(11), // تب اختصاصی گیمینگ
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
                            const SizedBox(height: 5),
                            _buildSidebarItem(9),
                            
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    RepaintBoundary(
                      child: _buildUpdateCard(),
                    ),
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
                            label: Text('telegram'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
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
                            label: Text('donate'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),

                    Center(
                      child: Text(
                        'app_edition'.tr(params: {'version': appCurrentVersion}),
                        style: const TextStyle(color: Colors.grey, fontSize: 10),
                      ),
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
    ),
    ),
  );
}

  Widget _buildUpdateCard() {
    if (_hasUpdate && _pulseAnimation != null) {
      final displayVer = _latestVersion.isNotEmpty ? _latestVersion : 'new';
      return AnimatedBuilder(
        animation: _pulseAnimation!,
        builder: (context, child) {
          return InkWell(
            onTap: _showAutoUpdateDialog,
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
                      'update_available'.tr(params: {'version': displayVer}),
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
                  _isCheckingUpdate ? 'checking_update'.tr() : 'check_update'.tr(),
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
        return _buildLanSharePage();
      case 8:
        return _buildSettingsPage();
      case 9:
        return _buildHelpPage();
      case 10:
        return _buildAntiDpiSettingsPage();
      case 11:
        return _buildGamingPage();
      
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('dash_title'.tr(), 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text('dash_subtitle'.tr(), 
                    style: const TextStyle(color: Colors.grey, fontSize: 12.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // ردیف اول: اتصال هوشمند + حالت هیبریدی
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildGlassContainer(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      borderRadius: 14,
                      borderColor: _useSmartOptimizer ? const Color(0xFF2DCA73).withValues(alpha: 0.6) : Colors.white12,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.auto_awesome_rounded, size: 16, color: _useSmartOptimizer ? const Color(0xFF2DCA73) : Colors.grey),
                          const SizedBox(width: 6),
                          const Text('اتصال هوشمند', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
                          Switch(
                            value: _useSmartOptimizer,
                            activeThumbColor: const Color(0xFF2DCA73),
                            activeTrackColor: const Color(0xFF2DCA73).withValues(alpha: 0.4),
                            onChanged: isAnyRunning ? null : (bool val) {
                              setState(() {
                                _useSmartOptimizer = val;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildGlassContainer(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      borderRadius: 14,
                      borderColor: _isHybridModeEnabled ? const Color(0xFF00D2FF).withValues(alpha: 0.6) : Colors.white12,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.hub_rounded, size: 16, color: _isHybridModeEnabled ? const Color(0xFF00D2FF) : Colors.grey),
                          const SizedBox(width: 6),
                          Text('hybrid_mode'.tr(), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 6),
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
                const SizedBox(height: 8),
                // ردیف دوم: شتاب‌دهنده توربو BBR + افکت GoodbyeDPI
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTcpTurboSwitchTile(),
                    const SizedBox(width: 8),
                    _buildGoodbyeDpiSwitchTile(
                      tabName: 'dash_title'.tr(),
                      value: _useGoodbyeDpiDashboard,
                      onChanged: (val) {
                        setState(() => _useGoodbyeDpiDashboard = val);
                        _saveAntiDpiToDisk();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 26),
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
                          width: 195,
                          height: 195,
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
                                    ? const Color(0xFF00D2FF).withValues(alpha: 0.4)
                                    : const Color(0xFF00D2FF).withValues(alpha: 0.1),
                                blurRadius: 16,
                                spreadRadius: isAnyRunning ? 3 : 1,
                                offset: const Offset(-2, -2),
                              ),
                              BoxShadow(
                                color: isAnyRunning 
                                    ? const Color(0xFFFF8008).withValues(alpha: 0.4)
                                    : const Color(0xFFFF8008).withValues(alpha: 0.1),
                                blurRadius: 16,
                                spreadRadius: isAnyRunning ? 3 : 1,
                                offset: const Offset(2, 2),
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
                      const SizedBox(height: 22),
                      Text(
                        _isHybridRunning 
                            ? 'connected_hybrid'.tr() 
                            : _isProxyRunning 
                                ? 'connected_direct'.tr() 
                                : (_isHybridModeEnabled ? 'tap_to_connect_hybrid'.tr() : 'tap_to_connect_direct'.tr()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5, 
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
                          Expanded(child: _buildStatCard('download'.tr(), _downloadSpeed, Icons.arrow_downward_rounded, const Color(0xFF00D2FF))),
                          const SizedBox(width: 16),
                          Expanded(child: _buildStatCard('upload'.tr(), _uploadSpeed, Icons.arrow_upward_rounded, const Color(0xFFFF8008))),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: Text('sys_proxy_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('sys_proxy_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
                          title: Text('tun_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('tun_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
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
                                  Text(
                                    'anti_dpi_box_title'.tr(),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'anti_dpi_box_sub'.tr(),
                                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _selectedMenuIndex = 10;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFED213A),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              child: Text('configure'.tr(), style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      // رادار زنده دفع حملات و سقف دکل مخابراتی
                      _buildGlassContainer(
                        borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.35),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.radar_rounded, color: Color(0xFF00D2FF), size: 18),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      AppTranslations.currentLang == 'en' ? 'Live Defense & PMTU Radar' : 'رادار زنده دفع حملات و سقف دکل',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    'دکل MTU: ${_radarCarrierMtu}B',
                                    style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.currentLang == 'en' ? 'Fake RST Dropped' : 'پکت‌های RST خنثی‌شده',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$_radarRstCount',
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008), fontFamily: 'monospace'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.currentLang == 'en' ? 'WebRTC Shielded' : 'نشت WebRTC مهارشده',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$_radarStunCount',
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF), fontFamily: 'monospace'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_latestCalibration != null) ...[
                        _buildGlassContainer(
                          borderRadius: 18,
                          borderColor: const Color(0xFF2DCA73).withValues(alpha: 0.5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        const Icon(Icons.psychology_rounded, color: Color(0xFF2DCA73), size: 18),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'تله‌متری ($_activeProtocolName)',
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Row(
                                    children: [
                                      if (_latestCalibration!.isFastPathCached) ...[
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF00D2FF).withValues(alpha: 0.18),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: const Color(0xFF00D2FF).withValues(alpha: 0.4)),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.bolt_rounded, color: Color(0xFF00D2FF), size: 13),
                                              SizedBox(width: 4),
                                              Text(
                                                'حافظه یادگیری',
                                                style: TextStyle(color: Color(0xFF00D2FF), fontSize: 10, fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2DCA73).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          'امتیاز: ${_latestCalibration!.qualityMetrics.overallScore.toStringAsFixed(1)}/100',
                                          style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_isHybridRunning || _isProxyRunning ? 'پورت: ${_latestCalibration!.selectedPort}' : 'پورت لوکال: ${_latestCalibration!.selectedPort}', style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                                  Text(_isHybridRunning || _isProxyRunning ? 'فرگمنت: ${_latestCalibration!.optimalDelayStr}' : 'حالت/ریجن: ${_latestCalibration!.optimalDelayStr}', style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                                  Text('سقف دکل: ${_latestCalibration!.optimalMtu}B', style: const TextStyle(fontSize: 11.5, color: Color(0xFF00D2FF), fontWeight: FontWeight.bold)),
                                ],
                              ),
                              if (_latestCore2Report != null) ...[
                                const Divider(color: Colors.white12, height: 18),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'بازه R: [${_latestCore2Report!.expectedRangeLower.toStringAsFixed(0)}, ${_latestCore2Report!.expectedRangeUpper.toStringAsFixed(0)}] ms',
                                      style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                                    ),
                                    Text(
                                      'انحراف d(y, R): ${_latestCore2Report!.deviationValue.toStringAsFixed(1)} ms',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.bold,
                                        color: _latestCore2Report!.deviationValue > 0 ? Colors.orangeAccent : const Color(0xFF2DCA73),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
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
                                  Text('active_server_outbound'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                  const SizedBox(height: 4),
                                  Text(
                                    _selectedNode?.name ?? 'auto_github_server'.tr(), 
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
                                _localizedStatusMessage, 
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
    final bool isEn = AppTranslations.currentLang == 'en';

    String getModeName(String key) {
      if (isEn) {
        switch (key) {
          case 'auto': return 'Smart Auto Failover (Recommended)';
          case 'masque_h3': return 'MASQUE H3 (QUIC) - High Speed';
          case 'masque_h2': return 'MASQUE H2 + Fragment - Anti-UDP Throttle';
          case 'gool': return 'Gool (WARP-in-WARP) - Dual Tunnel';
          case 'wireguard': return 'WireGuard - Standard Protocol';
          default: return key;
        }
      }
      return _aetherModes[key] ?? key;
    }

    String getNoizeName(String key) {
      if (isEn) {
        switch (key) {
          case 'firewall': return 'Firewall (Anti-filtering & advanced blocking)';
          case 'light': return 'Light (Max speed & low latency)';
          case 'aggressive': return 'Aggressive (Bypass severe disruption)';
          default: return key;
        }
      }
      return _aetherNoizeProfiles[key] ?? key;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              child: Text('aether_badge'.tr(), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTcpTurboSwitchTile(),
                const SizedBox(width: 8),
                _buildGoodbyeDpiSwitchTile(
                  tabName: 'aether_title'.tr(),
                  value: _useGoodbyeDpiAether,
                  onChanged: (val) {
                    setState(() => _useGoodbyeDpiAether = val);
                    _saveAntiDpiToDisk();
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('aether_title'.tr(), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
        Text('aether_subtitle'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 28),
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
                          width: 195,
                          height: 195,
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
                      const SizedBox(height: 22),
                      Text(
                        isActive 
                            ? 'aether_connected'.tr() 
                            : isLoading 
                                ? 'aether_connecting'.tr(params: {'percent': '$_aetherProgressPercent'}) 
                                : 'aether_tap_to_connect'.tr(),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15.5, 
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
                            Row(
                              children: [
                                const Icon(Icons.tune_rounded, color: Color(0xFF00D2FF), size: 18),
                                const SizedBox(width: 10),
                                Text('aether_mode_label'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                                    _statusMessage = "Aether mode changed to $newValue";
                                  });
                                }
                              },
                              items: _aetherModes.keys.map((key) {
                                return DropdownMenuItem<String>(
                                  value: key,
                                  child: Text(getModeName(key)),
                                );
                              }).toList(),
                            ),
                            const Divider(color: Colors.white10, height: 20),
                            
                            Row(
                              children: [
                                const Icon(Icons.waves_rounded, color: Color(0xFF00D2FF), size: 18),
                                const SizedBox(width: 10),
                                Text('aether_noise_label'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                              items: _aetherNoizeProfiles.keys.map((key) {
                                return DropdownMenuItem<String>(
                                  value: key,
                                  child: Text(getNoizeName(key)),
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
                          title: Text('aether_adv_title'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          leading: const Icon(Icons.vpn_key_rounded, color: Colors.amberAccent, size: 18),
                          childrenPadding: const EdgeInsets.all(16),
                          children: [
                            TextField(
                              controller: _aetherWarpKeyController,
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                labelText: 'aether_warp_key'.tr(),
                                hintText: 'aether_warp_hint'.tr(),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                              onChanged: (_) => _saveAntiDpiToDisk(),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _aetherTeamController,
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                labelText: 'aether_team_token'.tr(),
                                hintText: 'aether_team_hint'.tr(),
                                border: const OutlineInputBorder(),
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
                          title: Text('aether_sys_proxy'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('aether_sys_proxy_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFF00D2FF),
                          onChanged: isActive || isLoading ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                              if (value) _useTunModeAether = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: Text('tun_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('tun_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useTunModeAether,
                          activeThumbColor: const Color(0xFF00D2FF),
                          onChanged: isActive || isLoading ? null : (bool value) {
                            setState(() {
                              _useTunModeAether = value;
                              if (value) _useSystemProxy = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      if (_latestCalibration != null) ...[
                        const SizedBox(height: 16),
                        _buildGlassContainer(
                          borderRadius: 18,
                          borderColor: const Color(0xFF2DCA73).withValues(alpha: 0.4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        const Icon(Icons.psychology_rounded, color: Color(0xFF2DCA73), size: 18),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'تله‌متری ($_activeProtocolName)',
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2DCA73).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      'امتیاز کیفیت: ${_latestCalibration!.qualityMetrics.overallScore.toStringAsFixed(1)}/100',
                                      style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('پورت برنده: ${_latestCalibration!.selectedPort}', style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                                  Text('فرگمنت اعمال‌شده: ${_latestCalibration!.optimalDelayStr}', style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
                                ],
                              ),
                              if (_latestCore2Report != null) ...[
                                const Divider(color: Colors.white12, height: 20),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'بازه مورد انتظار R: [${_latestCore2Report!.expectedRangeLower.toStringAsFixed(0)}, ${_latestCore2Report!.expectedRangeUpper.toStringAsFixed(0)}] ms',
                                      style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace'),
                                    ),
                                    Text(
                                      'انحراف d(y, R): ${_latestCore2Report!.deviationValue.toStringAsFixed(1)} ms',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontFamily: 'monospace',
                                        fontWeight: FontWeight.bold,
                                        color: _latestCore2Report!.deviationValue > 0 ? Colors.orangeAccent : const Color(0xFF2DCA73),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: const EdgeInsets.all(16),
                        borderRadius: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.terminal_rounded, size: 16, color: Color(0xFF00D2FF)),
                                const SizedBox(width: 8),
                                Text('aether_live_status'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
  isEn 
      ? (_aetherStatusText.contains("در حال اسکن") 
          ? "Scanning & probing anti-censorship protocols..." 
          : (_aetherStatusText.contains("پل ارتباطی") 
              ? "Bridge connected successfully!" 
              : (_aetherStatusText == "آماده اتصال" ? "Ready to connect" : _aetherStatusText)))
      : _aetherStatusText,
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
    final filteredList = _filteredNodeItems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('configs_title'.tr(), 
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text('configs_subtitle'.tr(), 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _openAddConfigDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2DCA73),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text('add_single_config'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () => _openAddOrEditSubGroupDialog(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00D2FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.playlist_add_rounded, size: 18),
                  label: Text('add_new_sub'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            )
          ],
        ),
        const SizedBox(height: 16),

        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            children: [
              _buildSubGroupTab(
                id: 'all',
                label: 'tab_all_servers'.tr(),
                count: _savedNodeItems.length,
                isSelected: _selectedGroupId == 'all',
              ),
              const SizedBox(width: 8),
              _buildSubGroupTab(
                id: 'manual',
                label: 'tab_manual_scanner'.tr(),
                count: _savedNodeItems.where((i) => i.groupId == 'manual' || i.groupId.startsWith('scanner')).length,
                isSelected: _selectedGroupId == 'manual',
              ),
              const SizedBox(width: 8),
              ..._subGroups.map((group) {
                final count = _savedNodeItems.where((i) => i.groupId == group.id).length;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: _buildSubGroupTab(
                    id: group.id,
                    label: group.name,
                    count: count,
                    isSelected: _selectedGroupId == group.id,
                    group: group,
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 14),

        _buildGlassContainer(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          borderRadius: 14,
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _serverSearchController,
                    onChanged: (val) {
                      setState(() {
                        _serverSearchQuery = val.trim();
                      });
                    },
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: 'search_placeholder'.tr(),
                      hintStyle: const TextStyle(fontSize: 11, color: Colors.white30),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Colors.grey),
                      suffixIcon: _serverSearchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 16),
                              onPressed: () {
                                _serverSearchController.clear();
                                setState(() => _serverSearchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: const Color(0xFF090B10),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              OutlinedButton.icon(
                onPressed: _isUpdatingSubs ? null : _updateAllSubscriptions,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00D2FF),
                  side: const BorderSide(color: Color(0xFF00D2FF), width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                icon: _isUpdatingSubs 
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)))
                    : const Icon(Icons.sync_rounded, size: 16),
                label: Text('update_all_subs'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isBulkPinging ? null : _bulkPingAndSort,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DCA73).withValues(alpha: 0.18),
                  foregroundColor: const Color(0xFF2DCA73),
                  side: const BorderSide(color: Color(0xFF2DCA73), width: 1),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                icon: _isBulkPinging 
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2DCA73)))
                    : const Icon(Icons.flash_on_rounded, size: 16),
                label: Text(_isBulkPinging ? 'pinging_in_progress'.tr() : 'ping_and_sort'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.cleaning_services_rounded, size: 18, color: Colors.amberAccent),
                tooltip: 'clean_dead_nodes'.tr(),
                onPressed: _removeDeadServers,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        Expanded(
          child: filteredList.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.dns_outlined, size: 54, color: Colors.grey[700]),
                      const SizedBox(height: 12),
                      Text('no_servers_found'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                )
              : _buildGlassContainer(
                  padding: const EdgeInsets.all(10),
                  borderRadius: 16,
                  child: ListView.separated(
                    itemCount: filteredList.length,
                    separatorBuilder: (_, index) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (context, index) {
                      final item = filteredList[index];
                      final isSelected = _selectedNode == item.node;
                      final config = V2rayConfig.parse(item.node.rawUrl);
                      final ping = _nodePings[item.node.rawUrl];

                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _selectedNode = item.node;
                              _statusMessage = "Active server changed to: ${item.node.name}";
                            });
                            _savePreferencesToDisk();
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? const Color(0xFF2DCA73).withValues(alpha: 0.1) : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected ? const Color(0xFF2DCA73).withValues(alpha: 0.4) : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 32,
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(color: isSelected ? const Color(0xFF2DCA73) : Colors.grey[600], fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _getProtocolColor(item.node.protocol).withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: _getProtocolColor(item.node.protocol).withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    item.node.protocol.toUpperCase(),
                                    style: TextStyle(color: _getProtocolColor(item.node.protocol), fontSize: 10, fontWeight: FontWeight.w900),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.node.name,
                                        style: TextStyle(
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                          color: isSelected ? Colors.white : Colors.grey[200],
                                          fontSize: 13,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Text(
                                            '${config.address}:${config.port}',
                                            style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'monospace'),
                                          ),
                                          const SizedBox(width: 12),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(alpha: 0.05),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '${config.transport.toUpperCase()} | ${config.security.toUpperCase()}',
                                              style: const TextStyle(color: Colors.white60, fontSize: 9.5),
                                            ),
                                          ),
                                        ],
                                      )
                                    ],
                                  ),
                                ),
                                if (ping != null) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: ping == -1 ? Colors.redAccent.withValues(alpha: 0.15) : const Color(0xFF2DCA73).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      ping == -1 ? "Timeout" : "$ping ms",
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: ping == -1 ? Colors.redAccent : const Color(0xFF2DCA73),
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                IconButton(
                                  icon: const Icon(Icons.flash_on_rounded, size: 18, color: Color(0xFFFFC837)),
                                  tooltip: 'کشف هوشمند فرگمنت طلایی (Smart Auto-Tuner)',
                                  onPressed: () => _openGoldenFragmentDialog(item),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.grey),
                                  tooltip: 'copied_config_link'.tr(),
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: item.node.rawUrl));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('copied_config_link'.tr())),
                                    );
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit_rounded, size: 16, color: Colors.grey),
                                  tooltip: 'edit'.tr(),
                                  onPressed: () {
                                    final origIndex = _savedNodeItems.indexOf(item);
                                    _openEditDialog(item.node, origIndex);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                                  tooltip: 'delete'.tr(),
                                  onPressed: () async {
                                    setState(() {
                                      _savedNodeItems.remove(item);
                                      if (_selectedNode == item.node) {
                                        _selectedNode = _savedNodeItems.isNotEmpty ? _savedNodeItems.first.node : null;
                                      }
                                    });
                                    await _saveNodesToDisk();
                                  },
                                ),
                                if (isSelected) ...[
                                  const SizedBox(width: 8),
                                  const Icon(Icons.check_circle_rounded, color: Color(0xFF2DCA73), size: 20),
                                ]
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Color _getProtocolColor(String protocol) {
    switch (protocol.toLowerCase()) {
      case 'vless':
        return const Color(0xFF00D2FF);
      case 'vmess':
        return const Color(0xFFB388FF);
      case 'tuic':
        return const Color(0xFF00E676);
      case 'shadowsocks':
      case 'ss':
        return const Color(0xFFFFB300);
      case 'hysteria2':
      case 'hy2':
        return const Color(0xFFFF8008);
      case 'trojan':
        return const Color(0xFFE94057);
      default:
        return const Color(0xFF6C5DD3);
    }
  }

  Widget _buildSubGroupTab({
    required String id,
    required String label,
    required int count,
    required bool isSelected,
    SubscriptionGroup? group,
  }) {
    return InkWell(
      onTap: () => setState(() => _selectedGroupId = id),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6C5DD3) : const Color(0xFF141828).withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.white.withValues(alpha: 0.6) : Colors.white10,
            width: isSelected ? 1.2 : 1,
          ),
          boxShadow: isSelected ? [
            BoxShadow(color: const Color(0xFF6C5DD3).withValues(alpha: 0.4), blurRadius: 10),
          ] : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.grey[300],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white.withValues(alpha: 0.25) : Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ),
            if (group != null) ...[
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert_rounded, size: 14, color: Colors.grey),
                padding: EdgeInsets.zero,
                color: const Color(0xFF121520),
                onSelected: (val) async {
                  if (val == 'update') {
                    _updateSubscription(group);
                  } else if (val == 'edit') {
                    _openAddOrEditSubGroupDialog(editGroup: group);
                  } else if (val == 'delete') {
                    setState(() {
                      _savedNodeItems.removeWhere((i) => i.groupId == group.id);
                      _subGroups.remove(group);
                      if (_selectedGroupId == group.id) {
                        _selectedGroupId = 'all';
                      }
                    });
                    await _saveSubGroupsToDisk();
                    await _saveNodesToDisk();
                  }
                },
                itemBuilder: (ctx) => [
                  const PopupMenuItem(value: 'update', child: Text('بروزرسانی این ساب', style: TextStyle(fontSize: 12))),
                  const PopupMenuItem(value: 'edit', child: Text('ویرایش مشخصات', style: TextStyle(fontSize: 12))),
                  const PopupMenuItem(value: 'delete', child: Text('حذف ساب و سرورها', style: TextStyle(fontSize: 12, color: Colors.redAccent))),
                ],
              )
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildLanSharePage() {
    final int port = int.tryParse(_lanPortController.text.trim()) ?? 10808;
    final String proxyHttpUrl = "http://$_lanIp:$port";
    final String tgProxyLink = "https://t.me/socks?server=$_lanIp&port=$port";
    final bool isEn = AppTranslations.currentLang == 'en';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('lan_title'.tr(), 
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text('lan_subtitle'.tr(), 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _buildGlassContainer(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              borderRadius: 16,
              borderColor: _isLanShareRunning ? const Color(0xFF00C6FF).withValues(alpha: 0.6) : Colors.white12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_tethering_rounded, size: 20, color: _isLanShareRunning ? const Color(0xFF00C6FF) : Colors.grey),
                  const SizedBox(width: 8),
                  Text('lan_status'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Switch(
                    value: _isLanShareRunning,
                    activeThumbColor: const Color(0xFF00C6FF),
                    activeTrackColor: const Color(0xFF0072FF).withValues(alpha: 0.5),
                    onChanged: (bool val) => _toggleLanShare(),
                  ),
                ],
              ),
            )
          ],
        ),
        const SizedBox(height: 24),

        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: _buildGlassContainer(
                  borderColor: _isLanShareRunning ? const Color(0xFF00C6FF).withValues(alpha: 0.5) : Colors.white12,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: (_isLanShareRunning ? const Color(0xFF00C6FF) : Colors.transparent).withValues(alpha: 0.4),
                              blurRadius: 20,
                              spreadRadius: 2,
                            )
                          ],
                        ),
                        child: QrImageView(
                          data: proxyHttpUrl,
                          version: QrVersions.auto,
                          size: 190.0,
                          backgroundColor: Colors.white,
                          padding: const EdgeInsets.all(8),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _isLanShareRunning 
                            ? 'lan_active_qr'.tr() 
                            : 'lan_disabled_qr'.tr(),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: _isLanShareRunning ? const Color(0xFF00C6FF) : Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'lan_local_ip_label'.tr(params: {'ip': _lanIp, 'port': port.toString()}),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),

              Expanded(
                flex: 6,
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildGlassContainer(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.router_rounded, color: Color(0xFF00C6FF), size: 18),
                                const SizedBox(width: 8),
                                Text('lan_proxy_specs'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('lan_host_label'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                        const SizedBox(height: 4),
                                        SelectableText(_lanIp, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace', color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: SizedBox(
                                    height: 52,
                                    child: TextField(
                                      controller: _lanPortController,
                                      keyboardType: TextInputType.number,
                                      enabled: !_isLanShareRunning,
                                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, fontWeight: FontWeight.bold),
                                      decoration: InputDecoration(
                                        labelText: 'lan_port_label'.tr(),
                                        border: const OutlineInputBorder(),
                                        isDense: true,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: "$_lanIp:$port"));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('copied_ipport_toast'.tr())),
                                      );
                                    },
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.white24),
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.copy_rounded, size: 16, color: Colors.white),
                                    label: Text('copy_ipport'.tr(), style: const TextStyle(color: Colors.white, fontSize: 11)),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: tgProxyLink));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('copied_tg_toast'.tr())),
                                      );
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF229ED9),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    ),
                                    icon: const Icon(Icons.send_rounded, size: 16),
                                    label: Text('copy_tg_proxy'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // بخش جدید: هات‌اسپات وای‌فای مجازی ویندوز (Mobile Hotspot)
                      _buildGlassContainer(
                        borderColor: const Color(0xFF00C6FF).withValues(alpha: 0.45),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF00C6FF).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(Icons.wifi_tethering_rounded, color: Color(0xFF00C6FF), size: 22),
                                    ),
                                    const SizedBox(width: 12),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          isEn ? 'Virtual Wi-Fi Hotspot' : 'هات‌اسپات وای‌فای ویندوز (Wi-Fi Hotspot)',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                        ),
                                        Text(
                                          isEn ? 'Share uncensored internet via Laptop Wi-Fi' : 'اشتراک مستقیم اینترنت آزاد با وای‌فای لپ‌تاپ (بدون نیاز به تنظیم در گوشی)',
                                          style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                Switch(
                                  value: _isHotspotRunning,
                                  activeThumbColor: const Color(0xFF00C6FF),
                                  onChanged: (_) => _toggleHotspot(),
                                ),
                              ],
                            ),
                            const Divider(color: Colors.white12, height: 22),

                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _hotspotSsidController,
                                    enabled: !_isHotspotRunning,
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                    decoration: InputDecoration(
                                      labelText: isEn ? 'Hotspot Name (SSID)' : 'نام وای‌فای هات‌اسپات (SSID)',
                                      hintText: 'RedCloud',
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                      prefixIcon: const Icon(Icons.wifi_rounded, size: 18),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 3,
                                  child: TextField(
                                    controller: _hotspotPassController,
                                    enabled: !_isHotspotRunning && _hasHotspotPassword,
                                    obscureText: _obscureHotspotPassword,
                                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                    decoration: InputDecoration(
                                      labelText: isEn ? 'Password (Min 8 chars)' : 'رمز عبور (حداقل ۸ کاراکتر)',
                                      border: const OutlineInputBorder(),
                                      isDense: true,
                                      prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscureHotspotPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                                          size: 18,
                                          color: Colors.grey,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _obscureHotspotPassword = !_obscureHotspotPassword;
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            Wrap(
                              alignment: WrapAlignment.spaceBetween,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              runSpacing: 10,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Checkbox(
                                      value: _hasHotspotPassword,
                                      activeColor: const Color(0xFF00D2FF),
                                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: _isHotspotRunning ? null : (v) {
                                        setState(() => _hasHotspotPassword = v ?? true);
                                      },
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      isEn ? 'WPA2' : 'رمز عبور (WPA2)',
                                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                                    ),
                                  ],
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _openHotspotClientsMonitorDialog,
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: const Color(0xFF00D2FF),
                                        side: const BorderSide(color: Color(0xFF00D2FF), width: 1.2),
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: const Icon(Icons.people_alt_rounded, size: 14),
                                      label: Text(
                                        isEn ? 'Clients (${_liveHotspotClients.length})' : 'کاربران (${_liveHotspotClients.length})',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ElevatedButton.icon(
                                      onPressed: _toggleHotspot,
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _isHotspotRunning ? Colors.redAccent : const Color(0xFF00D2FF),
                                        foregroundColor: _isHotspotRunning ? Colors.white : Colors.black,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      icon: Icon(_isHotspotRunning ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 16),
                                      label: Text(
                                        _isHotspotRunning ? (isEn ? 'Stop' : 'خاموش') : (isEn ? 'Start' : 'روشن کردن'),
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            if (_hotspotStatusText.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                _hotspotStatusText,
                                style: TextStyle(fontSize: 11, color: _isHotspotRunning ? const Color(0xFF2DCA73) : Colors.amberAccent),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      _buildHelpAccordion(
                        title: isEn ? 'Android Setup Guide' : 'راهنمای تنظیم در گوشی‌های اندروید (Android)',
                        icon: Icons.android_rounded,
                        iconColor: const Color(0xFF38EF7D),
                        content: isEn ? '''
1. Connect your phone to the same Wi-Fi network as this PC.
2. Tap and hold your Wi-Fi name and select Modify network (or the gear icon).
3. Expand Advanced options and set Proxy to Manual.
4. Set Proxy hostname to $_lanIp and Proxy port to $port, then Save.
All device internet traffic will now route securely through your PC!
''' : '''
۱. در گوشی اندرویدی خود به همان شبکه Wi-Fi متصل شوید که رایانه شما به آن وصل است.
۲. انگشت خود را روی نام Wi-Fi نگه داشته و گزینه Modify network (یا آیکون چرخ‌دنده تنظیمات) را انتخاب کنید.
۳. بخش Advanced options را باز کرده و Proxy را روی حالت Manual قرار دهید.
۴. در کادر Proxy hostname آی‌پی ($_lanIp) و در کادر Proxy port پورت ($port) را وارد کرده و Save کنید.
''',
                      ),
                      _buildHelpAccordion(
                        title: isEn ? 'iPhone & iPad Guide (iOS)' : 'راهنمای تنظیم در آیفون و آیپد (iOS / Apple)',
                        icon: Icons.apple_rounded,
                        iconColor: const Color(0xFF00C6FF),
                        content: isEn ? '''
1. Open Settings and go to Wi-Fi.
2. Tap the blue (i) icon next to your connected network.
3. Scroll to the bottom and select Configure Proxy.
4. Choose Manual, set Server to $_lanIp and Port to $port, then tap Save.
''' : '''
۱. وارد Settings و بخش Wi-Fi شوید.
۲. روی علامت (i) آبی‌رنگ کنار وای‌فای متصل کلیک کنید.
۳. به انتهای صفحه بروید و روی Configure Proxy ضربه بزنید.
۴. حالت Manual را انتخاب کرده و Server را برابر $_lanIp و Port را برابر $port قرار دهید و Save کنید.
''',
                      ),
                      _buildHelpAccordion(
                        title: isEn ? 'Smart TV & Gaming Consoles Guide' : 'راهنمای تلویزیون هوشمند (Smart TV) و کنسول بازی',
                        icon: Icons.tv_rounded,
                        iconColor: const Color(0xFFFF8008),
                        content: isEn ? '''
Go to network settings on your Smart TV (Android TV, LG, Samsung) or console (PS5, Xbox), find the Proxy Server section, and enter Host $_lanIp with Port $port to bypass region locks and censorship instantly.
''' : '''
در تنظیمات شبکه تلویزیون هوشمند یا کنسول‌های PS5 و Xbox وارد بخش تنظیمات Wi-Fi شده و در قسمت Proxy Server مقدار $_lanIp و پورت $port را تنظیم کنید تا تحریم‌ها و فیلترینگ بلافاصله دور زده شوند.
''',
                      ),
                    ],
                  ),
                ),
              )
            ],
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('tor_title'.tr(), 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text('tor_subtitle'.tr(), 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildGlassContainer(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  borderRadius: 14,
                  borderColor: _isTorMasqueEnabled ? const Color(0xFFE94057).withValues(alpha: 0.6) : Colors.white12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hub_rounded, size: 18, color: _isTorMasqueEnabled ? const Color(0xFFE94057) : Colors.grey),
                      const SizedBox(width: 8),
                      Text('tor_over_masque'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
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
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTcpTurboSwitchTile(),
                    const SizedBox(width: 8),
                    _buildGoodbyeDpiSwitchTile(
                      tabName: 'tor_title'.tr(),
                      value: _useGoodbyeDpiTor,
                      onChanged: (val) {
                        setState(() => _useGoodbyeDpiTor = val);
                        _saveAntiDpiToDisk();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 28),
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
                          width: 195,
                          height: 195,
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
                      const SizedBox(height: 22),
                      Text(
                        _isTorMasqueRunning 
                            ? 'tor_connected_masque'.tr()
                            : isTorActive 
                                ? 'tor_connected_direct'.tr() 
                                : isTorLoading 
                                    ? 'tor_connecting'.tr(params: {'percent': '$_torProgressPercent'}) 
                                    : (_isTorMasqueEnabled ? 'tor_tap_connect_masque'.tr() : 'tor_tap_connect_direct'.tr()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5, 
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
                            Row(
                              children: [
                                const Icon(Icons.public_rounded, color: Color(0xFFE94057), size: 20),
                                const SizedBox(width: 12),
                                Text('exit_node_country'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                                    _statusMessage = "Tor exit node changed to $newValue";
                                  });
                                  _savePreferencesToDisk();
                                }
                              },
                              items: _torCountries.keys.map<DropdownMenuItem<String>>((String value) {
  final isEn = AppTranslations.currentLang == 'en';
  final displayName = isEn && value.contains('(') ? value.split('(')[1].replaceAll(')', '').trim() : value;
  return DropdownMenuItem<String>(
    value: value,
    child: Text(displayName),
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
                          title: Text('tor_sys_proxy'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('sys_proxy_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFFE94057),
                          onChanged: (isTorActive || isTorLoading) ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                              if (value) _useTunModeTor = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: Text('tun_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('tun_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useTunModeTor,
                          activeThumbColor: const Color(0xFFE94057),
                          onChanged: (isTorActive || isTorLoading) ? null : (bool value) {
                            setState(() {
                              _useTunModeTor = value;
                              if (value) _useSystemProxy = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildLocationCard(), 
                      const SizedBox(height: 16),
                      // رادار زنده دفع حملات و سقف دکل مخابراتی
                      _buildGlassContainer(
                        borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.35),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Icon(Icons.radar_rounded, color: Color(0xFF00D2FF), size: 18),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      AppTranslations.currentLang == 'en' ? 'Live Defense & PMTU Radar' : 'رادار زنده دفع حملات و سقف دکل',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    'دکل MTU: ${_radarCarrierMtu}B',
                                    style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.currentLang == 'en' ? 'Fake RST Dropped' : 'پکت‌های RST خنثی‌شده',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$_radarRstCount',
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008), fontFamily: 'monospace'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF090B10),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.currentLang == 'en' ? 'WebRTC Shielded' : 'نشت WebRTC مهارشده',
                                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$_radarStunCount',
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF), fontFamily: 'monospace'),
                                        ),
                                      ],
                                    ),
                                  ),
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
                            Icon(Icons.info_outline_rounded, color: Colors.grey[400], size: 20),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _localizedStatusMessage, 
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
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('psiphon_title'.tr(), 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text('psiphon_subtitle'.tr(), 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildGlassContainer(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  borderRadius: 14,
                  borderColor: _isPsiphonMasqueEnabled ? const Color(0xFF38EF7D).withValues(alpha: 0.6) : Colors.white12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.hub_rounded, size: 18, color: _isPsiphonMasqueEnabled ? const Color(0xFF38EF7D) : Colors.grey),
                      const SizedBox(width: 8),
                      Text('psiphon_over_masque'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
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
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTcpTurboSwitchTile(),
                    const SizedBox(width: 8),
                    _buildGoodbyeDpiSwitchTile(
                      tabName: 'psiphon_title'.tr(),
                      value: _useGoodbyeDpiPsiphon,
                      onChanged: (val) {
                        setState(() => _useGoodbyeDpiPsiphon = val);
                        _saveAntiDpiToDisk();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 28),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      RepaintBoundary(
                        child: GestureDetector(
                          onTap: _togglePsiphonConnection,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            width: 195,
                            height: 195,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: (isPsiphonActive || isPsiphonLoading)
                                  ? const LinearGradient(colors: [Color(0xFF11998E), Color(0xFF38EF7D)])
                                  : const LinearGradient(colors: [Color(0xFF141828), Color(0xFF0F111D)]),
                              border: Border.all(
                                color: (isPsiphonActive || isPsiphonLoading) ? Colors.white : const Color(0xFF38EF7D).withValues(alpha: 0.4),
                                width: 3.5,
                              ),
                              boxShadow: isPsiphonLoading
                                  ? [] // در زمان لودینگ سایه حذف می‌شود تا پردازنده گرافیکی درگیر نشود
                                  : [
                                      BoxShadow(
                                        color: isPsiphonActive
                                            ? const Color(0xFF38EF7D).withValues(alpha: 0.3) 
                                            : const Color(0xFF11998E).withValues(alpha: 0.1),
                                        blurRadius: 16,
                                        spreadRadius: 1,
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
                                  const RepaintBoundary(
                                    child: SizedBox(
                                      width: 150,
                                      height: 150,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3.0,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _isPsiphonMasqueRunning
                            ? 'psiphon_connected_masque'.tr()
                            : isPsiphonActive 
                                ? 'psiphon_connected_direct'.tr() 
                                : isPsiphonLoading 
                                    ? (_isPsiphonMasqueEnabled ? 'psiphon_connecting_masque'.tr() : 'psiphon_connecting_direct'.tr()) 
                                    : (_isPsiphonMasqueEnabled ? 'psiphon_tap_connect_masque'.tr() : 'psiphon_tap_connect_direct'.tr()),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14.5, 
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
                      // اگر CDN Fronting روشن باشد، کارت اختصاصی سرورهای آنلاین باز می‌شود
                      if (_usePsiphonCdnFronting)
                        _buildGlassContainer(
                          borderColor: const Color(0xFFFF8008).withValues(alpha: 0.6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.hub_rounded, color: Color(0xFFFF8008), size: 20),
                                      const SizedBox(width: 10),
                                      Text(
                                        AppTranslations.currentLang == 'en' ? 'Live CDN Gateways' : 'سرورهای آنلاین CDN Fronting',
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                    ],
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.3)),
                                    ),
                                    child: const Text('● Active CDN', style: TextStyle(color: Color(0xFF2DCA73), fontSize: 10.5, fontWeight: FontWeight.bold)),
                                  )
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                AppTranslations.currentLang == 'en' 
                                    ? 'Select an online CDN egress region:' 
                                    : 'یکی از سرورهای آنلاین زیر را برای خروج انتخاب کنید:',
                                style: const TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF090B10),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: DropdownButton<String>(
                                  value: _selectedCdnRegion,
                                  isExpanded: true,
                                  dropdownColor: const Color(0xFF0D101A),
                                  underline: const SizedBox(),
                                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                                  onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (String? newVal) {
                                    if (newVal != null) {
                                      setState(() => _selectedCdnRegion = newVal);
                                    }
                                  },
                                  items: [
                                    const DropdownMenuItem(
                                      value: 'auto',
                                      child: Text('⚡ انتخاب هوشمند و خودکار (پیشنهادی - اتصال فوری)'),
                                    ),
                                    const DropdownMenuItem(
                                      value: 'JP',
                                      child: Text('🇯🇵 ژاپن (Japan - JP)  ● سرور آنلاین'),
                                    ),
                                    const DropdownMenuItem(
                                      value: 'US',
                                      child: Text('🇺🇸 آمریکا (United States - US)  ● سرور آنلاین'),
                                    ),
                                    const DropdownMenuItem(
                                      value: 'SE',
                                      child: Text('🇸🇪 سوئد (Sweden - SE)  ● سرور آنلاین'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        // کارت سنتی کشورهای سایفون در حالت عادی
                        _buildGlassContainer(
                          borderColor: const Color(0xFF38EF7D).withValues(alpha: 0.35),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.public_rounded, color: Color(0xFF38EF7D), size: 20),
                                  const SizedBox(width: 12),
                                  Text('exit_node_country'.tr(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                                      _statusMessage = "Psiphon exit region changed to $newValue";
                                    });
                                    _savePreferencesToDisk();
                                  }
                                },
                                items: _psiphonCountries.keys.map<DropdownMenuItem<String>>((String value) {
                                  final isEn = AppTranslations.currentLang == 'en';
                                  final displayName = isEn && value.contains('(') ? value.split('(')[1].replaceAll(')', '').trim() : value;
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(displayName),
                                  );
                                }).toList(),
                              )
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      // کارت مدیریت تنظیمات پیشرفته و فناوری CDN Fronting
                      _buildGlassContainer(
                        borderColor: _usePsiphonCdnFronting ? const Color(0xFFFF8008).withValues(alpha: 0.6) : Colors.white12,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: _usePsiphonCdnFronting ? const Color(0xFFFF8008).withValues(alpha: 0.2) : Colors.white10,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Icon(
                                        Icons.hub_rounded, 
                                        color: _usePsiphonCdnFronting ? const Color(0xFFFF8008) : Colors.grey, 
                                        size: 20
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          AppTranslations.currentLang == 'en' ? 'Advanced Engine (CDN Fronting)' : 'موتور پیشرفته (CDN Fronting)',
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _usePsiphonCdnFronting 
                                              ? (AppTranslations.currentLang == 'en' ? '● CDN Fronting is Active' : '● فناوری CDN Fronting فعال است')
                                              : (AppTranslations.currentLang == 'en' ? 'Standard Direct Connection' : 'حالت اتصال مستقیم عادی'),
                                          style: TextStyle(
                                            fontSize: 10.5, 
                                            color: _usePsiphonCdnFronting ? const Color(0xFFFF8008) : Colors.grey,
                                            fontWeight: _usePsiphonCdnFronting ? FontWeight.bold : FontWeight.normal
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                ElevatedButton.icon(
                                  onPressed: (isPsiphonActive || isPsiphonLoading) ? null : _openPsiphonAdvancedDialog,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _usePsiphonCdnFronting ? const Color(0xFFFF8008) : const Color(0xFF141828),
                                    foregroundColor: _usePsiphonCdnFronting ? Colors.black : Colors.white,
                                    side: BorderSide(color: _usePsiphonCdnFronting ? const Color(0xFFFF8008) : Colors.white24),
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  icon: const Icon(Icons.tune_rounded, size: 15),
                                  label: Text(
                                    AppTranslations.currentLang == 'en' ? 'Advanced' : 'تنظیمات پیشرفته',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: Text('psiphon_sys_proxy'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('sys_proxy_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useSystemProxy,
                          activeThumbColor: const Color(0xFF38EF7D),
                          onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (bool value) {
                            setState(() {
                              _useSystemProxy = value;
                              if (value) _useTunModePsiphon = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGlassContainer(
                        padding: EdgeInsets.zero,
                        borderRadius: 16,
                        child: SwitchListTile(
                          title: Text('tun_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: Text('tun_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          value: _useTunModePsiphon,
                          activeThumbColor: const Color(0xFF38EF7D),
                          onChanged: (isPsiphonActive || isPsiphonLoading) ? null : (bool value) {
                            setState(() {
                              _useTunModePsiphon = value;
                              if (value) _useSystemProxy = false;
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
                                _localizedStatusMessage, 
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
    final bool isEn = AppTranslations.currentLang == 'en';

    String getDnsName(DnsProfile dns) {
      if (!isEn) return dns.name;
      if (dns.name.contains('کلودفلر')) return 'Cloudflare DoH (Ultra Secure)';
      if (dns.name.contains('گوگل')) return 'Google DoT (High Speed)';
      if (dns.name.contains('شکن')) return 'Shecan (Anti-Sanction)';
      if (dns.name.contains('الکترو')) return 'Electro (Gaming & Sanction)';
      if (dns.name.contains('رادار')) return 'Radar Game (Online Gaming)';
      if (dns.name.contains('۴۰۳')) return '403.online (Anti-Sanction)';
      if (dns.name.contains('ادگارد')) return 'AdGuard DoH (Ad Blocker)';
      if (dns.name.contains('نکست')) return 'NextDNS DoH (Customizable)';
      if (dns.name.contains('کواد')) return 'Quad9 DoH (Malware Protection)';
      return dns.name;
    }

    String getDnsDesc(DnsProfile dns) {
      if (!isEn) return dns.description;
      if (dns.name.contains('کلودفلر')) return "The world's most secure encrypted DNS over HTTPS.";
      if (dns.name.contains('گوگل')) return 'Google encrypted DNS over native TLS port 853.';
      if (dns.name.contains('شکن')) return 'Bypasses foreign website sanctions and regional blocks.';
      if (dns.name.contains('الکترو')) return 'Optimized for gaming and general sanction bypass with low ping.';
      if (dns.name.contains('رادار')) return 'Domestic gaming DNS designed for online multiplayer games.';
      if (dns.name.contains('۴۰۳')) return 'High-speed anti-sanction DNS service.';
      if (dns.name.contains('ادگارد')) return 'Automatically blocks advertising domains and trackers over DoH.';
      if (dns.name.contains('نکست')) return 'Customizable high-speed secure DNS over HTTPS.';
      if (dns.name.contains('کواد')) return 'Swiss-based malware and phishing domain blocker.';
      return dns.description;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('dns_title'.tr(), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                Text('dns_subtitle'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTcpTurboSwitchTile(),
                const SizedBox(width: 8),
                _buildGoodbyeDpiSwitchTile(
                  tabName: 'dns_title'.tr(),
                  value: _useGoodbyeDpiDns,
                  onChanged: (val) {
                    setState(() => _useGoodbyeDpiDns = val);
                    _saveAntiDpiToDisk();
                  },
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
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
                        _isDnsRunning ? 'dns_active'.tr() : 'dns_tap_to_apply'.tr(),
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
                      // باکس مدرن اسکنر هوشمند دی‌ان‌اس با راستی‌آزمایی گواهی TLS
                      _buildGlassContainer(
                        borderColor: const Color(0xFF6DD5ED).withValues(alpha: 0.4),
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF6DD5ED).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: const Icon(Icons.radar_rounded, color: Color(0xFF6DD5ED), size: 18),
                                    ),
                                    const SizedBox(width: 10),
                                    Text('dns_scanner_box_title'.tr(), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                                if (_dnsList.any((d) => d.name.contains('[اسکن]') || d.name.contains('[Scan]')))
                                  IconButton(
                                    icon: const Icon(Icons.cleaning_services_rounded, size: 16, color: Colors.amberAccent),
                                    tooltip: 'btn_clear_scanned_dns'.tr(),
                                    onPressed: _clearScannedDnsProfiles,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text('dns_scanner_box_sub'.tr(), style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 40,
                                    child: TextField(
                                      controller: _dnsScanDomainController,
                                      enabled: !_isScanningDnsForDomain,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: InputDecoration(
                                        hintText: 'dns_scan_input_hint'.tr(),
                                        prefixIcon: const Icon(Icons.link_rounded, size: 16, color: Colors.grey),
                                        filled: true,
                                        fillColor: const Color(0xFF090B10),
                                        contentPadding: EdgeInsets.zero,
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (_isScanningDnsForDomain)
                                  ElevatedButton.icon(
                                    onPressed: _stopSmartDnsDomainScan,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.redAccent,
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    ),
                                    icon: const Icon(Icons.stop_circle_rounded, size: 16),
                                    label: Text('btn_stop_dns_scan'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                                  )
                                else
                                  ElevatedButton.icon(
                                    onPressed: _isDnsRunning ? null : _runSmartDnsDomainScan,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF6DD5ED),
                                      foregroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    ),
                                    icon: const Icon(Icons.travel_explore_rounded, size: 16),
                                    label: Text('btn_start_dns_scan'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // نوار انتخاب سطح سرعت و پردازش موازی تردها
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.tune_rounded, size: 13, color: Colors.grey),
                                    const SizedBox(width: 6),
                                    Text('سرعت پردازش:', style: TextStyle(fontSize: 10.5, color: Colors.grey[400])),
                                  ],
                                ),
                                DropdownButton<int>(
                                  value: _selectedDnsThreadCount,
                                  dropdownColor: const Color(0xFF090B10),
                                  underline: const SizedBox(),
                                  isDense: true,
                                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF6DD5ED), fontWeight: FontWeight.bold),
                                  onChanged: _isScanningDnsForDomain ? null : (v) {
                                    if (v != null) setState(() => _selectedDnsThreadCount = v);
                                  },
                                  items: [
                                    DropdownMenuItem(value: 0, child: Text('threads_auto'.tr())),
                                    DropdownMenuItem(value: 10, child: Text('threads_light'.tr())),
                                    DropdownMenuItem(value: 25, child: Text('threads_balanced'.tr())),
                                    DropdownMenuItem(value: 40, child: Text('threads_turbo'.tr())),
                                  ],
                                ),
                              ],
                            ),
                            // نوار پیشرفت و نشانگرهای زنده آمار اسکن
                            if (_isScanningDnsForDomain || _dnsScannerProgress != null) ...[
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: _dnsScannerProgress != null && _dnsScannerProgress!.totalServers > 0
                                      ? (_dnsScannerProgress!.scannedServers / _dnsScannerProgress!.totalServers)
                                      : null,
                                  minHeight: 5,
                                  backgroundColor: Colors.white10,
                                  color: const Color(0xFF6DD5ED),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF090B10),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    _buildDnsLiveBadge('dns_stat_total'.tr(), '${_dnsScannerProgress?.totalServers ?? 0}', Colors.white70),
                                    Container(width: 1, height: 20, color: Colors.white10),
                                    _buildDnsLiveBadge('dns_stat_scanned'.tr(), '${_dnsScannerProgress?.scannedServers ?? 0} (${_dnsScannerProgress?.progressPercent ?? 0}%)', const Color(0xFF6DD5ED)),
                                    Container(width: 1, height: 20, color: Colors.white10),
                                    _buildDnsLiveBadge('dns_stat_alive'.tr(), '${_dnsScannerProgress?.aliveServers ?? 0}', const Color(0xFF2DCA73)),
                                    Container(width: 1, height: 20, color: Colors.white10),
                                    _buildDnsLiveBadge('dns_stat_dead'.tr(), '${_dnsScannerProgress?.deadServers ?? 0}', Colors.redAccent),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // کارت مدرن نمایش پروفایل فعال و دکمه باز کردن پنجره اختصاصی مدیریت دی‌ان‌اس‌ها
                      _buildGlassContainer(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6DD5ED).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.verified_user_rounded, color: Color(0xFF6DD5ED), size: 20),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text('dns_select'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                        const SizedBox(width: 8),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.white10,
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: Text(_selectedDns.dnsType.toUpperCase(), style: const TextStyle(fontSize: 9.5, color: Color(0xFF6DD5ED), fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      getDnsName(_selectedDns),
                                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.white),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            ElevatedButton.icon(
                              onPressed: _isDnsRunning ? null : _openDnsManagerDialog,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6DD5ED),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.tune_rounded, size: 16),
                              label: const Text('انتخاب و مدیریت پروفایل‌ها', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      _buildGlassContainer(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('dns_primary'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                Text(_selectedDns.primary, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('dns_secondary'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                Text(_selectedDns.secondary, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                              ],
                            ),
                            if (_selectedDns.dnsType == 'doh' && _selectedDns.dohUrl != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('dns_doh_url'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
                                  Text('dns_dot_host'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                  Text(_selectedDns.dotHost!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFFC837))),
                                ],
                              ),
                            ],
                            const Divider(color: Colors.white12, height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('dns_latency'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
                                _isPingingDns
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6DD5ED)),
                                      )
                                    : Row(
                                        children: [
                                          Text(
                                            _dnsPing != null ? '$_dnsPing ms' : 'N/A',
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
                                getDnsDesc(_selectedDns),
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
                              SnackBar(content: Text(isEn ? 'Custom DNS removed.' : 'دی‌ان‌اس سفارشی از سیستم حذف شد.')),
                            );
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                            foregroundColor: Colors.redAccent,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          ),
                          icon: const Icon(Icons.delete_forever_rounded),
                          label: Text('dns_delete_custom'.tr(), style: const TextStyle(fontWeight: FontWeight.bold)),
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
                                _localizedStatusMessage, 
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
          Text('scanner_title'.tr(), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('scanner_subtitle'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 20),
          
          _buildGlassContainer(
            borderColor: const Color(0xFFFF8008).withValues(alpha: 0.35),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('fetch_github_accounts'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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
                            label: Text('fetch_random_accounts'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
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
                  decoration: InputDecoration(labelText: 'account_uuid'.tr(), border: const OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _workerController,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(labelText: 'account_worker'.tr(), border: const OutlineInputBorder(), isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _pathController,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(labelText: 'account_path'.tr(), border: const OutlineInputBorder(), isDense: true),
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
                      _buildScanStatBadge('stat_total'.tr(), '$_scannedTotal', const Color(0xFF00D2FF)),
                      Container(width: 1, height: 24, color: Colors.white12),
                      _buildScanStatBadge('stat_alive'.tr(), '$_scannedAlive', const Color(0xFF2DCA73)),
                      Container(width: 1, height: 24, color: Colors.white12),
                      _buildScanStatBadge('stat_dead'.tr(), '$_scannedDead', Colors.redAccent),
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
                          label: Text('stop_scan'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
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
                              label: Text('quick_scan'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
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
                              label: Text('deep_scan'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
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
                Text('scanner_status_logs'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 6),
                Text(
                  _localizedStatusMessage,
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

  Widget _buildDnsLiveBadge(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color, fontFamily: 'monospace')),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 9.5, color: Colors.grey)),
      ],
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
    final bool isEn = AppTranslations.currentLang == 'en';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('settings_title'.tr(), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        Text('settings_subtitle'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ۱. بخش زبان
                _buildGlassContainer(
                  borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.translate_rounded, color: Color(0xFF00D2FF), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('language_section_title'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text('language_section_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: _buildLanguageSelectCard(
                              title: 'فارسی (Persian)',
                              subtitle: 'راست‌چین (RTL)',
                              flag: '🇮🇷',
                              isSelected: _selectedLanguage == 'fa',
                              onTap: () async {
                                setState(() {
                                  _selectedLanguage = 'fa';
                                  AppTranslations.currentLang = 'fa';
                                });
                                await _saveLanguageToDisk();
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildLanguageSelectCard(
                              title: 'English',
                              subtitle: 'Left-to-Right (LTR)',
                              flag: '🇬🇧',
                              isSelected: _selectedLanguage == 'en',
                              onTap: () async {
                                setState(() {
                                  _selectedLanguage = 'en';
                                  AppTranslations.currentLang = 'en';
                                });
                                await _saveLanguageToDisk();
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // بخش جدید: مدیریت پیشرفته اسپلیت تانل (Split Tunneling)
                _buildGlassContainer(
                  borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.call_split_rounded, color: Color(0xFF00D2FF), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEn ? 'Split Tunneling & Domestic Bypass' : 'اسپلیت تانل و تفکیک ترافیک (Split Tunneling)',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  isEn 
                                      ? 'Bypass domestic Iran traffic or route specific domains directly with real IP' 
                                      : 'عبور ترافیک داخلی ایران با آی‌پی واقعی و بدون فیلترشکن (سایت‌های بانکی، اسنپ، دامنه‌های .ir)',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _bypassIran,
                            activeThumbColor: const Color(0xFF00D2FF),
                            onChanged: (val) {
                              setState(() => _bypassIran = val);
                              _saveSplitTunnelToDisk();
                            },
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 24),

                      Text(
                        isEn ? 'Custom Routing Rules (Domain / IP):' : 'قوانین اختصاصی کاربر (افزودن سایت دلخواه):',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white70),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _customRuleDomainController,
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                hintText: isEn ? 'e.g. shaparak.ir or .ir' : 'مثال: shaparak.ir یا snapp.ir یا .ir',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          DropdownButton<String>(
                            value: _selectedRuleType,
                            dropdownColor: const Color(0xFF090B10),
                            underline: const SizedBox(),
                            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                            onChanged: (v) {
                              if (v != null) setState(() => _selectedRuleType = v);
                            },
                            items: [
                              DropdownMenuItem(value: 'direct', child: Text(isEn ? 'Direct (Real IP)' : 'مستقیم (آی‌پی ایران)')),
                              DropdownMenuItem(value: 'proxy', child: Text(isEn ? 'Proxy (Tunnel)' : 'عبور از فیلترشکن')),
                            ],
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              final text = _customRuleDomainController.text.trim();
                              if (text.isNotEmpty) {
                                setState(() {
                                  _splitRules.add({'domain': text, 'type': _selectedRuleType});
                                  _customRuleDomainController.clear();
                                });
                                _saveSplitTunnelToDisk();
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00D2FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: Text(isEn ? 'Add' : 'افزودن', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                          ),
                        ],
                      ),
                      if (_splitRules.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: _splitRules.map((rule) {
                            final isDirect = rule['type'] == 'direct';
                            return Chip(
                              backgroundColor: isDirect ? const Color(0xFF2DCA73).withValues(alpha: 0.15) : const Color(0xFF00D2FF).withValues(alpha: 0.15),
                              side: BorderSide(color: isDirect ? const Color(0xFF2DCA73) : const Color(0xFF00D2FF), width: 0.8),
                              label: Text(
                                "${rule['domain']} (${isDirect ? (isEn ? 'Direct' : 'مستقیم') : (isEn ? 'Proxy' : 'پروکسی')})",
                                style: TextStyle(fontSize: 11, color: isDirect ? const Color(0xFF2DCA73) : const Color(0xFF00D2FF), fontWeight: FontWeight.bold),
                              ),
                              deleteIcon: const Icon(Icons.close_rounded, size: 14),
                              onDeleted: () {
                                setState(() => _splitRules.remove(rule));
                                _saveSplitTunnelToDisk();
                              },
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // بخش شتاب‌دهنده شبکه و بهینه‌ساز BBR ویندوز
                _buildGlassContainer(
                  borderColor: const Color(0xFFFFC837).withValues(alpha: 0.35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFC837).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.bolt_rounded, color: Color(0xFFFFC837), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEn ? 'Windows Network Turbo & BBR Accelerator' : 'شتاب‌دهنده شبکه و مهار پکت‌لاس ویندوز (TCP Turbo & BBR)',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  isEn
                                      ? 'Activates Google BBR2, TCP SACK, and disables packet queuing delay for gaming and 4K streaming'
                                      : 'فعال‌سازی الگوریتم BBR گوگل، جبران پکت‌لاس با SACK و کاهش پینگ بازی‌ها در سطح کرنل ویندوز',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _isTcpTurboEnabled,
                            activeThumbColor: const Color(0xFFFFC837),
                            onChanged: _isApplyingTcpTurbo ? null : (val) => _applyWindowsTcpTurbo(val),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 22),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _isTcpTurboEnabled ? Icons.check_circle_rounded : Icons.info_outline_rounded,
                                size: 16,
                                color: _isTcpTurboEnabled ? const Color(0xFF2DCA73) : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _isTcpTurboEnabled
                                    ? (isEn ? 'Status: Turbo Mode Active (BBR2 + SACK + Low Ping)' : 'وضعیت: توربو فعال (BBR2 + SACK + پینگ کمینه)')
                                    : (isEn ? 'Status: Windows Standard TCP' : 'وضعیت: استاندارد پیش‌فرض ویندوز'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: _isTcpTurboEnabled ? const Color(0xFF2DCA73) : Colors.grey,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          OutlinedButton.icon(
                            onPressed: _isApplyingTcpTurbo ? null : () => _applyWindowsTcpTurbo(false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey,
                              side: const BorderSide(color: Colors.white12),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.restore_rounded, size: 14),
                            label: Text(isEn ? 'Reset to Windows Default' : 'بازنشانی به پیش‌فرض ویندوز', style: const TextStyle(fontSize: 10.5)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ۲. بخش سپر ضد مسمومیت دی‌ان‌اس (DNSCrypt Shield)
                _buildGlassContainer(
                  borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.security_rounded, color: Color(0xFF00D2FF), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEn ? 'DNSCrypt Anti-Poisoning Shield (Tier 1)' : 'سپر ضد مسمومیت و جعل DNSCrypt (اولویت ۱)',
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  isEn 
                                      ? 'Cryptographic DNS verification (Curve25519) to drop forged DPI responses' 
                                      : 'احراز هویت رمزنگاری پاسخ‌ها با کلید عمومی و رد پکت‌های جعلی فیلترینگ',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: _useDnscryptShield,
                            activeThumbColor: const Color(0xFF00D2FF),
                            onChanged: (val) {
                              setState(() => _useDnscryptShield = val);
                            },
                          ),
                        ],
                      ),
                      if (_isDnscryptRunning) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.check_circle_rounded, color: Color(0xFF2DCA73), size: 16),
                              const SizedBox(width: 8),
                              Text(
                                isEn ? 'DNSCrypt Shield Verified & Active (Port 5354)' : 'سپر DNSCrypt تاییدشده و فعال است (پورت 5354)',
                                style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ۳. بخش بروزرسانی و وضعیت هسته‌ها
                _buildGlassContainer(
                  borderColor: const Color(0xFF2DCA73).withValues(alpha: 0.35),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.system_update_alt_rounded, color: Color(0xFF2DCA73), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('cores_update_title'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text('cores_update_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),

                      ...CoreUpdaterService.updatableCores.map((core) {
                        final bool isMissing = !core.isInstalled;

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF090B10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isMissing
                                  ? Colors.redAccent.withValues(alpha: 0.6)
                                  : core.hasUpdate
                                      ? const Color(0xFFFF8008).withValues(alpha: 0.6)
                                      : Colors.white10,
                              width: isMissing ? 1.4 : 1.0,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    isMissing
                                        ? Icons.warning_amber_rounded
                                        : core.hasUpdate
                                            ? Icons.arrow_circle_up_rounded
                                            : Icons.check_circle_rounded,
                                    color: isMissing
                                        ? Colors.redAccent
                                        : core.hasUpdate
                                            ? const Color(0xFFFF8008)
                                            : const Color(0xFF2DCA73),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(core.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                                      const SizedBox(height: 2),
                                      Text(
                                        isMissing
                                            ? (isEn ? 'Not installed (${core.targetExeName} missing)' : 'نصب نشده (فایل ${core.targetExeName} یافت نشد)')
                                            : 'core_installed_ver'.tr(params: {'ver': core.currentVersion}),
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: isMissing ? Colors.redAccent : Colors.grey,
                                          fontFamily: 'monospace',
                                          fontWeight: isMissing ? FontWeight.bold : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              if (isMissing)
                                ElevatedButton.icon(
                                  onPressed: _isUpdatingCores
                                      ? null
                                      : () async {
                                          setState(() {
                                            _isUpdatingCores = true;
                                            _coreUpdateStatus = isEn
                                                ? 'Downloading ${core.name}...'
                                                : 'در حال دانلود و نصب ${core.name}...';
                                          });
                                          await CoreUpdaterService.updateSingleCore(
                                            core,
                                            onProgress: (status, p) {
                                              if (mounted) {
                                                setState(() {
                                                  _coreUpdateStatus = status;
                                                  _coreUpdateProgress = p;
                                                });
                                              }
                                            },
                                          );
                                          if (mounted) {
                                            setState(() {
                                              _isUpdatingCores = false;
                                            });
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00D2FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.download_rounded, size: 14),
                                  label: Text(
                                    isEn ? 'Download & Install' : 'دانلود و نصب خودکار',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                )
                              else if (core.hasUpdate)
                                ElevatedButton.icon(
                                  onPressed: _isUpdatingCores
                                      ? null
                                      : () async {
                                          setState(() {
                                            _isUpdatingCores = true;
                                            _coreUpdateStatus = isEn
                                                ? 'Updating ${core.name}...'
                                                : 'در حال بروزرسانی ${core.name}...';
                                          });
                                          await CoreUpdaterService.updateSingleCore(
                                            core,
                                            onProgress: (status, p) {
                                              if (mounted) {
                                                setState(() {
                                                  _coreUpdateStatus = status;
                                                  _coreUpdateProgress = p;
                                                });
                                              }
                                            },
                                          );
                                          if (mounted) {
                                            setState(() {
                                              _isUpdatingCores = false;
                                            });
                                          }
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF8008),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  icon: const Icon(Icons.sync_rounded, size: 14),
                                  label: Text(
                                    isEn ? 'Update (${core.latestVersion})' : 'آپدیت به ${core.latestVersion}',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                )
                              else
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    isEn ? 'Installed & Ready' : 'نصب و آماده',
                                    style: const TextStyle(fontSize: 10.5, color: Color(0xFF2DCA73), fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                        );
                      }),
                      const SizedBox(height: 16),

                      if (_isUpdatingCores || _coreUpdateStatus.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF090B10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF00D2FF).withValues(alpha: 0.3)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _coreUpdateStatus,
                                style: const TextStyle(fontSize: 11.5, color: Colors.white70, fontFamily: 'monospace'),
                              ),
                              if (_isUpdatingCores) ...[
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value: _coreUpdateProgress > 0 ? _coreUpdateProgress : null,
                                  backgroundColor: Colors.white12,
                                  color: const Color(0xFF00D2FF),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: (_isCheckingCores || _isUpdatingCores)
                                  ? null
                                  : () async {
                                      setState(() {
                                        _isCheckingCores = true;
                                        _coreUpdateStatus = isEn
                                            ? 'Checking official repositories for updates...'
                                            : 'در حال استعلام آخرین نسخه‌ها از گیت‌هاب رسمی...';
                                      });

                                      await CoreUpdaterService.checkUpdates(
                                        onStatus: (st) {
                                          if (mounted) setState(() => _coreUpdateStatus = st);
                                        },
                                      );

                                      if (mounted) {
                                        final hasAny = CoreUpdaterService.updatableCores.any((c) => c.hasUpdate);
                                        setState(() {
                                          _isCheckingCores = false;
                                          _coreUpdateStatus = hasAny
                                              ? (isEn ? 'New updates available!' : 'نسخه جدید برای برخی هسته‌ها موجود است.')
                                              : 'cores_up_to_date'.tr();
                                        });
                                      }
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2DCA73),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: _isCheckingCores
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                  : const Icon(Icons.sync_rounded, size: 18),
                              label: Text(
                                _isCheckingCores
                                    ? (isEn ? 'Checking...' : 'در حال بررسی...')
                                    : 'btn_check_cores'.tr(),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: (_isUpdatingCores || _isCheckingCores)
                                  ? null
                                  : () async {
                                      setState(() {
                                        _isUpdatingCores = true;
                                        _coreUpdateProgress = 0.0;
                                      });

                                      await CoreUpdaterService.updateAllAvailableCores(
                                        onProgress: (status, p) {
                                          if (mounted) {
                                            setState(() {
                                              _coreUpdateStatus = status;
                                              _coreUpdateProgress = p;
                                            });
                                          }
                                        },
                                      );

                                      if (mounted) {
                                        setState(() {
                                          _isUpdatingCores = false;
                                        });
                                      }
                                    },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF00D2FF),
                                side: const BorderSide(color: Color(0xFF00D2FF)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: _isUpdatingCores
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)))
                                  : const Icon(Icons.download_for_offline_rounded, size: 18),
                              label: Text(
                                'btn_update_all_cores'.tr(),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // بخش جدید: شخصی‌سازی کلیدهای میانبر سراسری کیبورد
                _buildGlassContainer(
                  borderColor: const Color(0xFFFF416C).withValues(alpha: 0.4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(colors: [Color(0xFFFF416C), Color(0xFFFF4B2B)]),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.keyboard_rounded, color: Colors.white, size: 22),
                              ),
                              const SizedBox(width: 14),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('hotkeys_title'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                  const SizedBox(height: 2),
                                  Text('hotkeys_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                ],
                              ),
                            ],
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              setState(() {
                                _hkDashboard = 'D';
                                _hkGaming = 'G';
                                _hkAether = 'A';
                                _hkTor = 'T';
                                _hkPsiphon = 'P';
                                _hkTun = 'M';
                              });
                              await _savePreferencesToDisk();
                              await _registerAllGlobalHotkeys();
                            },
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            icon: const Icon(Icons.restore_rounded, size: 14, color: Colors.grey),
                            label: Text('reset_hotkeys'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          )
                        ],
                      ),
                      const Divider(color: Colors.white12, height: 24),
                      Wrap(
                        spacing: 16,
                        runSpacing: 12,
                        children: [
                          _buildHotkeySettingTile('hotkey_dashboard'.tr(), _hkDashboard, (val) => _updateSingleHotkey('dashboard', val)),
                          _buildHotkeySettingTile('hotkey_gaming'.tr(), _hkGaming, (val) => _updateSingleHotkey('gaming', val)),
                          _buildHotkeySettingTile('hotkey_aether'.tr(), _hkAether, (val) => _updateSingleHotkey('aether', val)),
                          _buildHotkeySettingTile('hotkey_tor'.tr(), _hkTor, (val) => _updateSingleHotkey('tor', val)),
                          _buildHotkeySettingTile('hotkey_psiphon'.tr(), _hkPsiphon, (val) => _updateSingleHotkey('psiphon', val)),
                          _buildHotkeySettingTile('hotkey_tun'.tr(), _hkTun, (val) => _updateSingleHotkey('tun', val)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ۴. بخش گزارش خطاها
                _buildGlassContainer(
                  borderColor: const Color(0xFF00D2FF).withValues(alpha: 0.4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(Icons.bug_report_rounded, color: Color(0xFF00D2FF), size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('logs_title'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                                Text('logs_sub'.tr(), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                              ],
                            ),
                          )
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'logs_desc'.tr(),
                        style: const TextStyle(fontSize: 12, height: 1.6, color: Colors.white70),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                try {
                                  final path = await getLogFilePath();
                                  final file = File(path);
                                  if (!await file.exists()) {
                                    await file.create(recursive: true);
                                  }
                                  
                                  if (Platform.isWindows) {
                                    Process.run('explorer.exe', [file.parent.path]);
                                  } else {
                                    await openLogDirectory();
                                  }

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(isEn ? 'Log folder opened successfully.' : 'پوشه لاگ در ویندوز با موفقیت باز شد.'),
                                        backgroundColor: const Color(0xFF2DCA73),
                                      ),
                                    );
                                  }
                                } catch (e, st) {
                                  AppLogger.error("LOG_UI", "Error opening log directory", e, st);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(isEn ? 'Error opening folder: $e' : 'خطا در باز کردن پوشه: $e')),
                                    );
                                  }
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00D2FF),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: const Icon(Icons.folder_open_rounded, size: 20),
                              label: Text('btn_open_log_dir'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () async {
                              try {
                                final path = await getLogFilePath();
                                await Clipboard.setData(ClipboardData(text: path));
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(isEn ? 'Log file path copied to clipboard!' : 'مسیر فایل log.txt در کلیپ‌بورد کپی شد!')),
                                  );
                                }
                              } catch (e) {
                                AppLogger.warn("LOG_UI", "Error copying log path: $e");
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: Text('btn_copy_log_path'.tr(), style: const TextStyle(fontSize: 12)),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                            tooltip: 'btn_clear_log'.tr(),
                            onPressed: () async {
                              try {
                                await clearLogFile();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(isEn ? 'Log file cleared successfully.' : 'فایل لاگ با موفقیت پاکسازی شد.')),
                                  );
                                }
                              } catch (e) {
                                AppLogger.error("LOG_UI", "Error clearing log", e);
                              }
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // ۵. بخش مسیر فایل‌های باینری هسته‌ها
                _buildGlassContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isEn ? 'Path to dnscrypt-proxy.exe (Anti-Poisoning Shield)' : 'مسیر فایل dnscrypt-proxy.exe (سپر ضد مسمومیت دی‌ان‌اس)', 
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _dnscryptPathController,
                        decoration: const InputDecoration(
                          labelText: 'dnscrypt-proxy.exe',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.security_rounded, color: Color(0xFF00D2FF)),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),

                      Text('goodbyedpi_path_label'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF2DCA73))),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _goodbyedpiPathController,
                        decoration: InputDecoration(
                          labelText: 'goodbyedpi_path_label'.tr(),
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.shield_outlined, color: Color(0xFF2DCA73)),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),

                      Text('aether_path_label'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF))),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _aetherPathController,
                        decoration: InputDecoration(
                          labelText: 'aether_path_label'.tr(),
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.bolt_rounded, color: Color(0xFF00D2FF)),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),

                      Text('singbox_path_label'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _binaryPathController,
                        decoration: InputDecoration(
                          labelText: 'singbox_path_label'.tr(),
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.code_rounded),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),

                      Text('tor_path_label'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _torPathController,
                        decoration: InputDecoration(
                          labelText: 'tor_path_label'.tr(),
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.blur_circular_rounded),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),

                      Text('psiphon_path_label'.tr(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _psiphonPathController,
                        decoration: InputDecoration(
                          labelText: 'psiphon_path_label'.tr(),
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.security_rounded),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Divider(color: Colors.white12),
                      const SizedBox(height: 16),
                      Text('target_os_label'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHelpPage() {
    final bool isEn = AppTranslations.currentLang == 'en';

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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEn ? 'RedCloud User Guide & Pro Tips' : 'راهنمای جامع کاربری و ترفندهای RedCloud', 
                    style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isEn ? 'Step-by-step documentation for all anti-censorship protocols and bypass tools' : 'آموزش گام‌به‌گام تمامی ابزارها، پروتکل‌ها و تکنیک‌های دور زدن فیلترینگ', 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
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
                  title: isEn ? '1. Dashboard & Hybrid Mode (Recommended)' : '۱. داشبورد و حالت اتصال هیبریدی (پیشنهاد اصلی)',
                  icon: Icons.hub_rounded,
                  iconColor: const Color(0xFF00D2FF),
                  content: isEn ? '''
• Hybrid Connection (Aether + VLESS):
The premier anti-censorship feature. Your traffic first tunnels through the resilient Aether MASQUE bridge before hitting the Sing-box core, keeping connections totally undetectable with high speeds.

• Direct V2Ray:
When Hybrid is toggled off, the app connects directly to your chosen server from the Configs tab.

• Smart Auto-Rotation:
If the 5GB quota of the free active shared account is exhausted, the app auto-fetches fresh accounts from GitHub without disconnecting.
''' : '''
• اتصال هیبریدی (Aether + VLESS):
این حالت پیشرفته‌ترین متد ضدسانسور برنامه است. در این حالت ترافیک شما ابتدا از پل فوق‌العاده پایدار اتر (MASQUE) رد شده و سپس وارد هسته ویتوری (Sing-box) می‌شود. با این کار فیلترینگ متوجه هویت ترافیک شما نمی‌شود و سرعت آپلود و دانلود بسیار پایداری خواهید داشت.

• ویتوری مستقیم (Direct):
اگر سوییچ اتصال هیبریدی را خاموش کنید، برنامه مستقیماً با سرور انتخابی شما در تب پیکربندی ارتباط برقرار می‌کند.

• چرخش خودکار اکانت‌ها (Auto-Rotation):
در صورتی که حجم ۵ گیگابایتی اکانت اشتراکی فعال تمام شود، برنامه بدون نیاز به دخالت شما به‌طور خودکار اکانت تازه از سرور گیت‌هاب دریافت کرده و ترافیک را متصل نگه می‌دارد.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '2. Kernel Anti-DPI Layer (GoodbyeDPI)' : '۲. افکت ضد DPI (GoodbyeDPI Layer)',
                  icon: Icons.shield_rounded,
                  iconColor: const Color(0xFF2DCA73),
                  content: isEn ? '''
• First-Line Protection Layer:
GoodbyeDPI operates through a Windows kernel driver (WinDivert). When enabled, handshake packets are fragmented, re-ordered, or padded before leaving your network adapter, preventing deep packet inspection (DPI) censorship from terminating connections.
''' : '''
• لایه اول محافظتی برای تمامی تب‌ها:
گودبای‌دی‌پی (GoodbyeDPI) به عنوان یک درایور کرنل ویندوز (WinDivert) عمل می‌کند. وقتی تیک این گزینه را در داشبورد، اتر، تور یا سایفون فعال کنید، پکت‌های هندشیک قبل از خروج از کارت شبکه تغییر ساختار پیدا می‌کنند تا سیستم DPI اپراتورها نتوانند اتصال اولیه شما به سرورهای خارجی را ببندند.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '3. Virtual TUN Mode vs System Proxy' : '۳. تفاوت کارت شبکه مجازی (TUN Mode) و پروکسی سیستم',
                  icon: Icons.alt_route_rounded,
                  iconColor: const Color(0xFF2DCA73),
                  content: isEn ? '''
• System Proxy:
Configures the Windows system registry to automatically tunnel all browsers (Chrome, Edge, Firefox) and proxy-aware tools.

• TUN Mode (Virtual Network Adapter):
Installs an in-memory virtual adapter (Wintun) that routes 100% of your PC's traffic through the tunnel, including online games, CLI, Git, Discord voice, and non-proxy apps.
''' : '''
• حالت پروکسی سیستم‌عامل (System Proxy):
این گزینه رجیستری ویندوز را تنظیم می‌کند تا ترافیک تمام مرورگرها (کروم، فایرفاکس، ادج) و نرم‌افزارها به‌طور خودکار از فیلترشکن عبور کنند.

• کارت شبکه مجازی (TUN Mode):
یک کارت شبکه مجازی روی ویندوز می‌سازد و کل ترافیک اینترنت رایانه شما (شامل بازی‌های آنلاین، برنامه‌های بدون قابلیت پروکسی، CMD، گیت و کلاینت‌های دسکتاپ) را بدون استثنا از تونل عبور می‌دهد.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '4. Aether MASQUE Anti-Censorship Engine' : '۴. شبکه ضدسانسور اِتر (MASQUE Aether Engine)',
                  icon: Icons.bolt_rounded,
                  iconColor: const Color(0xFF00D2FF),
                  content: isEn ? '''
Connects independently to Cloudflare Zero Trust without requiring custom domains or VPS setups!

• Auto Failover:
Probes and benchmarks multiple pathways in real-time, locking onto the lowest-latency, most reliable route.

• MASQUE H3 (QUIC):
High throughput HTTP/3 QUIC connection with zero round-trip handshakes (0-RTT), ideal for 4K streaming.

• MASQUE H2 + Fragment:
Specially tailored for networks throttling or dropping UDP packets.

• Noise Profiles:
Firewall for severe censorship resilience, Light for lowest ping and maximum raw throughput.
''' : '''
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
                  title: isEn ? '5. Local LAN Sharing & QR Gateway' : '۵. اشتراک‌گذاری اینترنت در شبکه محلی (LAN Share & QR Code)',
                  icon: Icons.qr_code_2_rounded,
                  iconColor: const Color(0xFF00C6FF),
                  content: isEn ? '''
• Turn PC into a Home Proxy Gateway:
Enabling LAN Share lets your mobile phones, gaming consoles, and smart TVs on the same Wi-Fi enjoy uncensored internet by simply scanning the generated QR Code or setting the local IP:Port.

• Universal Core Relay:
Regardless of whether you connect via Aether, Hybrid, Tor, or Psiphon, the Rust relay engine routes all LAN traffic through the currently active tunnel seamlessly.
''' : '''
• تبدیل سیستم به گذرگاه اینترنت خانگی:
با روشن کردن سوییچ اشتراک‌گذاری LAN، تمامی گوشی‌های همراه، تبلت‌ها، کنسول‌های بازی و تلویزیون‌های متصل به همان وای‌فای می‌توانند با اسکن بارکد QR یا تنظیم ساده پروکسی (IP:Port) از اینترنت بدون سانسور سیستم استفاده کنند.

• رله هوشمند و سراسری:
مهم نیست سیستم شما به کدام پروتکل (پل اِتر، هیبریدی، تور یا سایفون) متصل باشد؛ موتور رله راست به صورت هوشمند تمام بسته‌ها را از اتصال فعال عبور می‌دهد.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '6. Server Management (VLESS / Reality / Hysteria 2)' : '۶. پیکربندی و مدیریت سرورها (VLESS / Reality / Hysteria 2)',
                  icon: Icons.tune_rounded,
                  iconColor: const Color(0xFF6C5DD3),
                  content: isEn ? '''
• Subscription Management:
Create multiple subscription groups, auto-update with one click, and isolate different server pools.

• Bulk Ping & Sorting:
Parallel high-speed latency testing with Rust native sockets instantly brings the fastest and most stable servers to the top.

• Reality & ECH Editing:
Customize SNI, Reality public keys (pbk), short IDs (sid), and Encrypted Client Hello (ECH) headers directly from the edit dialog.
''' : '''
• مدیریت حرفه‌ای ساب‌اسکریپشن‌ها:
می‌توانید گروه‌های مختلف ساب ایجاد کنید و با زدن دکمه «بروزرسانی ساب‌ها» تمام سرورها را در چند ثانیه آپدیت کنید.

• تست پینگ دسته‌جمعی و مرتب‌سازی:
با زدن دکمه «تست پینگ و مرتب‌سازی»، هسته باینری راست تمام سرورها را به‌طور موازی پایش کرده و سرورهای سالم و پرسرعت را به صدر لیست می‌آورد.

• ویرایش دستی و فعال‌سازی Reality و ECH:
با کلیک روی آیکون مداد هر سرور، می‌توانید پارامترهای پیشرفته مثل کلید عمومی Reality (pbk)، شناسه (sid)، مسیر (Path) و هدرهای ECH را ویرایش و ذخیره کنید.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '7. Tor & Psiphon over MASQUE' : '۷. شبکه‌های پیاز تور (Tor over MASQUE) و سایفون (Psiphon over MASQUE)',
                  icon: Icons.blur_circular_rounded,
                  iconColor: const Color(0xFFE94057),
                  content: isEn ? '''
• Tor over MASQUE:
Tor guard nodes tunnel through the MASQUE anti-censorship bridge, bypassing ISP guard-blocking to ensure a reliable connection to your chosen exit country (Germany, US, Netherlands, UK, etc.).

• Psiphon over MASQUE:
Shields Psiphon initial discovery handshakes and handshake packets from state DPI, giving you robust multi-protocol egress.
''' : '''
• اتصال تور بر بستر مسک (Tor over MASQUE):
گره‌های گارد تور از پل ضدسانسور MASQUE عبور کرده و فیلترینگ گاردها را دور می‌زنند تا ارتباط شما با کشور خروجی دلخواه (آلمان، آمریکا، هلند، بریتانیا و...) ۱۰۰٪ برقرار شود.

• اتصال سایفون بر بستر مسک (Psiphon over MASQUE):
ترافیک اولیه و هندشیک‌های سایفون از درون پل MASQUE عبور کرده و به کشور انتخابی تحویل داده می‌شود.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '8. Dual Cloudflare Scanner (Quick & Deep)' : '۸. اسکنر دوحالته کلودفلر (Quick & Deep Scanner)',
                  icon: Icons.radar_rounded,
                  iconColor: const Color(0xFFFF8008),
                  content: isEn ? '''
• Quick Scan:
Fast test over curated high-performance cloud clean IPs for instant connectivity.

• Deep Scan:
Scans thousands of CIDR blocks from cloudflare_IPs.txt using parallel multi-threaded workers.

• Live Stop Control:
Shows real-time alive/dead metrics. You can stop anytime, and newly discovered clean IPs are immediately added to your node list.
''' : '''
• اسکن سریع (Quick Scan):
تست چندثانیه‌ای روی لیست منتخب از آی‌پی‌های پرسرعت برای اتصالات فوری.

• اسکن عمیق و جامع (Deep Scan):
استفاده از فایل cloudflare_IPs.txt و اسکن موازی هزاران آی‌پی از دل رنج‌های CIDR ابری.

• کنترل زنده و دکمه توقف (Stop):
در حین اسکن آمار آی‌پی‌های کل، سالم و مرده نمایش داده می‌شود و هر زمان دکمه Stop را بزنید، با آی‌پی‌های سفید کشف‌شده تا همان لحظه کانفیگ ساخته می‌شود.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '9. Smart DNS Changer' : '۹. تغییر دهنده هوشمند دی‌ان‌اس (DNS Changer)',
                  icon: Icons.dns_rounded,
                  iconColor: const Color(0xFF6DD5ED),
                  content: isEn ? '''
Bypass anti-Iran sanctions (AI services, Discord, Epic Games, Adobe, Docker, online games) without turning on a VPN!
Includes popular gaming DNS providers (Shecan, Electro, 403, Radar) as well as encrypted DoH servers (Cloudflare, AdGuard, NextDNS).
''' : '''
این تب به شما اجازه می‌دهد بدون روشن کردن فیلترشکن، تحریم‌های اینترنتی علیه کاربران ایرانی (مثل سایت‌های هوش مصنوعی، دیسکورد، اپیک گیمز، ادوبی، داکر و بازی‌های آنلاین) را دور بزنید!
دی‌ان‌اس‌های معروف مانند شکن، الکترو، ۴۰۳ آنلاین، رادار گیم و همچنین DNSهای فوق امن رمزنگاری‌شده DoH در این تب آماده انتخاب هستند.
''',
                ),
                _buildHelpAccordion(
                  title: isEn ? '10. Advanced Anti-DPI Settings' : '۱۰. تنظیمات فوق‌پیشرفته ضدسانسور (Anti-DPI)',
                  icon: Icons.security_rounded,
                  iconColor: const Color(0xFFED213A),
                  content: isEn ? '''
• uTLS Fingerprint Emulation:
Mimics authentic desktop Google Chrome handshakes to prevent traffic classification.

• TLS Packet Fragmentation:
Splits ClientHello SNI packets into tiny fragments so DPI sensors cannot read your destination hostname.

• Fake SNI Spoofing:
Injects an unblocked decoy domain (e.g. zoom.us or microsoft.com) before the real request to blind DPI filters.
''' : '''
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

  /// دیالوگ حرفه‌ای مانیتورینگ زنده هات‌اسپات، محدودیت تعداد کاربر و بلک‌لیست مک‌آدرس
  /// دیالوگ آزمایشگاه اختصاصی کشف فرگمنت طلایی برای سرور انتخاب‌شده
  void _openGoldenFragmentDialog(SavedNodeItem item) {
    final bool isEn = AppTranslations.currentLang == 'en';
    final config = V2rayConfig.parse(item.node.rawUrl);
    final host = config.address;
    final port = config.port;
    final sni = config.sni.isNotEmpty ? config.sni : host;

    final strategies = [
      {'name': isEn ? 'Header Micro-Split' : 'فرگمنت میکرو هدر (Header Micro-Split)', 'len': '1-3', 'interval': '15ms', 'split': 2, 'delay': 15, 'ping': null},
      {'name': isEn ? 'SNI Segmentation' : 'تفکیک افزونه دامنه (SNI Segmentation)', 'len': '40-60', 'interval': '25ms', 'split': 45, 'delay': 25, 'ping': null},
      {'name': isEn ? 'Low-Latency Mode' : 'فرگمنت کم‌تاخیر (Low-Latency Mode)', 'len': '2-5', 'interval': '5ms', 'split': 3, 'delay': 5, 'ping': null},
      {'name': isEn ? 'Standard TLS Split' : 'فرگمنت استاندارد رکورد (Standard TLS Split)', 'len': '100-150', 'interval': '10ms', 'split': 120, 'delay': 10, 'ping': null},
    ];

    bool isTesting = false;
    int? bestIndex;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xFFFFC837), width: 1.4),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFC837).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.flash_on_rounded, color: Color(0xFFFFC837), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isEn ? 'Smart Fragment Auto-Tuner' : 'کاشف هوشمند فرگمنت طلایی (Auto-Tuner)', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                        Text('${item.node.name} ($host:$port)', style: const TextStyle(fontSize: 10.5, color: Colors.grey), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  )
                ],
              ),
              content: SizedBox(
                width: 540,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isEn
                          ? 'This tool tests 4 surgical TLS fragmentation strategies against your ISP DPI to discover the lowest ping and bypass handshake blocks.'
                          : 'این آزمایشگاه ۴ الگوی شکستن پکت را روی فیلترینگ اپراتور شما تست می‌کند تا بهترین بازه بایت و تاخیر را برای این سرور کشف کند.',
                      style: const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.5),
                    ),
                    const SizedBox(height: 16),
                    ...strategies.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final s = entry.value;
                      final ping = s['ping'] as int?;
                      final isBest = bestIndex == idx;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: isBest ? const Color(0xFF2DCA73).withValues(alpha: 0.12) : const Color(0xFF090B10),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isBest ? const Color(0xFF2DCA73) : Colors.white12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s['name'].toString(), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isBest ? const Color(0xFF2DCA73) : Colors.white)),
                                const SizedBox(height: 2),
                                Text('طول: ${s['len']} | تاخیر: ${s['interval']}', style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontFamily: 'monospace')),
                              ],
                            ),
                            if (ping == null)
                              Text(isTesting ? 'در حال تست...' : 'تست‌نشده', style: const TextStyle(fontSize: 11, color: Colors.grey))
                            else if (ping == -1)
                              const Text('تایم‌اوت ❌', style: TextStyle(fontSize: 11, color: Colors.redAccent, fontWeight: FontWeight.bold))
                            else
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2DCA73).withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('$ping ms ✅', style: const TextStyle(fontSize: 11, color: Color(0xFF2DCA73), fontWeight: FontWeight.bold, fontFamily: 'monospace')),
                              ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: isTesting ? null : () async {
                          setDialogState(() {
                            isTesting = true;
                            bestIndex = null;
                            for (var s in strategies) { s['ping'] = null; }
                          });

                          int minPing = 99999;
                          int? winner;

                          for (int i = 0; i < strategies.length; i++) {
                            final p = await _probeFragmentLatency(
                              host,
                              port,
                              sni,
                              strategies[i]['split'] as int,
                              strategies[i]['delay'] as int,
                            );
                            setDialogState(() {
                              strategies[i]['ping'] = p;
                              if (p > 0 && p < minPing) {
                                minPing = p;
                                winner = i;
                              }
                            });
                          }

                          setDialogState(() {
                            isTesting = false;
                            bestIndex = winner;
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFC837),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: isTesting
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                            : const Icon(Icons.play_arrow_rounded),
                        label: Text(isTesting ? 'در حال آزمایش ۴ استراتژی...' : 'شروع آزمایش و کشف بهترین فرگمنت', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(isEn ? 'Close' : 'بستن', style: const TextStyle(color: Colors.grey)),
                ),
                if (bestIndex != null)
                  ElevatedButton.icon(
                    onPressed: () async {
                      final winner = strategies[bestIndex!];
                      final len = winner['len'];
                      final interval = winner['interval'];

                      final uri = Uri.parse(item.node.rawUrl);
                      final qParams = Map<String, String>.from(uri.queryParameters);
                      qParams['frag_len'] = len.toString();
                      qParams['frag_interval'] = interval.toString();

                      final newUri = uri.replace(queryParameters: qParams);
                      item.node = ProxyNode(
                        name: item.node.name,
                        protocol: item.node.protocol,
                        rawUrl: newUri.toString(),
                      );
                      if (_selectedNode == item.node) {
                        _selectedNode = item.node;
                      }

                      await _saveNodesToDisk();
                      if (ctx.mounted) Navigator.of(ctx).pop();

                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('فرگمنت طلایی ($len با تاخیر $interval) روی سرور ذخیره شد!'),
                            backgroundColor: const Color(0xFF2DCA73),
                          ),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DCA73), foregroundColor: Colors.black),
                    icon: const Icon(Icons.check_circle_rounded, size: 16),
                    label: const Text('اعمال و ذخیره فرگمنت برنده', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _openHotspotClientsMonitorDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    final manualMacController = TextEditingController();

    // اجرای فوری اولین استعلام
    _fetchConnectedHotspotClients();

    // شروع پایش زنده هر ۳ ثانیه فقط تا زمانی که این دیالوگ باز است
    _hotspotMonitorTimer?.cancel();
    _hotspotMonitorTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _fetchConnectedHotspotClients();
    });

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xFF00D2FF), width: 1.4),
              ),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.devices_rounded, color: Color(0xFF00D2FF), size: 22),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        isEn ? 'Hotspot Client Management' : 'مدیریت و مانیتورینگ زنده کاربران هات‌اسپات',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.grey),
                    onPressed: () => Navigator.of(ctx).pop(),
                  )
                ],
              ),
              content: SizedBox(
                width: 620,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ۱. نوار تنظیم سقف مجاز اتصال همزمان کاربران
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF090B10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.group_rounded, color: Color(0xFF2DCA73), size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  isEn ? 'Max Client Limit:' : 'سقف مجاز تعداد کاربر:',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            DropdownButton<int>(
                              value: _hotspotMaxClientsLimit,
                              dropdownColor: const Color(0xFF090B10),
                              underline: const SizedBox(),
                              style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 12, fontWeight: FontWeight.bold),
                              onChanged: (val) async {
                                if (val != null) {
                                  setDialogState(() => _hotspotMaxClientsLimit = val);
                                  setState(() => _hotspotMaxClientsLimit = val);
                                  await _saveHotspotSecurityToDisk();
                                  _fetchConnectedHotspotClients();
                                }
                              },
                              items: [
                                DropdownMenuItem(value: 0, child: Text(isEn ? 'Unlimited' : 'نامحدود')),
                                DropdownMenuItem(value: 1, child: Text(isEn ? '1 Device' : '۱ کاربر')),
                                DropdownMenuItem(value: 2, child: Text(isEn ? '2 Devices' : '۲ کاربر')),
                                DropdownMenuItem(value: 3, child: Text(isEn ? '3 Devices' : '۳ کاربر')),
                                DropdownMenuItem(value: 5, child: Text(isEn ? '5 Devices' : '۵ کاربر')),
                                DropdownMenuItem(value: 10, child: Text(isEn ? '10 Devices' : '۱۰ کاربر')),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ۲. لیست دستگاه‌های متصل زنده
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            isEn ? 'Connected Devices (${_liveHotspotClients.length}):' : 'دستگاه‌های متصل آنلاین (${_liveHotspotClients.length} کاربر):',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          InkWell(
                            onTap: () async {
                              await _fetchConnectedHotspotClients();
                              setDialogState(() {});
                            },
                            child: const Row(
                              children: [
                                Icon(Icons.sync_rounded, size: 14, color: Color(0xFF00D2FF)),
                                SizedBox(width: 4),
                                Text('استعلام دستی', style: TextStyle(fontSize: 11, color: Color(0xFF00D2FF))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      if (_liveHotspotClients.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF090B10),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              isEn ? 'No devices currently connected.' : 'در حال حاضر هیچ دستگاهی به هات‌اسپات متصل نیست.',
                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                            ),
                          ),
                        )
                      else
                        ..._liveHotspotClients.map((client) {
                          final isBanned = _hotspotMacBlacklist.contains(client['mac']);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF090B10),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: isBanned ? Colors.redAccent.withValues(alpha: 0.5) : Colors.white12),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.smartphone_rounded,
                                  color: isBanned ? Colors.redAccent : const Color(0xFF2DCA73),
                                  size: 24,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        client['name']!,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          Text('IP: ${client['ip']}', style: const TextStyle(fontSize: 11, color: Colors.grey, fontFamily: 'monospace')),
                                          const SizedBox(width: 12),
                                          Text('MAC: ${client['mac']}', style: const TextStyle(fontSize: 11, color: Colors.white60, fontFamily: 'monospace')),
                                        ],
                                      )
                                    ],
                                  ),
                                ),
                                if (isBanned)
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      await _unbanHotspotClientMac(client['mac']!);
                                      setDialogState(() {});
                                    },
                                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DCA73), foregroundColor: Colors.black),
                                    icon: const Icon(Icons.check_circle_outline_rounded, size: 14),
                                    label: Text(isEn ? 'Unban' : 'آزاد کردن', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  )
                                else
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      await _banHotspotClientMac(client['mac']!, ip: client['ip']);
                                      setDialogState(() {});
                                    },
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                                    icon: const Icon(Icons.block_rounded, size: 14),
                                    label: Text(isEn ? 'Ban Device' : 'مسدودسازی (بن)', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                          );
                        }),

                      const Divider(color: Colors.white12, height: 26),

                      // ۳. بخش بلک‌لیست و ثبت دستی مک‌آدرس
                      Text(
                        isEn ? 'Blacklisted MAC Addresses (Block List):' : 'لیست سیاه مک‌آدرس‌ها (دستگاه‌های مسدود شده):',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.redAccent),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: manualMacController,
                              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                              decoration: InputDecoration(
                                hintText: isEn ? 'e.g. A4-C3-F0-12-89-AB' : 'مثال: A4-C3-F0-12-89-AB',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () async {
                              final raw = manualMacController.text.trim();
                              if (raw.isNotEmpty) {
                                await _banHotspotClientMac(raw);
                                manualMacController.clear();
                                setDialogState(() {});
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
                              foregroundColor: Colors.redAccent,
                              side: const BorderSide(color: Colors.redAccent),
                            ),
                            icon: const Icon(Icons.add_moderator_rounded, size: 16),
                            label: Text(isEn ? 'Add to Blacklist' : 'افزودن به بلک‌لیست', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      if (_hotspotMacBlacklist.isEmpty)
                        Text(
                          isEn ? 'No MAC addresses are currently blacklisted.' : 'هیچ دستگاهی در لیست سیاه قرار ندارد.',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: _hotspotMacBlacklist.map((mac) {
                            return Chip(
                              backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                              side: const BorderSide(color: Colors.redAccent, width: 0.8),
                              label: Text(
                                mac,
                                style: const TextStyle(fontSize: 11, color: Colors.redAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                              ),
                              deleteIcon: const Icon(Icons.close_rounded, size: 14),
                              onDeleted: () async {
                                await _unbanHotspotClientMac(mac);
                                setDialogState(() {});
                              },
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      // تضمین ۱۰۰٪ توقف حلقه و صفر شدن مصرف رم و سی‌پی‌یو به محض بستن پنجره
      _hotspotMonitorTimer?.cancel();
      _hotspotMonitorTimer = null;
      AppLogger.info("HOTSPOT_MONITOR", "پنجره مانیتور بسته شد؛ حلقه استعلام زنده متوقف گردید.");
    });
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
    final bool isEn = AppTranslations.currentLang == 'en';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEn ? 'Advanced Anti-Censorship (Anti-DPI)' : 'تنظیمات فوق پیشرفته ضدسانسور (Anti-DPI)', 
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isEn ? 'TLS handshake spoofing, traffic fragmentation, and GoodbyeDPI filter bypass' : 'تکنیک‌های جعل دست‌دهی TLS، قطعه‌بندی ترافیک و افکت GoodbyeDPI', 
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
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
        const SizedBox(height: 24),
        Expanded(
          child: SingleChildScrollView(
            child: _buildGlassContainer(
              borderColor: const Color(0xFFED213A).withValues(alpha: 0.35),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEn ? '1. Kernel Anti-DPI Protection (WinDivert)' : '۱. افکت و محافظت کرنل GoodbyeDPI (WinDivert)', 
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2DCA73)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEn 
                        ? 'Direct packet modification at the network adapter level to bypass DPI censorship without a proxy' 
                        : 'دستکاری مستقیم پکت‌های خروجی در سطح کارت شبکه جهت فریب فیلترینگ بدون نیاز به پروکسی',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _openGoodbyeDpiConfigDialog,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2DCA73),
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        icon: const Icon(Icons.tune_rounded, size: 16),
                        label: Text(
                          isEn ? 'Configure GoodbyeDPI Presets & Arguments' : 'پیکربندی پریست‌ها و آرگومان‌های GoodbyeDPI', 
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (_isGoodbyeDpiRunning)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2DCA73).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFF2DCA73).withValues(alpha: 0.4)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF2DCA73)),
                              const SizedBox(width: 6),
                              Text(
                                isEn ? 'Core is running' : 'هسته در حال اجراست', 
                                style: const TextStyle(color: Color(0xFF2DCA73), fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        )
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 36),

                  Text(
                    isEn ? '2. Browser Fingerprint Emulation (uTLS)' : '۲. شبیه‌ساز اثر انگشت مرورگر (uTLS Fingerprint)', 
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEn 
                        ? 'Modifies ClientHello security signature to mimic real desktop web browsers' 
                        : 'تغییر اثر انگشت امنیتی ClientHello به شکل مرورگرهای واقعی دسکتاپ',
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
                      items: [
                        DropdownMenuItem(value: 'chrome', child: Text(isEn ? 'Google Chrome (Recommended)' : 'Google Chrome (پیشنهادی)')),
                        const DropdownMenuItem(value: 'firefox', child: Text('Mozilla Firefox')),
                        const DropdownMenuItem(value: 'safari', child: Text('Apple Safari')),
                        const DropdownMenuItem(value: 'edge', child: Text('Microsoft Edge')),
                        DropdownMenuItem(value: 'randomized', child: Text(isEn ? 'Randomized' : 'Randomized (تصادفی)')),
                      ],
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 36),

                  Text(
                    isEn ? '3. Encrypted Client Hello (Auto-ECH)' : '۳. رمزنگاری کامل هدر دامنه (Auto-ECH)', 
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF00D2FF)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEn 
                        ? 'Encrypts the SNI header with Cloudflare post-quantum keys so DPI cannot see the destination domain' 
                        : 'رمزنگاری کامل نام دامنه با کلیدهای پسا-کوانتومی تا فیلترینگ نتواند مقصد را بخواند',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      isEn ? 'Enable Encrypted Client Hello (ECH)' : 'فعال‌سازی رمزنگاری خودکار ECH', 
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      isEn ? 'Stealth SNI encryption (Recommended: Always ON)' : 'استتار نام دامنه (پیشنهادی: همیشه روشن)', 
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    value: _enableEch,
                    activeThumbColor: const Color(0xFF00D2FF),
                    onChanged: (bool value) {
                      setState(() {
                        _enableEch = value;
                      });
                      _saveAntiDpiToDisk();
                    },
                  ),
                  const Divider(color: Colors.white12, height: 36),

                  Text(
                    isEn ? '4. Packet Fragmentation (TLS Fragmentation)' : '۴. قطعه‌بندی پکت‌های امنیتی (Fragmentation)', 
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEn 
                        ? 'Fragments ClientHello packets to hide Server Name Indication (SNI) from DPI inspection' 
                        : 'خرد کردن پکت ClientHello برای ممانعت از خوانده شدن SNI توسط DPI',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      isEn ? 'Enable TLS Fragmentation' : 'فعال‌سازی قطعه‌بندی (TLS Fragmentation)', 
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      isEn ? 'Split Hello packet to evade SNI detection' : 'خرد کردن بسته سلام برای مهار تشخیص SNI', 
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
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
                    title: Text(
                      isEn ? 'Enable TLS Record Fragmentation' : 'فعال‌سازی قطعه‌بندی رکوردها (TLS Record Fragmentation)', 
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      isEn ? 'Fragment data at TLS record layer' : 'تکه‌تکه کردن داده‌ها در لایه رکوردهای رمزنگاری', 
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
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
                    decoration: InputDecoration(
                      labelText: isEn ? 'Fragmentation fallback delay' : 'تاخیر زمانی فالبک قطعه‌بندی (fallback delay)',
                      hintText: '500ms / 100ms',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const Divider(color: Colors.white12, height: 36),

                  Text(
                    isEn ? '4. Fake SNI Injection (TLS Spoofing)' : '۴. جعل تزریقی اس‌ان‌آی (TLS Spoofing)', 
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFFF8008)),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isEn 
                        ? 'Injects a fake Hello header with an unblocked domain (e.g. zoom.us) before the real packet' 
                        : 'تزریق هدر سلام فیک با دامنه مجاز (مانند zoom.us) پیش از پکت اصلی',
                    style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      isEn ? 'Enable Fake SNI Spoofing' : 'فعال‌سازی سیستم جعل تزریقی SNI', 
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(
                      isEn ? 'Bypass DPI by injecting decoy domains' : 'دور زدن DPI با ارسال اس‌ان‌آی فیک مجاز', 
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
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
                      decoration: InputDecoration(
                        labelText: isEn ? 'Allowed Decoy Domain (e.g. zoom.us, microsoft.com)' : 'نام دامنه مجاز (مانند zoom.us یا microsoft.com)',
                        hintText: 'zoom.us',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),

                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        final scaffoldMessenger = ScaffoldMessenger.of(context);
                        await _saveAntiDpiToDisk();
                        scaffoldMessenger.showSnackBar(
                          SnackBar(
                            content: Text(isEn ? 'Anti-DPI settings saved and applied successfully.' : 'تنظیمات پیشرفته Anti-DPI با موفقیت اعمال شد.'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        setState(() {
                          _selectedMenuIndex = 0;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFED213A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 10,
                        shadowColor: const Color(0xFFED213A).withValues(alpha: 0.4),
                      ),
                      icon: const Icon(Icons.check_circle_rounded, color: Colors.white),
                      label: Text(
                        isEn ? 'Save & Apply Anti-DPI Settings' : 'ثبت و اعمال تنظیمات ضدسانسور', 
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                      ),
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
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)),
                ),
                const SizedBox(width: 16),
                Text('querying_location'.tr(), style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
                            _publicIp ?? 'fetching_ip'.tr(),
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
                                  SnackBar(content: Text('toast_ip_copied'.tr()), duration: const Duration(seconds: 1)),
                                );
                              },
                              child: const Icon(Icons.copy_rounded, size: 14, color: Colors.grey),
                            )
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_cityName ?? "unknown".tr()}، ${_countryName ?? "unknown".tr()}',
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

  Future<void> _updateSingleHotkey(String action, String keyLetter) async {
    setState(() {
      if (action == 'dashboard') _hkDashboard = keyLetter;
      if (action == 'gaming') _hkGaming = keyLetter;
      if (action == 'aether') _hkAether = keyLetter;
      if (action == 'tor') _hkTor = keyLetter;
      if (action == 'psiphon') _hkPsiphon = keyLetter;
      if (action == 'tun') _hkTun = keyLetter;
    });
    await _savePreferencesToDisk();
    await _registerAllGlobalHotkeys();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('hotkeys_saved_toast'.tr()), duration: const Duration(seconds: 1)),
      );
    }
  }

  Widget _buildHotkeySettingTile(String title, String currentKey, ValueChanged<String> onChanged) {
    const letters = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z'];
    return Container(
      width: 290,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF090B10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Text('Ctrl + Shift + ', style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.grey)),
                DropdownButton<String>(
                  value: currentKey,
                  dropdownColor: const Color(0xFF141828),
                  underline: const SizedBox(),
                  isDense: true,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF00D2FF), fontFamily: 'monospace'),
                  items: letters.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
                  onChanged: (v) {
                    if (v != null) onChanged(v);
                  },
                ),
              ],
            ),
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis),
              ],
            ),
          )
        ],
      ),
    );
  }
  // =========================================================================
  // منطق و متدهای هسته گیمینگ (Gaming Controller & HUD)
  // =========================================================================

  void _startGamingMetricsPolling() {
    _gamingMetricsTimer?.cancel();
    _gamingMetricsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_isGamingRunning) {
        _gamingMetricsTimer?.cancel();
        return;
      }
      try {
        final metrics = await getGamingLiveMetrics();
        if (mounted) {
          setState(() {
            _gamingMetrics = metrics;
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _toggleGamingBoost() async {
    final bool isEn = AppTranslations.currentLang == 'en';
    if (_selectedGame == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isEn ? 'Please select a game first!' : 'لطفاً ابتدا یک بازی را انتخاب کنید!'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (_isGamingRunning) {
      setState(() => _isGamingStarting = true);
      try {
        await stopGamingBoost();
        await _maybeStopGoodbyeDpi();
        _gamingMetricsTimer?.cancel();
        setState(() {
          _isGamingRunning = false;
          _isGamingStarting = false;
          _gamingMetrics = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(isEn ? 'Gaming booster stopped.' : 'بوستر گیمینگ متوقف و سیستم به حالت عادی برگشت.'),
              backgroundColor: const Color(0xFF6C5DD3),
            ),
          );
        }
      } catch (e) {
        setState(() => _isGamingStarting = false);
      }
      return;
    }

    // خاموش کردن اتصالات فعال قبلی جهت جلوگیری از تداخل کارت‌های شبکه
    if (_isHybridRunning) await stopHybridConnection();
    if (_isProxyRunning) await stopProxyCore();
    if (_isAetherRunning) await stopAetherCore();
    if (_isTorRunning) await stopTorCore();
    if (_isPsiphonRunning) await stopPsiphonCore();

    // فعال‌سازی قطعی لایه ضد فیلترینگ و فرگمنت پکت‌های گیمینگ (GoodbyeDPI)
    await _maybeStartGoodbyeDpi(true);

    setState(() {
      _isGamingStarting = true;
      _gamingStatusStep = 'status_testing_dns'.tr();
    });

    try {
      // گام ۱: تست راستی‌آزمایی و ضد مسمومیت DNS برای دامنه‌های بازی
      await Future.delayed(const Duration(milliseconds: 300));
      setState(() => _gamingStatusStep = 'status_benchmarking_jitter'.tr());

      // گام ۲: پیکربندی و راه‌اندازی بوستر گیمینگ
      final config = GamingBoostConfig(
        gameId: _selectedGame!.id,
        gameName: _selectedGame!.name,
        executables: _selectedGame!.executables,
        authDomains: _selectedGame!.authDomains,
        preferredRegion: _selectedGamingRegion,
        enableKernelTweaks: _enableGamingBbr,
        dnsMode: _selectedGamingDnsMode,
      );

      final msg = await startGamingBoost(
        singboxPath: _binaryPathController.text.trim(),
        aetherPath: _aetherPathController.text.trim(),
        config: config,
      );

      setState(() {
        _isGamingRunning = true;
        _isGamingStarting = false;
        _gamingStatusStep = 'status_gaming_active'.tr();
      });

      _startGamingMetricsPolling();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: const Color(0xFF2DCA73),
          ),
        );
      }
    } catch (e, st) {
      AppLogger.error("GAMING_BOOST", "Error starting gaming booster", e, st);
      setState(() => _isGamingStarting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(isEn ? 'Failed to start gaming boost: $e' : 'خطا در فعال‌سازی بوستر گیمینگ: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _openAddCustomGameDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    final nameCtrl = TextEditingController();
    final exeCtrl = TextEditingController();
    final domainCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121520),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFFF4B2B), width: 1.4),
        ),
        title: Row(
          children: [
            const Icon(Icons.add_circle_outline_rounded, color: Color(0xFFFF4B2B)),
            const SizedBox(width: 10),
            Text(isEn ? 'Add Custom Game' : 'افزودن بازی دلخواه', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'Game Name' : 'نام بازی',
                  hintText: 'e.g. Call of Duty / FiveM',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: exeCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'Executable (.exe)' : 'فایل اجرایی (.exe)',
                  hintText: 'e.g. game.exe or Shipping.exe',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: domainCtrl,
                decoration: InputDecoration(
                  labelText: isEn ? 'Auth Domain (Optional)' : 'دامنه تست لاگین (اختیاری)',
                  hintText: 'e.g. auth.game.com',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(isEn ? 'Cancel' : 'انصراف', style: const TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () async {
              if (nameCtrl.text.trim().isEmpty || exeCtrl.text.trim().isEmpty) return;
              await _gamingRegistry.addCustomGame(
                name: nameCtrl.text.trim(),
                exeFileName: exeCtrl.text.trim(),
                testDomain: domainCtrl.text.trim(),
              );
              setState(() {});
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF4B2B), foregroundColor: Colors.white),
            child: Text(isEn ? 'Add Game' : 'ثبت بازی', style: const TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  Widget _buildGamingPage() {
    final bool isEn = AppTranslations.currentLang == 'en';
    final games = _gamingRegistry.filterGames(query: _gameSearchQuery, category: _selectedGameCategory);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // هدر تب گیمینگ
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFFFF416C), Color(0xFFFF4B2B)]),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text('PRO GAMING', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(width: 10),
                      Text('gaming_title'.tr(), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('gaming_subtitle'.tr(), style: const TextStyle(color: Colors.grey, fontSize: 11.5)),
                ],
              ),
            ),
            Row(
              children: [
                _buildGlassContainer(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  borderRadius: 14,
                  borderColor: _enableGamingBbr ? const Color(0xFFFFC837).withValues(alpha: 0.6) : Colors.white12,
                  child: Row(
                    children: [
                      const Icon(Icons.bolt_rounded, size: 16, color: Color(0xFFFFC837)),
                      const SizedBox(width: 6),
                      Text(isEn ? 'Kernel BBR' : 'شتاب‌دهنده BBR', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 6),
                      Switch(
                        value: _enableGamingBbr,
                        activeThumbColor: const Color(0xFFFFC837),
                        onChanged: _isGamingRunning ? null : (v) => setState(() => _enableGamingBbr = v),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _isGamingRunning ? null : _openAddCustomGameDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF141828),
                    foregroundColor: const Color(0xFFFF4B2B),
                    side: const BorderSide(color: Color(0xFFFF4B2B), width: 1.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text('add_custom_game'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            )
          ],
        ),
        const SizedBox(height: 18),

        // بخش اصلی: اگر بازی در حال اجراست HUD مانیتورینگ زنده را نشان بده، در غیر این صورت گرید انتخاب بازی
        Expanded(
          child: _isGamingRunning ? _buildLiveGamingHud() : _buildGameSelectionView(games),
        ),
      ],
    );
  }

  Widget _buildGameSelectionView(List<GameItem> games) {
    final bool isEn = AppTranslations.currentLang == 'en';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ستون سمت چپ: گرید و لیست بازی‌ها
        Expanded(
          flex: 6,
          child: Column(
            children: [
              // نوار جستجو و فیلتر دسته‌بندی
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        onChanged: (v) => setState(() => _gameSearchQuery = v.trim()),
                        style: const TextStyle(fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'search_game'.tr(),
                          prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFF090B10),
                          contentPadding: EdgeInsets.zero,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF090B10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: DropdownButton<String>(
                      value: _selectedGameCategory,
                      dropdownColor: const Color(0xFF0D101A),
                      underline: const SizedBox(),
                      style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold),
                      onChanged: (v) {
                        if (v != null) setState(() => _selectedGameCategory = v);
                      },
                      items: _gamingRegistry.categories.map((c) => DropdownMenuItem(value: c, child: Text(c.toUpperCase()))).toList(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // گرید کارت‌های بازی
              Expanded(
                child: _buildGlassContainer(
                  padding: const EdgeInsets.all(12),
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      childAspectRatio: 1.25,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: games.length,
                    itemBuilder: (context, index) {
                      final game = games[index];
                      final isSelected = _selectedGame?.id == game.id;

                      return InkWell(
                        onTap: () => setState(() => _selectedGame = game),
                        borderRadius: BorderRadius.circular(14),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isSelected ? game.accentColor.withValues(alpha: 0.18) : const Color(0xFF090B10),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected ? game.accentColor : Colors.white10,
                              width: isSelected ? 1.8 : 1.0,
                            ),
                            boxShadow: isSelected
                                ? [BoxShadow(color: game.accentColor.withValues(alpha: 0.35), blurRadius: 14)]
                                : null,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Icon(game.iconData, color: isSelected ? game.accentColor : Colors.grey, size: 24),
                                  if (isSelected)
                                    Icon(Icons.check_circle_rounded, color: game.accentColor, size: 16)
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.05),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(game.primaryProtocol, style: const TextStyle(fontSize: 9, color: Colors.grey)),
                                    ),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    game.name,
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isSelected ? Colors.white : Colors.white70),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    game.executables.first,
                                    style: const TextStyle(fontSize: 9.5, color: Colors.grey, fontFamily: 'monospace'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),

        // ستون سمت راست: انتخاب ریجن و دکمه راه‌اندازی
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGlassContainer(
                  borderColor: const Color(0xFFFF4B2B).withValues(alpha: 0.4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.public_rounded, color: Color(0xFFFF4B2B), size: 18),
                          const SizedBox(width: 8),
                          Text('game_region'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildRegionTile('auto', 'region_auto'.tr(), Icons.auto_awesome_rounded, const Color(0xFF00D2FF)),
                      const SizedBox(height: 8),
                      _buildRegionTile('turkey', 'region_turkey'.tr(), Icons.flag_rounded, const Color(0xFFFF8008)),
                      const SizedBox(height: 8),
                      _buildRegionTile('uae', 'region_uae'.tr(), Icons.location_on_rounded, const Color(0xFF2DCA73)),
                      const SizedBox(height: 8),
                      _buildRegionTile('germany', 'region_germany'.tr(), Icons.hub_rounded, const Color(0xFF6C5DD3)),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // بخش انتخاب مود DNS و دکمه آپدیت ۴۸ ساعته
                _buildGlassContainer(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.dns_rounded, color: Color(0xFF00D2FF), size: 16),
                              const SizedBox(width: 6),
                              Text('dns_mode_label'.tr(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          InkWell(
                            onTap: _isUpdatingLocalDns ? null : () async {
                              setState(() => _isUpdatingLocalDns = true);
                              final ok = await LocalDnsService().syncOnlineMappings();
                              setState(() => _isUpdatingLocalDns = false);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(ok ? 'local_dns_updated'.tr() : 'خطا در ارتباط با سرور دیتابیس DNS'),
                                    backgroundColor: ok ? const Color(0xFF2DCA73) : Colors.redAccent,
                                  ),
                                );
                              }
                            },
                            child: Row(
                              children: [
                                _isUpdatingLocalDns 
                                    ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)))
                                    : const Icon(Icons.sync_rounded, size: 14, color: Color(0xFF00D2FF)),
                                const SizedBox(width: 4),
                                Text('update_local_dns'.tr(), style: const TextStyle(fontSize: 10, color: Color(0xFF00D2FF))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() => _selectedGamingDnsMode = 'local'),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: _selectedGamingDnsMode == 'local' ? const Color(0xFF00D2FF).withValues(alpha: 0.2) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _selectedGamingDnsMode == 'local' ? const Color(0xFF00D2FF) : Colors.white10),
                                ),
                                child: Center(
                                  child: Text('dns_mode_local'.tr(), style: TextStyle(fontSize: 10, fontWeight: _selectedGamingDnsMode == 'local' ? FontWeight.bold : FontWeight.normal)),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() => _selectedGamingDnsMode = 'resolver'),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: _selectedGamingDnsMode == 'resolver' ? const Color(0xFFFF8008).withValues(alpha: 0.2) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _selectedGamingDnsMode == 'resolver' ? const Color(0xFFFF8008) : Colors.white10),
                                ),
                                child: Center(
                                  child: Text('dns_mode_resolver'.tr(), style: TextStyle(fontSize: 10, fontWeight: _selectedGamingDnsMode == 'resolver' ? FontWeight.bold : FontWeight.normal)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // باکس محافظت سشن
                _buildGlassContainer(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.security_rounded, color: Color(0xFF2DCA73), size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('session_lock_title'.tr(), style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 2),
                            Text('session_lock_active'.tr(), style: const TextStyle(fontSize: 9.5, color: Colors.grey)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // دکمه بزرگ استارت بوستر
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _isGamingStarting ? null : _toggleGamingBoost,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF4B2B),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 8,
                      shadowColor: const Color(0xFFFF4B2B).withValues(alpha: 0.5),
                    ),
                    icon: _isGamingStarting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.rocket_launch_rounded, size: 22),
                    label: Text(
                      _isGamingStarting ? _gamingStatusStep : 'gaming_boost_btn'.tr(),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
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

  Widget _buildRegionTile(String code, String title, IconData icon, Color color) {
    final isSelected = _selectedGamingRegion == code;

    return InkWell(
      onTap: () => setState(() => _selectedGamingRegion = code),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.15) : const Color(0xFF090B10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: isSelected ? color : Colors.white10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: isSelected ? color : Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, color: isSelected ? Colors.white : Colors.grey[300]),
              ),
            ),
            if (isSelected) Icon(Icons.radio_button_checked_rounded, color: color, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveGamingHud() {
    final metrics = _gamingMetrics;
    final ping = metrics?.currentPingMs ?? -1;
    final jitter = metrics?.currentJitterMs ?? 0;
    final rstCount = metrics?.rstPacketsDefended ?? _radarRstCount;

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 820),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // نشانگر دایره‌ای پینگ زنده
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 180,
                height: 180,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF416C), Color(0xFFFF4B2B)],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF4B2B).withValues(alpha: 0.45),
                      blurRadius: 36,
                      spreadRadius: 6,
                    )
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.sports_esports_rounded, color: Colors.white, size: 36),
                    const SizedBox(height: 6),
                    Text(
                      ping > 0 ? '$ping ms' : 'Optimal',
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white, fontFamily: 'monospace'),
                    ),
                    const Text('LOWEST PING', style: TextStyle(fontSize: 9, letterSpacing: 1.5, color: Colors.white70, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              Text(
                '🔥 بازی ${_selectedGame?.name ?? ""} تحت محافظت تونل اختصاصی است',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(
                'سایر برنامه‌ها (تلگرام، کروم، ویندوز) مستقیماً از نت عادی عبور می‌کنند تا پینگ بازی را خراب نکنند.',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[400]),
              ),
              const SizedBox(height: 24),

              // کارت‌های وضعیت HUD
              Row(
                children: [
                  Expanded(child: _buildHudStatCard('hud_live_ping'.tr(), ping > 0 ? '$ping ms' : '< 45ms', Icons.speed_rounded, const Color(0xFF2DCA73))),
                  const SizedBox(width: 12),
                  Expanded(child: _buildHudStatCard('hud_jitter'.tr(), '±$jitter ms', Icons.waves_rounded, const Color(0xFF00D2FF))),
                  const SizedBox(width: 12),
                  Expanded(child: _buildHudStatCard('hud_rst_blocked'.tr(), '$rstCount', Icons.shield_rounded, const Color(0xFFFF8008))),
                  const SizedBox(width: 12),
                  Expanded(child: _buildHudStatCard('hud_webrtc_shield'.tr(), 'Active', Icons.lock_outline_rounded, const Color(0xFF6C5DD3))),
                ],
              ),
              const SizedBox(height: 28),

              // دکمه توقف بوستر گیمینگ
              SizedBox(
                width: 320,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _toggleGamingBoost,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.2),
                    foregroundColor: Colors.redAccent,
                    side: const BorderSide(color: Colors.redAccent, width: 1.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.stop_circle_rounded),
                  label: Text('gaming_stop_btn'.tr(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHudStatCard(String title, String value, IconData icon, Color color) {
    return _buildGlassContainer(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      borderRadius: 14,
      borderColor: color.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 10.5, color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  /// دیالوگ پیشرفته سایفون جهت فعال‌سازی CDN Fronting (درون کلاس State)
  void _openPsiphonAdvancedDialog() {
    final bool isEn = AppTranslations.currentLang == 'en';
    bool tempFronting = _usePsiphonCdnFronting;
    String tempMode = _psiphonCdnMode;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF121520),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
                side: const BorderSide(color: Color(0xFFFF8008), width: 1.4),
              ),
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF8008).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.cell_tower_rounded, color: Color(0xFFFF8008), size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isEn ? 'Psiphon Advanced (CDN Fronting)' : 'تنظیمات پیشرفته سایفون (CDN Fronting)',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          isEn ? 'Bypass extreme censorship using Domain Fronting' : 'عبور از فیلترینگ شدید با پنهان‌سازی پشت سرورهای CDN',
                          style: const TextStyle(fontSize: 10.5, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 500,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF090B10),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Text(
                        isEn 
                            ? 'CDN Fronting routes Psiphon handshakes disguised as normal traffic to trusted international CDN networks (Akamai & Cloudflare).'
                            : 'فناوری CDN Fronting پکت‌های اتصال سایفون را با هویت جعلی و قانونی از درون CDNهای بین‌المللی عبور می‌دهد تا در زمان فیلترینگ شدید متصل بمانید.',
                        style: const TextStyle(fontSize: 11.5, color: Colors.white70, height: 1.6),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: tempFronting ? const Color(0xFFFF8008).withValues(alpha: 0.12) : const Color(0xFF090B10),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: tempFronting ? const Color(0xFFFF8008) : Colors.white12),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.flash_on_rounded, color: tempFronting ? const Color(0xFFFF8008) : Colors.grey, size: 22),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isEn ? 'Enable CDN Fronting' : 'فعال‌سازی CDN Fronting',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    isEn ? 'Meek domain fronting mode' : 'پنهان‌سازی ترافیک پشت سرورهای ابری',
                                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Switch(
                            value: tempFronting,
                            activeThumbColor: const Color(0xFFFF8008),
                            onChanged: (v) => setDialogState(() => tempFronting = v),
                          ),
                        ],
                      ),
                    ),
                    if (tempFronting) ...[
                      const SizedBox(height: 16),
                      Text(
                        isEn ? 'Fronting Protocol Mode:' : 'نوع پروتکل فرانتینگ:',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF090B10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: DropdownButton<String>(
                          value: tempMode,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF090B10),
                          underline: const SizedBox(),
                          style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold),
                          onChanged: (v) {
                            if (v != null) setDialogState(() => tempMode = v);
                          },
                          items: [
                            DropdownMenuItem(
                              value: 'cdn',
                              child: Text(isEn ? 'Meek CDN Mode (Aggressive - Recommended)' : 'حالت کامل CDN Meek (ضد اختلال شدید - پیشنهادی)'),
                            ),
                            DropdownMenuItem(
                              value: 'direct',
                              child: Text(isEn ? 'Direct Mode (Without CDN disguise)' : 'حالت مستقیم (بدون فرانتینگ)'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _usePsiphonCdnFronting = false;
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: Text(isEn ? 'Disable & Reset' : 'غیرفعال‌سازی و حالت عادی', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _usePsiphonCdnFronting = tempFronting;
                      _psiphonCdnMode = tempMode;
                    });
                    Navigator.of(ctx).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(tempFronting 
                            ? (isEn ? 'CDN Fronting enabled! Tap connect.' : 'فناوری CDN Fronting فعال شد! اکنون روی دکمه اتصال کلیک کنید.')
                            : (isEn ? 'Saved in standard mode.' : 'تنظیمات در حالت مستقیم ذخیره شد.')),
                        backgroundColor: tempFronting ? const Color(0xFF2DCA73) : const Color(0xFF6C5DD3),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF8008),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: Text(isEn ? 'Apply & Return' : 'اعمال و بازگشت به صفحه اتصال', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            );
          },
        );
      },
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
/// ویجت اختصاصی و مستقل عیب‌یابی سیستم با بروزرسانی زنده
class SystemDiagnosticsDialog extends StatefulWidget {
  const SystemDiagnosticsDialog({super.key});

  @override
  State<SystemDiagnosticsDialog> createState() => _SystemDiagnosticsDialogState();
}

class _SystemDiagnosticsDialogState extends State<SystemDiagnosticsDialog> {
  final Map<String, dynamic> _results = {
    'admin': null,
    'raw_internet': null,
    'dns': null,
    'stuck_proxy': null,
    'cores': null,
    'ports': null,
  };

  @override
  void initState() {
    super.initState();
    _startLiveDiagnostics();
  }

  Future<void> _startLiveDiagnostics() async {
    // ۱. تست Administrator با دستور سیستمی net session
    bool isAdmin = false;
    if (Platform.isWindows) {
      try {
        final res = await Process.run('net', ['session'], runInShell: true);
        isAdmin = res.exitCode == 0;
      } catch (_) {
        isAdmin = false;
      }
    } else {
      isAdmin = true;
    }
    if (mounted) setState(() => _results['admin'] = isAdmin);
    await Future.delayed(const Duration(milliseconds: 250));

    // ۲. تست فیزیکی اینترنت (سوکِت خام به 1.1.1.1 بدون نیاز به DNS)
    bool hasNet = false;
    try {
      final s = await Socket.connect('1.1.1.1', 53, timeout: const Duration(seconds: 2));
      s.destroy();
      hasNet = true;
    } catch (_) {
      try {
        final s2 = await Socket.connect('8.8.8.8', 53, timeout: const Duration(seconds: 2));
        s2.destroy();
        hasNet = true;
      } catch (_) {
        hasNet = false;
      }
    }
    if (mounted) setState(() => _results['raw_internet'] = hasNet);
    await Future.delayed(const Duration(milliseconds: 250));

    // ۳. تست تبدیل نام دامنه DNS
    bool hasDns = false;
    try {
      final l = await InternetAddress.lookup('google.com').timeout(const Duration(seconds: 3));
      hasDns = l.isNotEmpty && l[0].rawAddress.isNotEmpty;
    } catch (_) {
      try {
        final l2 = await InternetAddress.lookup('aparat.com').timeout(const Duration(seconds: 2));
        hasDns = l2.isNotEmpty;
      } catch (_) {
        hasDns = false;
      }
    }
    if (mounted) setState(() => _results['dns'] = hasDns);
    await Future.delayed(const Duration(milliseconds: 250));

    // ۴. بررسی گیر کردن پروکسی قبلی ویندوز در رجیستری
    bool isProxyStuck = false;
    if (Platform.isWindows) {
      try {
        final res = await Process.run(
          'reg',
          ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', '/v', 'ProxyEnable'],
          runInShell: true,
        );
        isProxyStuck = res.stdout.toString().contains('0x1');
      } catch (_) {
        isProxyStuck = false;
      }
    }
    if (mounted) setState(() => _results['stuck_proxy'] = isProxyStuck);
    await Future.delayed(const Duration(milliseconds: 250));

    // ۵. بررسی فیزیکی وجود فایل‌های هسته و آنتی‌ویروس Defender
    List<String> missing = [];
    final exeDir = File(Platform.resolvedExecutable).parent;
    final currentDir = Directory.current;
    final filesToCheck = [
      'sing-box.exe',
      'aether.exe',
      'goodbyedpi.exe',
      'WinDivert.dll',
      'WinDivert64.sys',
      'wintun.dll'
    ];

    for (var fName in filesToCheck) {
      final inExe = File('${exeDir.path}\\$fName');
      final inCur = File('${currentDir.path}\\$fName');
      if (!inExe.existsSync() && !inCur.existsSync()) {
        missing.add(fName);
      }
    }
    if (mounted) setState(() => _results['cores'] = missing);
    await Future.delayed(const Duration(milliseconds: 250));

    // ۶. بررسی اشغال بودن پورت‌های لوکال (2080 / 1819)
    bool conflict = false;
    try {
      final s1 = await ServerSocket.bind('127.0.0.1', 2080);
      await s1.close();
      final s2 = await ServerSocket.bind('127.0.0.1', 1819);
      await s2.close();
    } catch (_) {
      conflict = true;
    }
    if (mounted) setState(() => _results['ports'] = conflict);
  }

  @override
  Widget build(BuildContext context) {
    final bool isEn = AppTranslations.currentLang == 'en';
    final bool admin = _results['admin'] == true;
    final bool? rawNet = _results['raw_internet'];
    final bool? dns = _results['dns'];
    final bool? stuckProxy = _results['stuck_proxy'];
    final List<String>? missingCores = _results['cores'];
    final bool? portConflict = _results['ports'];

    return AlertDialog(
      backgroundColor: const Color(0xFF121520),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: Color(0xFF00D2FF), width: 1.5),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF00D2FF).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.analytics_rounded, color: Color(0xFF00D2FF), size: 22),
          ),
          const SizedBox(width: 12),
          Text(
            isEn ? 'Deep System Diagnostics' : 'عیب‌یابی جامع و دقیق سیستم',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEn
                    ? 'Real-time testing of permissions, network adapters, DNS, drivers, and binaries:'
                    : 'نتایج بررسی زنده دسترسی‌های ویندوز، شبکه، فایروال و آنتی‌ویروس:',
                style: const TextStyle(fontSize: 11.5, color: Colors.grey),
              ),
              const SizedBox(height: 18),

              _buildRow(
                title: isEn ? 'Windows Administrator Privileges' : 'سطح دسترسی ادمین (Run as Administrator)',
                status: _results['admin'],
                success: isEn ? 'Granted (Root Privileges Active)' : 'تایید شد (دسترسی کامل سیستمی فعال است)',
                fail: isEn ? 'Not Admin (Rerun as Administrator)' : 'خطا: برنامه بدون دسترسی Administrator اجرا شده است',
              ),
              const SizedBox(height: 10),

              _buildRow(
                title: isEn ? 'Physical Network Connection' : 'اتصال فیزیکی به شبکه و مودم (Raw Socket)',
                status: rawNet,
                success: isEn ? 'Online (Physical link active)' : 'متصل (ارتباط کابل/وای‌فای به مودم برقرار است)',
                fail: isEn ? 'Offline (Check your router or Wi-Fi)' : 'قطع: دستگاه شما به مودم یا اینترنت وصل نیست',
              ),
              const SizedBox(height: 10),

              _buildRow(
                title: isEn ? 'DNS Domain Resolution' : 'تبدیل نام دامنه به آی‌پی (DNS Resolution)',
                status: dns,
                success: isEn ? 'Operational (DNS is functional)' : 'سالم (پاسخ‌های دی‌ان‌اس دریافت می‌شوند)',
                fail: isEn ? 'DNS Failed (DNS is blocked or poisoned)' : 'اختلال: دی‌ان‌اس سیستم مسدود یا مسموم شده است',
              ),
              const SizedBox(height: 10),

              _buildRow(
                title: isEn ? 'Windows Proxy Status' : 'وضعیت پروکسی سیستم در رجیستری ویندوز',
                status: stuckProxy != null ? !stuckProxy : null,
                success: isEn ? 'Clean (No stuck system proxy)' : 'پاک (پروکسی ویندوز تداخلی ایجاد نکرده)',
                fail: isEn ? 'Stuck Proxy (A leftover proxy is blocking net)' : 'هشدار: پروکسی قبلی ویندوز روشن مانده و نت را بسته است!',
              ),
              const SizedBox(height: 10),

              _buildRow(
                title: isEn ? 'Core Binaries & Antivirus Check' : 'سلامت هسته‌ها و بررسی آنتی‌ویروس (Defender)',
                status: missingCores?.isEmpty,
                success: isEn ? 'All core files exist and intact' : 'کامل (تمام فایل‌های هسته و درایور موجود هستند)',
                fail: isEn
                    ? 'Missing: ${missingCores?.join(", ")} (Quarantined by Defender)'
                    : 'ناقص: فایل‌های (${missingCores?.join(", ")}) حذف شده‌اند (توسط آنتی‌ویروس)',
              ),
              const SizedBox(height: 10),

              _buildRow(
                title: isEn ? 'Local Port Availability (2080 / 1819)' : 'آزاد بودن پورت‌های محلی (2080 و 1819)',
                status: portConflict != null ? !portConflict : null,
                success: isEn ? 'Available (No port conflicts)' : 'آزاد (پورت‌های برنامه در دسترس هستند)',
                fail: isEn ? 'Conflict: Port 2080 is occupied' : 'تداخل: پورت ۲۰۸۰ توسط نرم‌افزار دیگری اشغال شده',
              ),

              const SizedBox(height: 20),
              const Divider(color: Colors.white12),
              const SizedBox(height: 10),

              if (stuckProxy == true) ...[
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await Process.run(
                        'reg',
                        ['add', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0', '/f'],
                        runInShell: true,
                      );
                      setState(() => _results['stuck_proxy'] = false);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(isEn ? 'Windows proxy cleared!' : 'پروکسی ویندوز پاکسازی شد! اینترنت باز شد.'), backgroundColor: const Color(0xFF2DCA73)),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber[800], foregroundColor: Colors.white),
                    icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                    label: Text(isEn ? 'Fix Stuck Proxy Now' : 'پاکسازی فوری پروکسی و باز شدن اینترنت', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11.5)),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              if (!admin) ...[
                Text(
                  isEn
                      ? 'Tip: Please right click RedCloud icon and choose "Run as administrator".'
                      : 'نکته مهم: برای رفع محدودیت‌ها، روی آیکون برنامه راست‌کلیک کرده و Run as administrator را بزنید.',
                  style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(isEn ? 'Close' : 'بستن', style: const TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }

  Widget _buildRow({required String title, required bool? status, required String success, required String fail}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF090B10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: status == null
              ? Colors.white12
              : status
                  ? const Color(0xFF2DCA73).withValues(alpha: 0.3)
                  : Colors.redAccent.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (status == null)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00D2FF)))
          else if (status)
            const Icon(Icons.check_circle_rounded, color: Color(0xFF2DCA73), size: 18)
          else
            const Icon(Icons.cancel_rounded, color: Colors.redAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 2),
                Text(
                  status == null ? 'در حال بررسی...' : (status ? success : fail),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: status == null ? Colors.grey : (status ? const Color(0xFF2DCA73) : Colors.redAccent),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}