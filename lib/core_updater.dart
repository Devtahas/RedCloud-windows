// lib/core_updater.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'translations.dart';

/// مدل اطلاعات و وضعیت هر هسته قابل دانلود یا آپدیت
class CoreItem {
  final String id;
  final String name;
  final String repo;
  final String targetExeName;
  final String? assetKeyword;
  final bool isDirectExe;
  final bool isPinned;
  String currentVersion;
  String latestVersion;
  String? downloadUrl;
  bool hasUpdate;
  bool isUpdating;
  bool isInstalled;

  CoreItem({
    required this.id,
    required this.name,
    required this.repo,
    required this.targetExeName,
    this.assetKeyword,
    this.isDirectExe = false,
    this.isPinned = false,
    this.currentVersion = '1.0.0',
    this.latestVersion = 'Unknown',
    this.downloadUrl,
    this.hasUpdate = false,
    this.isUpdating = false,
    this.isInstalled = false,
  });
}

/// سرویس مدیریت، دانلود اولیه و بروزرسانی خودکار هسته‌های اصلی
class CoreUpdaterService {
  static final List<CoreItem> updatableCores = [
    CoreItem(
      id: 'aether',
      name: 'Aether (MASQUE Engine)',
      repo: 'CluvexStudio/Aether',
      targetExeName: 'aether.exe',
      assetKeyword: 'aether-windows-x86_64.zip',
      currentVersion: 'v1.9.0',
      downloadUrl:
          'https://github.com/CluvexStudio/Aether/releases/latest/download/aether-windows-x86_64.zip',
    ),
    CoreItem(
      id: 'goodbyedpi',
      name: 'GoodbyeDPI & WinDivert',
      repo: 'ValdikSS/GoodbyeDPI',
      targetExeName: 'goodbyedpi.exe',
      assetKeyword: 'goodbyedpi-',
      currentVersion: 'v0.2.3rc3',
      downloadUrl:
          'https://github.com/ValdikSS/GoodbyeDPI/releases/download/0.2.3rc3/goodbyedpi-0.2.3rc3.zip',
    ),
    CoreItem(
      id: 'dnscrypt',
      name: 'DNSCrypt-Proxy (Anti-Poisoning)',
      repo: 'DNSCrypt/dnscrypt-proxy',
      targetExeName: 'dnscrypt-proxy.exe',
      assetKeyword: 'dnscrypt-proxy-win64-',
      currentVersion: 'v2.1.5',
      downloadUrl:
          'https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.5/dnscrypt-proxy-win64-2.1.5.zip',
    ),
    CoreItem(
      id: 'udp2raw',
      name: 'udp2raw (FakeTCP Booster)',
      repo: 'wangyu-/udp2raw-multiplatform',
      targetExeName: 'udp2raw.exe',
      assetKeyword: 'udp2raw_mp_binaries.tar.gz',
      currentVersion: 'Latest',
      downloadUrl:
          'https://github.com/wangyu-/udp2raw-multiplatform/releases/download/20230206.0/udp2raw_mp_binaries.tar.gz',
    ),
    CoreItem(
      id: 'psiphon',
      name: 'Psiphon Core',
      repo: 'Psiphon-Labs/psiphon-tunnel-core-binaries',
      targetExeName: 'psiphon-tunnel-core.exe',
      isDirectExe: true,
      currentVersion: 'Latest',
      downloadUrl:
          'https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/windows/psiphon-tunnel-core-i686.exe',
    ),
  ];

  /// دریافت پوشه هدف برای فایل‌های اجرایی
  static Future<Directory> getTargetDirectory() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    if (kReleaseMode) {
      return exeDir;
    }
    if (File('${Directory.current.path}\\pubspec.yaml').existsSync()) {
      return Directory.current;
    }
    return exeDir;
  }



  /// بررسی فیزیکی وجود فایل هسته روی هارد دیسک
  static Future<bool> checkCoreInstalled(CoreItem core) async {
    final targetDir = await getTargetDirectory();
    final primaryFile = File('${targetDir.path}\\${core.targetExeName}');
    if (primaryFile.existsSync()) {
      core.isInstalled = true;
      return true;
    }

    final exeDir = File(Platform.resolvedExecutable).parent;
    final fallbackExe = File('${exeDir.path}\\${core.targetExeName}');
    if (fallbackExe.existsSync()) {
      core.isInstalled = true;
      return true;
    }

    final currentDirFile = File('${Directory.current.path}\\${core.targetExeName}');
    if (currentDirFile.existsSync()) {
      core.isInstalled = true;
      return true;
    }

    core.isInstalled = false;
    return false;
  }

  /// به‌روزرسانی وضعیت نصب بودن تمامی هسته‌ها
  static Future<void> refreshInstallationStatus() async {
    for (var core in updatableCores) {
      await checkCoreInstalled(core);
    }
  }

  /// فایل کش ذخیره نسخه‌ها در AppData
  static Future<File> _getVersionCacheFile() async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return File('${directory.path}/saved_core_versions.json');
  }

  /// بارگذاری نسخه‌های محلی و بررسی وضعیت نصب
  static Future<void> loadSavedVersions() async {
    try {
      final file = await _getVersionCacheFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);
        for (var core in updatableCores) {
          if (data.containsKey(core.id)) {
            core.currentVersion = data[core.id].toString();
          }
        }
      }
    } catch (_) {}
    await refreshInstallationStatus();
  }

  /// ذخیره نسخه‌های دانلود شده
  static Future<void> _saveCurrentVersions() async {
    try {
      final file = await _getVersionCacheFile();
      final Map<String, String> data = {};
      for (var core in updatableCores) {
        data[core.id] = core.currentVersion;
      }
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  /// بستن پروسه قدیمی هسته
  static Future<void> _killCoreProcess(String exeName) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('taskkill', ['/F', '/IM', exeName], runInShell: true);
      if (exeName.toLowerCase().contains('goodbyedpi')) {
        await Process.run('net', ['stop', 'WinDivert'], runInShell: true);
        await Process.run('net', ['stop', 'WinDivert14'], runInShell: true);
      }
    } catch (_) {}
  }

  /// دریافت خودکار لینک دانلود از گیت‌هاب
  static Future<void> resolveCoreDownloadUrl(CoreItem core) async {
    try {
      final uri = Uri.parse('https://api.github.com/repos/${core.repo}/releases/latest');
      final response = await http.get(
        uri,
        headers: {
          'User-Agent': 'RedCloud-Core-Updater',
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 7));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final tagName = (data['tag_name'] ?? '').toString().trim();
        if (tagName.isNotEmpty) core.latestVersion = tagName;

        final List<dynamic> assets = data['assets'] ?? [];
        for (var asset in assets) {
          final String name = (asset['name'] ?? '').toString().toLowerCase();
          if (core.assetKeyword != null && name.contains(core.assetKeyword!.toLowerCase())) {
            core.downloadUrl = asset['browser_download_url'] ?? core.downloadUrl;
            break;
          }
        }

        if (assets.isNotEmpty) {
          for (var asset in assets) {
            final String name = (asset['name'] ?? '').toString().toLowerCase();
            if ((name.contains('windows') || name.contains('win64')) &&
                (name.endsWith('.zip') || name.endsWith('.tar.gz') || name.endsWith('.exe'))) {
              core.downloadUrl = asset['browser_download_url'] ?? core.downloadUrl;
              break;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Fallback link used for ${core.name}');
    }
  }

  /// استعلام آنلاین نسخه‌های جدید از گیت‌هاب
  static Future<void> checkUpdates({Function(String status)? onStatus}) async {
    await loadSavedVersions();

    for (var core in updatableCores) {
      if (core.isPinned) {
        await checkCoreInstalled(core);
        continue;
      }

      onStatus?.call(AppTranslations.isRtl
          ? 'در حال بررسی وضعیت ${core.name}...'
          : 'Checking status for ${core.name}...');

      await resolveCoreDownloadUrl(core);
      await checkCoreInstalled(core);

      if (core.latestVersion != 'Unknown' && core.isInstalled) {
        if (core.currentVersion != core.latestVersion &&
            !core.currentVersion.contains(core.latestVersion.replaceAll('v', ''))) {
          core.hasUpdate = true;
        } else {
          core.hasUpdate = false;
        }
      }
    }
  }

  /// استخراج آرشیوهای فشرده با ابزارهای ویندوز
  static Future<bool> _extractArchiveWindows(String archivePath, String extractDir) async {
    try {
      final lower = archivePath.toLowerCase();
      if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) {
        final res = await Process.run(
          'tar',
          ['-xzf', archivePath, '-C', extractDir],
          runInShell: true,
        );
        return res.exitCode == 0;
      } else {
        final res = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Expand-Archive -Path "$archivePath" -DestinationPath "$extractDir" -Force'
          ],
          runInShell: true,
        );
        return res.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
  }

  /// دانلود، نصب و استخراج هسته
  static Future<bool> updateSingleCore(
    CoreItem core, {
    Function(String status, double progress)? onProgress,
  }) async {
    final bool isEn = !AppTranslations.isRtl;

    if (core.downloadUrl == null || core.downloadUrl!.isEmpty) {
      onProgress?.call(
        isEn ? 'Resolving download link for ${core.name}...' : 'در حال دریافت آدرس دانلود ${core.name}...',
        0.1,
      );
      await resolveCoreDownloadUrl(core);
      if (core.downloadUrl == null || core.downloadUrl!.isEmpty) {
        onProgress?.call(
          isEn ? 'Failed to get download URL for ${core.name}' : 'آدرس دانلود برای ${core.name} یافت نشد!',
          0.0,
        );
        return false;
      }
    }

    core.isUpdating = true;
    final bool isFirstInstall = !core.isInstalled;
    onProgress?.call(
      isFirstInstall
          ? (isEn ? 'Preparing to download ${core.name}...' : 'آماده‌سازی برای دانلود ${core.name}...')
          : (isEn ? 'Preparing to update ${core.name}...' : 'آماده‌سازی برای بروزرسانی ${core.name}...'),
      0.15,
    );

    try {
      await _killCoreProcess(core.targetExeName);

      final tempDir = Directory('${Directory.systemTemp.path}\\RedCloud_Core_Update');
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
      await tempDir.create(recursive: true);

      final targetDir = await getTargetDirectory();

      onProgress?.call(
        isEn ? 'Downloading ${core.name}...' : 'در حال دانلود فایل‌های رسمی ${core.name}...',
        0.3,
      );

      final client = http.Client();
      final request = http.Request('GET', Uri.parse(core.downloadUrl!));
      request.headers['User-Agent'] = 'RedCloud-Core-Updater';

      final response = await client.send(request);
      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final lowerUrl = core.downloadUrl!.toLowerCase();
      final isArchive = lowerUrl.endsWith('.zip') || lowerUrl.endsWith('.tar.gz') || lowerUrl.endsWith('.tgz');
      final downloadedFileName = isArchive
          ? (lowerUrl.endsWith('.zip') ? 'archive.zip' : 'archive.tar.gz')
          : core.targetExeName;
      final downloadedFilePath = '${tempDir.path}\\$downloadedFileName';
      final file = File(downloadedFilePath);
      final sink = file.openWrite();

      final totalBytes = response.contentLength ?? 0;
      var receivedBytes = 0;

      await response.stream.listen((chunk) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        if (totalBytes > 0) {
          final progress = 0.3 + ((receivedBytes / totalBytes) * 0.4);
          onProgress?.call(
            isEn
                ? 'Downloading: ${(receivedBytes / (1024 * 1024)).toStringAsFixed(1)} MB'
                : 'در حال دریافت: ${(receivedBytes / (1024 * 1024)).toStringAsFixed(1)} مگابایت',
            progress,
          );
        }
      }).asFuture();

      await sink.flush();
      await sink.close();
      client.close();

      onProgress?.call(
        isEn ? 'Extracting & Placing files...' : 'در حال استخراج و جای‌گذاری در مسیر برنامه...',
        0.75,
      );

      if (isArchive) {
        final extractDir = '${tempDir.path}\\extracted';
        final extractDirObj = Directory(extractDir);
        await extractDirObj.create(recursive: true);

        final extractSuccess = await _extractArchiveWindows(downloadedFilePath, extractDir);
        if (!extractSuccess) {
          throw Exception('Failed to extract archive.');
        }

        final allFiles = extractDirObj.listSync(recursive: true).whereType<File>();

        File? exeFile;
        // انتخاب هوشمند نسخه بدون نیاز به درایور pcap برای ویندوز
        if (core.id == 'udp2raw') {
          exeFile = allFiles.cast<File?>().firstWhere(
            (f) => f?.uri.pathSegments.last.toLowerCase() == 'udp2raw_mp_wepoll.exe',
            orElse: () => null,
          );
        }

        exeFile ??= allFiles.firstWhere(
          (f) {
            final fName = f.uri.pathSegments.last.toLowerCase();
            final target = core.targetExeName.toLowerCase();
            if (fName == target) return true;
            if (core.id == 'udp2raw' && fName.contains('udp2raw') && fName.endsWith('.exe')) return true;
            if (core.id == 'dnscrypt' && fName.contains('dnscrypt') && fName.endsWith('.exe')) return true;
            if (core.id == 'goodbyedpi' && fName.contains('goodbyedpi') && fName.endsWith('.exe')) return true;
            if (core.id == 'singbox' && fName.contains('sing-box') && fName.endsWith('.exe')) return true;
            return false;
          },
          orElse: () => throw Exception('${core.targetExeName} not found in archive'),
        );

        final destPath = '${targetDir.path}\\${core.targetExeName}';
        await exeFile.copy(destPath);

        if (core.id == 'goodbyedpi') {
          for (var f in allFiles) {
            final fileName = f.uri.pathSegments.last.toLowerCase();
            if (fileName == 'windivert.dll' || fileName == 'windivert64.sys') {
              final driverDest = '${targetDir.path}\\${f.uri.pathSegments.last}';
              try {
                await f.copy(driverDest);
              } catch (_) {}
            }
          }
        }

        if (core.id == 'dnscrypt') {
          for (var f in allFiles) {
            final fileName = f.uri.pathSegments.last.toLowerCase();
            if (fileName == 'example-dnscrypt-proxy.toml' || fileName == 'dnscrypt-proxy.toml') {
              final tomlDest = '${targetDir.path}\\dnscrypt-proxy.toml';
              if (!File(tomlDest).existsSync()) {
                try {
                  await f.copy(tomlDest);
                } catch (_) {}
              }
            }
          }
        }
      } else {
        final destPath = '${targetDir.path}\\${core.targetExeName}';
        await file.copy(destPath);
      }

      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}

      core.isInstalled = true;
      if (core.latestVersion != 'Unknown') {
        core.currentVersion = core.latestVersion;
      }
      core.hasUpdate = false;
      await _saveCurrentVersions();
      await checkCoreInstalled(core);

      onProgress?.call(
        isFirstInstall
            ? (isEn ? '${core.name} installed successfully!' : '${core.name} با موفقیت دانلود و نصب شد!')
            : (isEn ? '${core.name} updated successfully!' : '${core.name} با موفقیت بروزرسانی شد!'),
        1.0,
      );

      return true;
    } catch (e) {
      debugPrint('Error installing/updating ${core.name}: $e');
      onProgress?.call(
        isEn ? 'Operation failed: $e' : 'خطا در عملیات: $e',
        0.0,
      );
      return false;
    } finally {
      core.isUpdating = false;
    }
  }

  /// دانلود یا بروزرسانی تمام هسته‌ها
  static Future<void> updateAllAvailableCores({
    Function(String status, double progress)? onProgress,
  }) async {
    final bool isEn = !AppTranslations.isRtl;
    await refreshInstallationStatus();

    final targets = updatableCores.where((c) => !c.isInstalled || c.hasUpdate).toList();
    if (targets.isEmpty) {
      onProgress?.call(
        isEn ? 'All core engines are installed and up to date.' : 'تمام هسته‌ها نصب و بروز هستند.',
        1.0,
      );
      return;
    }

    for (int i = 0; i < targets.length; i++) {
      final core = targets[i];
      await updateSingleCore(
        core,
        onProgress: (status, p) {
          final overallProgress = (i / targets.length) + (p / targets.length);
          onProgress?.call(status, overallProgress);
        },
      );
    }
    await refreshInstallationStatus();
  }
}