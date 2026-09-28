import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// مدل جامع هر بازی برای روتینگ اختصاصی و تست DNS
class GameItem {
  final String id;
  final String name;
  final String category;
  final List<String> executables;
  final List<String> authDomains;
  final List<String> cloudProviders;
  final String primaryProtocol;
  final IconData iconData;
  final Color accentColor;
  final bool isCustom;

  GameItem({
    required this.id,
    required this.name,
    required this.category,
    required this.executables,
    required this.authDomains,
    required this.cloudProviders,
    this.primaryProtocol = 'Hybrid',
    this.iconData = Icons.sports_esports_rounded,
    this.accentColor = const Color(0xFF00D2FF),
    this.isCustom = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'executables': executables,
    'auth_domains': authDomains,
    'cloud_providers': cloudProviders,
    'primary_protocol': primaryProtocol,
    'is_custom': isCustom,
  };

  factory GameItem.fromJson(Map<String, dynamic> json) {
    return GameItem(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      category: json['category'] ?? 'General',
      executables: List<String>.from(json['executables'] ?? []),
      authDomains: List<String>.from(json['auth_domains'] ?? []),
      cloudProviders: List<String>.from(json['cloud_providers'] ?? []),
      primaryProtocol: json['primary_protocol'] ?? 'Hybrid',
      iconData: _resolveIconByCategory(json['category'] ?? ''),
      accentColor: _resolveColorByCategory(json['category'] ?? ''),
      isCustom: json['is_custom'] ?? false,
    );
  }

  static IconData _resolveIconByCategory(String category) {
    switch (category.toLowerCase()) {
      case 'tactical shooter':
      case 'shooter':
        return Icons.gps_fixed_rounded;
      case 'battle royale':
        return Icons.military_tech_rounded;
      case 'moba':
        return Icons.auto_awesome_rounded;
      case 'sports':
        return Icons.sports_soccer_rounded;
      case 'racing':
        return Icons.speed_rounded;
      case 'survival':
      case 'horror':
        return Icons.local_fire_department_rounded;
      default:
        return Icons.sports_esports_rounded;
    }
  }

  static Color _resolveColorByCategory(String category) {
    switch (category.toLowerCase()) {
      case 'tactical shooter':
      case 'shooter':
        return const Color(0xFFFF4E50);
      case 'battle royale':
        return const Color(0xFFFF8008);
      case 'moba':
        return const Color(0xFF6C5DD3);
      case 'sports':
        return const Color(0xFF2DCA73);
      case 'racing':
        return const Color(0xFFFFC837);
      case 'survival':
      case 'horror':
        return const Color(0xFFE94057);
      default:
        return const Color(0xFF00D2FF);
    }
  }
}

/// رجیستری متمرکز بازی‌ها با پشتیبانی از کش آفلاین و آپدیت زنده
class GamingRegistry {
  static final GamingRegistry _instance = GamingRegistry._internal();
  factory GamingRegistry() => _instance;
  GamingRegistry._internal();

  List<GameItem> _games = [];
  List<GameItem> _customGames = [];
  bool _isInitialized = false;

  List<GameItem> get allGames => [..._games, ..._customGames];

  List<String> get categories {
    final set = <String>{'all'};
    for (var g in allGames) {
      set.add(g.category);
    }
    return set.toList();
  }

  /// مقداردهی اولیه
  Future<void> init() async {
    if (_isInitialized) return;
    _games = _getPrebakedGames();
    await _loadCustomGamesFromDisk();
    await _loadCachedOnlineCatalog();
    _isInitialized = true;
  }

  /// استعلام و همگام‌سازی آخرین تغییرات از سرور گیت‌هاب
  Future<void> syncOnlineCatalog() async {
    try {
      final url = Uri.parse('https://raw.githubusercontent.com/Devtahas/RedCloud-windows/main/gaming_targets.json');
      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final List<dynamic> decoded = jsonDecode(response.body);
        final List<GameItem> fetched = decoded.map((j) => GameItem.fromJson(j)).toList();

        if (fetched.isNotEmpty) {
          _games = fetched;
          final file = await _getLocalCacheFile('cached_gaming_targets.json');
          await file.writeAsString(response.body);
        }
      }
    } catch (_) {}
  }

  Future<void> _loadCachedOnlineCatalog() async {
    try {
      final file = await _getLocalCacheFile('cached_gaming_targets.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        _games = decoded.map((j) => GameItem.fromJson(j)).toList();
      }
    } catch (_) {}
  }

  Future<void> _loadCustomGamesFromDisk() async {
    try {
      final file = await _getLocalCacheFile('saved_custom_games.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> decoded = jsonDecode(content);
        _customGames = decoded.map((j) => GameItem.fromJson(j)).toList();
      }
    } catch (_) {}
  }

  Future<void> _saveCustomGamesToDisk() async {
    try {
      final file = await _getLocalCacheFile('saved_custom_games.json');
      final data = _customGames.map((g) => g.toJson()).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<File> _getLocalCacheFile(String fileName) async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}/$fileName');
  }

  /// افزودن بازی سفارشی توسط کاربر
  Future<void> addCustomGame({
    required String name,
    required String exeFileName,
    String? testDomain,
    String category = 'Custom',
  }) async {
    final cleanExe = exeFileName.trim().replaceAll('/', '\\').split('\\').last;
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final domain = (testDomain != null && testDomain.trim().isNotEmpty) ? testDomain.trim() : 'google.com';

    final item = GameItem(
      id: id,
      name: name.trim(),
      category: category,
      executables: [cleanExe],
      authDomains: [domain],
      cloudProviders: ['Custom'],
      primaryProtocol: 'Hybrid',
      iconData: Icons.extension_rounded,
      accentColor: const Color(0xFF2DCA73),
      isCustom: true,
    );

    _customGames.add(item);
    await _saveCustomGamesToDisk();
  }

  /// فیلتر هوشمند بازی‌ها
  List<GameItem> filterGames({String query = '', String category = 'all'}) {
    return allGames.where((game) {
      final matchCategory = (category == 'all') || (game.category.toLowerCase() == category.toLowerCase());
      final matchQuery = query.isEmpty ||
          game.name.toLowerCase().contains(query.toLowerCase()) ||
          game.executables.any((e) => e.toLowerCase().contains(query.toLowerCase()));
      return matchCategory && matchQuery;
    }).toList();
  }

  /// لیست ۲۰ بازی استخراج‌شده با هوش مصنوعی
  List<GameItem> _getPrebakedGames() {
    const rawJson = r'''
[
  {
    "id": "valorant",
    "name": "Valorant",
    "category": "Tactical Shooter",
    "executables": ["VALORANT-Win64-Shipping.exe", "VALORANT.exe", "RiotClientServices.exe"],
    "auth_domains": ["auth.riotgames.com", "clientconfig.rpg.riotgames.com", "playerplatform.riotgames.com", "entitlements.auth.riotgames.com"],
    "cloud_providers": ["Cloudflare", "AWS"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "cs2",
    "name": "Counter-Strike 2",
    "category": "Shooter",
    "executables": ["cs2.exe", "steam.exe", "steamwebhelper.exe"],
    "auth_domains": ["steamcommunity.com", "api.steampowered.com", "store.steampowered.com", "help.steampowered.com"],
    "cloud_providers": ["Valve", "Akamai", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "dota2",
    "name": "Dota 2",
    "category": "MOBA",
    "executables": ["dota2.exe", "steam.exe", "steamwebhelper.exe"],
    "auth_domains": ["steamcommunity.com", "api.steampowered.com", "dota2.com", "valvesoftware.com"],
    "cloud_providers": ["Valve", "Akamai"],
    "primary_protocol": "UDP"
  },
  {
    "id": "cod_warzone",
    "name": "Call of Duty: Warzone",
    "category": "Battle Royale",
    "executables": ["ModernWarfare.exe", "cod.exe", "Battle.net.exe", "Battle.net Helper.exe"],
    "auth_domains": ["profile.callofduty.com", "accounts.activision.com", "callofduty.com", "battle.net"],
    "cloud_providers": ["AWS", "Microsoft Azure", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "rainbow_six_siege",
    "name": "Rainbow Six Siege",
    "category": "Tactical Shooter",
    "executables": ["RainbowSix.exe", "RainbowSix_Vulkan.exe", "RainbowSix_DX11.exe", "UbisoftConnect.exe"],
    "auth_domains": ["account.ubisoft.com", "connect.ubisoft.com", "public-ubiservices.ubi.com", "r6.ubi.com"],
    "cloud_providers": ["Microsoft Azure", "AWS"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "apex_legends",
    "name": "Apex Legends",
    "category": "Battle Royale",
    "executables": ["r5apex.exe", "ApexLauncher.exe", "EasyAntiCheat_EOS_Setup.exe", "steam.exe"],
    "auth_domains": ["accounts.ea.com", "signin.ea.com", "ea.com", "origin.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "fortnite",
    "name": "Fortnite",
    "category": "Battle Royale",
    "executables": ["FortniteLauncher.exe", "FortniteClient-Win64-Shipping.exe", "FortniteClient-Win64-Shipping_BE.exe", "FortniteClient-Win64-Shipping_EAC.exe", "EasyAntiCheat.exe"],
    "auth_domains": ["account.epicgames.com", "launcher-public-service-prod06.ol.epicgames.com", "fortnite-matchmaking-public-service-live-eu.ol.epicgames.com", "eulatracking-public-service-prod.ol.epicgames.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "league_of_legends",
    "name": "League of Legends",
    "category": "MOBA",
    "executables": ["LeagueClient.exe", "LeagueClientUx.exe", "RiotClientServices.exe"],
    "auth_domains": ["authenticate.riotgames.com", "auth.riotgames.com", "entitlements.auth.riotgames.com", "api.account.riotgames.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "pubg",
    "name": "PUBG: Battlegrounds",
    "category": "Battle Royale",
    "executables": ["TslGame.exe", "ExecPubg.exe", "BEService.exe", "steam.exe"],
    "auth_domains": ["accounts.pubg.com", "api.pubg.com", "pubg.com", "playbattlegrounds.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "ea_sports_fc",
    "name": "EA Sports FC",
    "category": "Sports",
    "executables": ["FC26.exe", "FC26_Trial.exe", "FC25.exe", "EAAntiCheat.GameServiceLauncher.exe", "EADesktop.exe"],
    "auth_domains": ["accounts.ea.com", "signin.ea.com", "fifa.stats.gameservices.ea.com", "fifa-online.easports.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "rocket_league",
    "name": "Rocket League",
    "category": "Sports",
    "executables": ["RocketLeague.exe", "steam.exe", "EpicGamesLauncher.exe"],
    "auth_domains": ["psyonix-rl.appspot.com", "api.rlpp.psynet.gg", "accounts.epicgames.com", "launcher-public-service-prod06.ol.epicgames.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "overwatch_2",
    "name": "Overwatch 2",
    "category": "Shooter",
    "executables": ["Overwatch.exe", "Battle.net.exe", "Agent.exe", "Battle.net Helper.exe"],
    "auth_domains": ["account.battle.net", "oauth.battle.net", "us.battle.net", "blizzard.com"],
    "cloud_providers": ["Google Cloud", "AWS", "Microsoft Azure"],
    "primary_protocol": "UDP"
  },
  {
    "id": "gta_v_fivem",
    "name": "Grand Theft Auto V / FiveM",
    "category": "Action",
    "executables": ["GTA5.exe", "FiveM.exe", "FiveM_GTAProcess.exe", "FiveM_b3258_GTAProcess.exe", "RockstarService.exe"],
    "auth_domains": ["socialclub.rockstargames.com", "rockstargames.com", "keymaster.fivem.net", "cfx.re"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "battlefield_2042",
    "name": "Battlefield 2042",
    "category": "Shooter",
    "executables": ["BF2042.exe", "BF2042Trial.exe", "EAAntiCheat.GameServiceLauncher.exe", "EADesktop.exe"],
    "auth_domains": ["ea.com", "accounts.ea.com", "tnt-ea.com", "rtm.tnt-ea.com"],
    "cloud_providers": ["AWS", "Microsoft Azure"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "dead_by_daylight",
    "name": "Dead by Daylight",
    "category": "Horror",
    "executables": ["DeadByDaylight.exe", "DeadByDaylight-Win64-Shipping.exe", "EasyAntiCheat.exe", "steam.exe"],
    "auth_domains": ["steam.live.bhvrdbd.com", "cdn.live.bhvrdbd.com", "api.live.bhvrdbd.com", "bhvr.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "genshin_impact",
    "name": "Genshin Impact",
    "category": "RPG",
    "executables": ["GenshinImpact.exe", "launcher.exe", "QtWebEngineProcess.exe"],
    "auth_domains": ["account.mihoyo.com", "api-os-takumi.mihoyo.com", "hk4e-sdk-os.mihoyo.com", "hoyoverse.com"],
    "cloud_providers": ["AWS", "Alibaba Cloud", "Cloudflare"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "world_of_warcraft",
    "name": "World of Warcraft",
    "category": "MMORPG",
    "executables": ["Wow.exe", "WowClassic.exe", "Battle.net.exe", "Agent.exe"],
    "auth_domains": ["account.battle.net", "oauth.battle.net", "us.battle.net", "battle.net"],
    "cloud_providers": ["AWS", "Microsoft Azure"],
    "primary_protocol": "Hybrid"
  },
  {
    "id": "rust",
    "name": "Rust",
    "category": "Survival",
    "executables": ["RustClient.exe", "Rust.exe", "EasyAntiCheat.exe", "steam.exe"],
    "auth_domains": ["companion-rust.facepunch.com", "rust.authfacepunch.com", "facepunch.com", "steamcommunity.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "escape_from_tarkov",
    "name": "Escape from Tarkov",
    "category": "Tactical Shooter",
    "executables": ["EscapeFromTarkov.exe", "BsgLauncher.exe"],
    "auth_domains": ["launcher.escapefromtarkov.com", "profile.tarkov.com", "gw-pvp.eft.tarkov.com", "escapefromtarkov.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  },
  {
    "id": "brawlhalla",
    "name": "Brawlhalla",
    "category": "Fighting",
    "executables": ["Brawlhalla.exe", "steam.exe", "UbisoftConnect.exe"],
    "auth_domains": ["oauth.brawlhalla.com", "live.patcher.brawlhalla.com", "brawlhalla.com", "ubisoft.com"],
    "cloud_providers": ["AWS", "Cloudflare"],
    "primary_protocol": "UDP"
  }
]
''';
    final List<dynamic> decoded = jsonDecode(rawJson);
    return decoded.map((j) => GameItem.fromJson(j)).toList();
  }
}
/// سرویس هوشمند مدیریت و دانلود خودکار آی‌پی‌های دی‌ان‌اس لوکال (هر ۴۸ ساعت یک‌بار)
class LocalDnsService {
  static final LocalDnsService _instance = LocalDnsService._internal();
  factory LocalDnsService() => _instance;
  LocalDnsService._internal();

  DateTime? lastUpdated;
  Map<String, String> ipMappings = {};

  Future<void> init() async {
    await _loadFromDisk();
    // بررسی اینکه آیا ۴۸ ساعت از آخرین آپدیت گذشته است یا خیر
    if (shouldAutoUpdate()) {
      syncOnlineMappings();
    }
  }

  bool shouldAutoUpdate() {
    if (lastUpdated == null) return true;
    return DateTime.now().difference(lastUpdated!).inHours >= 48;
  }

  /// دانلود لیست جدیدترین آی‌پی‌ها از گیت‌هاب و ذخیره روی دیسک
  Future<bool> syncOnlineMappings() async {
    try {
      final url = Uri.parse('https://raw.githubusercontent.com/Devtahas/RedCloud-windows/main/gaming_dns_ips.json');
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final Map<String, dynamic> decoded = jsonDecode(res.body);
        final Map<String, String> cleanMap = {};
        decoded.forEach((k, v) => cleanMap[k] = v.toString());
        ipMappings = cleanMap;
        lastUpdated = DateTime.now();
        await _saveToDisk();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _saveToDisk() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/local_dns_mapping.json');
      final tempFile = File('${Directory.systemTemp.path}\\RedCloud\\local_dns_mapping.json');

      final data = {
        'last_updated': lastUpdated?.toIso8601String(),
        'mappings': ipMappings,
      };
      final raw = jsonEncode(data);
      await file.writeAsString(raw);
      if (await tempFile.parent.exists()) {
        await tempFile.writeAsString(raw);
      }
    } catch (_) {}
  }

  Future<void> _loadFromDisk() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/local_dns_mapping.json');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final Map<String, dynamic> decoded = jsonDecode(raw);
        if (decoded['last_updated'] != null) {
          lastUpdated = DateTime.tryParse(decoded['last_updated']);
        }
        if (decoded['mappings'] != null) {
          final map = decoded['mappings'] as Map;
          ipMappings = map.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      }
    } catch (_) {}

    // در صورت نبود فایل یا اولین بار، مقادیر معتبر پیش‌فرض لود می‌شوند
    if (ipMappings.isEmpty) {
      ipMappings = _getDefaultPrebakedIpMappings();
    }
  }

  Map<String, String> _getDefaultPrebakedIpMappings() {
    return {
      // Valorant & Riot Games
      'auth.riotgames.com': '104.16.51.111',
      'clientconfig.rpg.riotgames.com': '104.18.3.111',
      'playerplatform.riotgames.com': '104.16.51.111',
      'entitlements.auth.riotgames.com': '104.18.3.111',
      'authenticate.riotgames.com': '104.16.51.111',

      // CS2 & Dota 2 & Steam (Valve)
      'api.steampowered.com': '23.50.21.11',
      'store.steampowered.com': '23.50.21.11',
      'steamcommunity.com': '23.50.21.11',
      'help.steampowered.com': '23.50.21.11',
      'cm01.cm.steampowered.com': '155.133.248.50',
      'dota2.com': '23.50.21.11',
      'valve.net': '208.64.202.69',

      // Call of Duty & Battle.net
      'prod.callofduty.com': '18.156.120.45',
      'profile.callofduty.com': '18.156.120.45',
      'accounts.activision.com': '18.156.120.45',
      'eu.actual.battle.net': '137.221.106.104',
      'account.battle.net': '137.221.106.104',
      'oauth.battle.net': '137.221.106.104',

      // Rainbow Six Siege & Ubisoft
      'public-ubiservices.ubi.com': '54.246.175.12',
      'ms-r6s-pc.ubisoft.com': '54.246.175.12',
      'account.ubisoft.com': '54.246.175.12',
      'connect.ubisoft.com': '54.246.175.12',

      // Apex Legends & EA Sports FC (FIFA)
      'accounts.ea.com': '159.153.64.161',
      'signin.ea.com': '159.153.64.161',
      'api1.origin.com': '159.153.64.161',
      'utas.fut.ea.com': '159.153.64.161',

      // Fortnite & Rocket League (Epic Games)
      'launcher-public-service-prod06.ol.epicgames.com': '3.216.145.105',
      'account.epicgames.com': '3.216.145.105',
      'api.rlpp.psynet.gg': '3.216.145.105',

      // PUBG: Battlegrounds
      'accounts.pubg.com': '99.86.38.102',
      'api.pubg.com': '99.86.38.102',

      // GTA V & FiveM
      'socialclub.rockstargames.com': '104.18.23.19',
      'keymaster.fivem.net': '104.26.15.220',

      // Genshin Impact
      'account.mihoyo.com': '47.254.88.55',
      'api-os-takumi.mihoyo.com': '47.254.88.55',

      // Rust & Escape from Tarkov
      'companion-rust.facepunch.com': '104.22.65.115',
      'launcher.escapefromtarkov.com': '104.20.208.21',
      'profile.tarkov.com': '104.20.208.21',
    };
  }
}