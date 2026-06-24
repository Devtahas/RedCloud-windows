; سناریوی ساخت اینستالر حرفه‌ای برای نرم‌افزار RedCloud VPN
#define AppName "RedCloud VPN"
#define AppVersion "2.5"
#define AppPublisher "RedCloud"
#define AppExeName "client.exe"

[Setup]
AppId={{9F2C0E8D-D8A1-4F43-9831-C7D4E75A22E1}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
; ذخیره فایل نصب‌کننده در ریشه پروژه
OutputDir=.
OutputBaseFilename=RedCloud_Setup
; مسیر نسبی آیکون برنامه
SetupIconFile=assets\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern
; درخواست دسترسی ادمین (Administrator) برای کارهای سیستمی و نصب در Program Files
PrivilegesRequired=admin

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; مسیر نسبی پوشه ریلیز فلاتر به جای آدرس مطلق درایو D
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
Root: "HKLM"; Subkey: "SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\{#AppExeName}"; ValueData: "RUNASADMIN"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent