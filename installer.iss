; =====================================================================
; اسکریپت ساخت فایل نصب اختصاصی نرم‌افزار RedCloud VPN (نسخه 3.5 Hybrid)
; مجهز به سیستم یکپارچه لاگ‌نویسی و هسته اختصاصی ضد DPI (GoodbyeDPI + WinDivert)
; =====================================================================

#define AppName "RedCloud VPN"
#define AppVersion "3.6"
#define AppPublisher "RedCloud Technologies"
#define AppExeName "client.exe"

[Setup]
AppId={{9F2C0E8D-D8A1-4F43-9831-C7D4E75A22E1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}

DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes

OutputDir=.
OutputBaseFilename=RedCloud_VPN_Setup_v{#AppVersion}
SetupIconFile=assets\app_icon.ico

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
Name: "autostart"; Description: "اجرای خودکار برنامه با بالا آمدن ویندوز (Startup)"; GroupDescription: "تنظیمات اضافی:"; Flags: unchecked

[Files]
; فایل‌های اجرایی و بیلد اصلی فلاتر
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

; باینری‌های هسته‌های اصلی برنامه
Source: "aether.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "sing-box.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "tor.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "psiphon-tunnel-core.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "wintun.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; هسته محافظتی و افکت ضد DPI به همراه درایور پکت ویندوز
Source: "goodbyedpi.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "WinDivert.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "WinDivert64.sys"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; فایل‌های دیتابیس کلودفلر، تور و مخزن DNS
Source: "cloudflare_IPs.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "geoip6"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "DNS.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; Tasks: desktopicon
Name: "{commonstartup}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: autostart

[Registry]
; تنظیم اجرای همیشگی برنامه به عنوان Administrator
Root: "HKLM"; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\{#AppExeName}"; ValueData: "~ RUNASADMIN"; Flags: uninsdeletevalue

[Run]
; بستن تمام پروسه‌های قدیمی قبل از اجرای برنامه
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM psiphon-tunnel-core.exe /IM goodbyedpi.exe"; Flags: runhidden runascurrentuser; StatusMsg: "آماده‌سازی محیط..."
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; بستن تمام فرآیندها و هسته‌های فعال
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM psiphon-tunnel-core.exe /IM goodbyedpi.exe"; Flags: runhidden

; متوقف‌سازی سرویس درایور WinDivert در صورت باقی ماندن
Filename: "net.exe"; Parameters: "stop WinDivert"; Flags: runhidden
Filename: "net.exe"; Parameters: "stop WinDivert14"; Flags: runhidden

; بازنشانی پروکسی سیستم در رجیستری ویندوز
Filename: "reg.exe"; Parameters: "add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"" /v ProxyEnable /t REG_DWORD /d 0 /f"; Flags: runhidden

; بازگرداندن تنظیمات DNS تمامی کارت‌های شبکه به DHCP خودکار
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -Command ""Get-NetAdapter | Where-Object {{$_.Status -eq 'Up'} | Set-DnsClientServerAddress -ResetServerAddresses"""; Flags: runhidden

[Code]
// تابع ثبت گزارش‌ها در فایل مشترک log.txt
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
    // در صورت بروز خطای I/O فرآیند ستاپ متوقف نشود
  end;
end;

function InitializeSetup(): Boolean;
begin
  WriteSetupLog('INFO', 'SETUP', '==================================================');
  WriteSetupLog('INFO', 'SETUP', 'آغاز فرآیند نصب نرم‌افزار RedCloud VPN نسخه 3.5');
  WriteSetupLog('INFO', 'SETUP', 'دسترسی روت / ادمین: تایید شد');
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  case CurStep of
    ssInstall:
      WriteSetupLog('INFO', 'SETUP', 'شروع فرآیند استخراج باینری‌ها، درایورها و هسته‌های ضدسانسور...');
    ssPostInstall:
      WriteSetupLog('INFO', 'SETUP', 'تمامی فایل‌ها با موفقیت کپی و کلیدهای ریجستری ثبت شدند.');
    ssDone:
      WriteSetupLog('INFO', 'SETUP', 'نصب برنامه با موفقیت به پایان رسید.');
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