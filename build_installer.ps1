$ErrorActionPreference = "Stop"

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "      RedCloud VPN - Auto Release & Installer Build  " -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Cyan

# Step 1: Rust and Flutter Bindings
Write-Host "`n[1/4] Generating Rust/Flutter Bindings..." -ForegroundColor Yellow
flutter_rust_bridge_codegen generate
if ($LASTEXITCODE -ne 0) {
    Write-Host "[-] Error in Codegen! Process aborted." -ForegroundColor Red
    exit 1
}

# Step 2: Build Flutter Windows Release
Write-Host "`n[2/4] Building Flutter Windows Release..." -ForegroundColor Yellow
flutter build windows --release
if ($LASTEXITCODE -ne 0) {
    Write-Host "[-] Error in Flutter Release Build!" -ForegroundColor Red
    exit 1
}

# Step 3: Check Required Core Binaries
Write-Host "`n[3/4] Checking Core Binaries in root folder..." -ForegroundColor Yellow
$requiredFiles = @("aether.exe", "sing-box.exe", "tor.exe", "psiphon-tunnel-core.exe", "wintun.dll", "cloudflare_IPs.txt")
foreach ($file in $requiredFiles) {
    if (Test-Path $file) {
        Write-Host "  [+] Found: $file" -ForegroundColor Green
    } else {
        Write-Host "  [-] Warning: $file not found in root directory!" -ForegroundColor Magenta
    }
}

# Step 4: Compile Inno Setup Installer
Write-Host "`n[4/4] Compiling Setup Installer with Inno Setup..." -ForegroundColor Yellow
$isccPath = ""
$possiblePaths = @(
    "ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe"
)

foreach ($p in $possiblePaths) {
    if (Get-Command $p -ErrorAction SilentlyContinue) {
        $isccPath = $p
        break
    } elseif (Test-Path $p) {
        $isccPath = $p
        break
    }
}

if ($isccPath -ne "") {
    & $isccPath "installer.iss"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n=====================================================" -ForegroundColor Green
        Write-Host "  [+] BUILD SUCCESSFUL! Setup installer created:    " -ForegroundColor Green
        Write-Host "  [+] RedCloud_VPN_Setup_v3.5.exe                   " -ForegroundColor Cyan
        Write-Host "=====================================================" -ForegroundColor Green
    } else {
        Write-Host "[-] Error during Inno Setup packaging!" -ForegroundColor Red
    }
} else {
    Write-Host "[-] Inno Setup 6 (ISCC.exe) not found! Please install Inno Setup or compile installer.iss manually." -ForegroundColor Red
}