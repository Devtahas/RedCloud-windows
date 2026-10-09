; =====================================================================
; اسکریپت ساخت فایل نصب اختصاصی نرم‌افزار RedCloud VPN
; مجهز به هسته اِتر، فرانتینگ CDN سایفون، درایور کرنل WinDivert و Sing-box
; =====================================================================

#define AppName "RedCloud VPN"
#define AppVersion "4.6"
#define AppPublisher "RedCloud Technologies"
#define AppExeName "client.exe"
#define AppURL "https://github.com/Devtahas/RedCloud-windows"
#define AppSupportURL "https://t.me/DevTaha_project"

[Setup]
AppId={{9F2C0E8D-D8A1-4F43-9831-C7D4E75A22E1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppSupportURL}

DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes

OutputDir=.
OutputBaseFilename=RedCloud_VPN_Setup_v{#AppVersion}
SetupIconFile=assets\app_icon.ico

; تنظیمات متادیتای ویندوز جهت جلوگیری از شناسایی به عنوان بدافزار ناشناس توسط آنتی‌ویروس‌ها
VersionInfoVersion=4.6.0.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=RedCloud VPN Next-Gen Anti-Censorship Client for Windows
VersionInfoCopyright=Copyright (C) 2026 {#AppPublisher}
VersionInfoProductName={#AppName}
VersionInfoProductVersion=4.6.0.0

Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog

CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "اجرای خودکار برنامه با بالا آمدن ویندوز (Startup Task)"; GroupDescription: "تنظیمات اضافی:"; Flags: unchecked

[Files]
; فایل‌های اجرایی و خروجی بیلد نهایی فلاتر
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Excludes: "*.pdb,*.obj,*.lib,*.exp"; Flags: recursesubdirs createallsubdirs ignoreversion

; باینری‌های هسته‌های اصلی برنامه
Source: "aether.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "sing-box.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "tor.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "psiphon-tunnel-core.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "shirokhorshid.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "udp2raw.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "slipnet.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "whitedns.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "wintun.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; پوشه حیاتی ترنسپورت‌های فرانتینگ اِتر و سایفون
Source: "pt\*"; DestDir: "{app}\pt"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

; هسته محافظتی و ضد مسمومیت DNSCrypt
Source: "dnscrypt-proxy.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "dnscrypt-proxy.toml"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; فایل‌های کانفیگ احتمالی اِتر
Source: "aether*.toml"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; استخر ۱۹۳ اکانت اختصاصی اِتر (پوشه ATC)
Source: "ATC\*"; DestDir: "{app}\ATC"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist

; هسته محافظتی و افکت ضد DPI به همراه درایور پکت ویندوز
Source: "goodbyedpi.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "WinDivert.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "WinDivert64.sys"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; فایل‌های دیتابیس کلودفلر، تور، ژئولوکیشن و مخزن DNS
Source: "*_IPs.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip6"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip-plus-asn"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip6-plus-asn"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "DNS.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; تنظیم اجرای همیشگی برنامه به عنوان Administrator در سطح سیستم و کاربر
Root: "HKLM"; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\{#AppExeName}"; ValueData: "~ RUNASADMIN"; Flags: uninsdeletevalue
Root: "HKCU"; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\{#AppExeName}"; ValueData: "~ RUNASADMIN"; Flags: uninsdeletevalue

[Run]
; ۱. بستن پروسه‌های معلق
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM shirokhorshid.exe /IM psiphon-tunnel-core.exe /IM goodbyedpi.exe /IM dnscrypt-proxy.exe /IM udp2raw.exe /IM slipnet.exe /IM whitedns.exe"; Flags: runhidden; StatusMsg: "آماده‌سازی محیط..."

; ۲. ثبت تسک زمان‌بندی‌شده جهت اجرای خودکار با دسترسی ادمین در استارتاپ (بدون مسدود شدن توسط UAC ویندوز)
Filename: "schtasks.exe"; Parameters: "/Create /TN ""{#AppName}"" /TR """"{app}\{#AppExeName}"""" /SC ONLOGON /RL HIGHEST /F"; Flags: runhidden; Tasks: autostart

; ۳. اجرای نهایی نرم‌افزار
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall shellexec

[UninstallRun]
; بستن تمام فرآیندها و هسته‌های فعال هنگام حذف نرم‌افزار
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM shirokhorshid.exe /IM psiphon-tunnel-core.exe /IM goodbyedpi.exe /IM dnscrypt-proxy.exe /IM udp2raw.exe /IM slipnet.exe /IM whitedns.exe"; Flags: runhidden

; حذف تسک استارتاپ از Task Scheduler
Filename: "schtasks.exe"; Parameters: "/Delete /TN ""{#AppName}"" /F"; Flags: runhidden

; متوقف‌سازی سرویس درایور WinDivert در ویندوز
Filename: "net.exe"; Parameters: "stop WinDivert"; Flags: runhidden
Filename: "net.exe"; Parameters: "stop WinDivert14"; Flags: runhidden

; خاموش کردن و بازنشانی پروکسی سیستم در رجیستری ویندوز
Filename: "reg.exe"; Parameters: "add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"" /v ProxyEnable /t REG_DWORD /d 0 /f"; Flags: runhidden

; بازگرداندن تنظیمات DNS تمامی کارت‌های شبکه به حالت خودکار (DHCP)
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -Command ""Get-NetAdapter | Where-Object {{$_.Status -eq 'Up'}} | Set-DnsClientServerAddress -ResetServerAddresses"""; Flags: runhidden

[UninstallDelete]
; پاکسازی فایل‌های لاگ و کش‌های ایجادشده در پوشه برنامه
Type: files; Name: "{app}\*.log"
Type: files; Name: "{app}\*.txt"
Type: files; Name: "{app}\*.json"

[Code]
procedure WriteSetupLog(Level, Tag, Msg: String);
var
  LogDir, LogFile, TimeStr, LogLine: String;
begin
  try
    LogDir := AddBackslash(GetTempDir()) + 'RedCloud';
    LogFile := LogDir + '\log.txt';
    ForceDirectories(LogDir);
    TimeStr := GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':');
    LogLine := Format('[%s] [%s] [%s] %s' + #13#10, [TimeStr, Level, Tag, Msg]);
    SaveStringToFile(LogFile, LogLine, True);
  except
  end;
end;

function InitializeSetup(): Boolean;
begin
  WriteSetupLog('INFO', 'SETUP', '==================================================');
  WriteSetupLog('INFO', 'SETUP', 'آغاز فرآیند نصب نرم‌افزار RedCloud VPN نسخه ' + '{#AppVersion}');
  WriteSetupLog('INFO', 'SETUP', 'دسترسی روت / ادمین: تایید شد');
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  case CurStep of
    ssInstall:
    begin
      // بستن درایورها و پروسه‌ها قبل از استخراج فایل‌ها برای جلوگیری از خطای Access is denied
      Exec('taskkill.exe', '/F /IM {#AppExeName} /IM goodbyedpi.exe /IM aether.exe /IM sing-box.exe /IM tor.exe /IM shirokhorshid.exe /IM psiphon-tunnel-core.exe /IM dnscrypt-proxy.exe /IM udp2raw.exe /IM slipnet.exe /IM whitedns.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Exec('net.exe', 'stop WinDivert', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Exec('net.exe', 'stop WinDivert14', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      WriteSetupLog('INFO', 'SETUP', 'شروع فرآیند استخراج باینری‌ها، ترنسپورت‌های CDN، درایورها و هسته‌ها...');
    end;
    ssPostInstall:
      WriteSetupLog('INFO', 'SETUP', 'تمامی فایل‌ها با موفقیت کپی و کلیدهای ریجستری ثبت شدند.');
    ssDone:
      WriteSetupLog('INFO', 'SETUP', 'نصب برنامه نسخه ' + '{#AppVersion}' + ' با موفقیت به پایان رسید.');
  end;
end;

function InitializeUninstall(): Boolean;
begin
  WriteSetupLog('INFO', 'UNINSTALL', '==================================================');
  WriteSetupLog('INFO', 'UNINSTALL', 'آغاز فرآیند حذف کامل نرم‌افزار RedCloud VPN...');
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  case CurUninstallStep of
    usUninstall:
      WriteSetupLog('INFO', 'UNINSTALL', 'در حال متوقف‌سازی هسته‌ها، سرویس‌های درایور و بازنشانی تنظیمات شبکه و DNS...');
    usPostUninstall:
      WriteSetupLog('INFO', 'UNINSTALL', 'نرم‌افزار با موفقیت و پاکسازی کامل از ویندوز حذف شد.');
  end;
end;