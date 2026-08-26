; =====================================================================
; اسکریپت ساخت فایل نصب اختصاصی نرم‌افزار RedCloud VPN (نسخه 3.5 Hybrid)
; =====================================================================

#define AppName "RedCloud VPN"
#define AppVersion "3.5"
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

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "اجرای خودکار برنامه با بالا آمدن ویندوز (Startup)"; GroupDescription: "تنظیمات اضافی:"; Flags: unchecked

[Files]
; فایل‌های اجرایی و بیلد اصلی فلاتر
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

; باینری‌های هسته‌های اختصاصی برنامه
Source: "aether.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "sing-box.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "tor.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "psiphon-tunnel-core.exe"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "wintun.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

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
Root: "HKLM"; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\{#AppExeName}"; ValueData: "~ RUNASADMIN"; Flags: uninsdeletevalue

[Run]
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM psiphon-tunnel-core.exe"; Flags: runhidden runascurrentuser; StatusMsg: "آماده‌سازی محیط..."
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
Filename: "taskkill.exe"; Parameters: "/F /IM {#AppExeName} /IM aether.exe /IM sing-box.exe /IM tor.exe /IM psiphon-tunnel-core.exe"; Flags: runhidden
Filename: "reg.exe"; Parameters: "add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"" /v ProxyEnable /t REG_DWORD /d 0 /f"; Flags: runhidden
Filename: "powershell.exe"; Parameters: "-Command ""Get-NetAdapter | Where-Object {{$_.Status -eq 'Up'} | Set-DnsClientServerAddress -ResetServerAddresses"""; Flags: runhidden