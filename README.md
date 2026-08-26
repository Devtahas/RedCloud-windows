<div align="center">

# 🛡️ RedCloud VPN (نسخه ۳.۵ هیبریدی)
### کلاینت نسل جدید ضدسانسور، فوق‌سریع و چند‌هسته‌ای برای ویندوز
**مجهز به پل ترکیبی MASQUE H3، هسته Sing-box 1.13، شبکه‌های Tor و Psiphon**

[![Latest Release](https://img.shields.io/github/v/release/Devtahas/RedCloud-windows?color=6C5DD3&label=Release&style=for-the-badge&logo=github)](https://github.com/Devtahas/RedCloud-windows/releases/latest)
[![Platform](https://img.shields.io/badge/Platform-Windows%20x64-blue?style=for-the-badge&logo=windows)](https://github.com/Devtahas/RedCloud-windows/releases/latest)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?style=for-the-badge&logo=flutter)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-Native_Core-DEA584?style=for-the-badge&logo=rust)](https://www.rust-lang.org)
[![License](https://img.shields.io/badge/License-GPL--3.0-green?style=for-the-badge)](LICENSE)
[![Telegram](https://img.shields.io/badge/Telegram-Channel-229ED9?style=for-the-badge&logo=telegram)](https://t.me/DevTaha_project)

<br/>

<img src="assets/app_icon.ico" width="110" height="110" alt="RedCloud Logo" />

<p align="center">
  <b>ردکلاود (RedCloud)</b> یک کلاینت همه‌فن‌حریف و پیشرفته برای دور زدن شدیدترین اختلالات و فیلترینگ اینترنت است که با ترکیب قدرت <b>Flutter</b> و هسته بومی <b>Rust</b> ساخته شده است.
</p>

[📥 دانلود فایل نصبی مستقیم](https://github.com/Devtahas/RedCloud-windows/releases/latest) • [📢 کانال تلگرام](https://t.me/DevTaha_project) • [📖 راهنمای کاربری](#-راهنمای-استفاده) • [❤️ حمایت مالی](#-حمایت-مالی-از-پروژه)

</div>

---

## 📸 تصاویر محیط نرم‌افزار (Screenshots)

<div align="center">
  <table>
    <tr>
      <td width="50%">
        <h4 align="center">داشبورد ویتوری و اتصال هیبریدی</h4>
        <img src="docs/screenshots/dashboard.png" alt="داشبورد ویتوری" />
      </td>
      <td width="50%">
        <h4 align="center">شبکه ضدسانسور اِتر (MASQUE H3)</h4>
        <img src="docs/screenshots/aether.png" alt="شبکه اتر" />
      </td>
    </tr>
    <tr>
      <td width="50%">
        <h4 align="center">پیکربندی سرورها (Reality & Hysteria 2)</h4>
        <img src="docs/screenshots/config.png" alt="پیکربندی سرورها" />
      </td>
      <td width="50%">
        <h4 align="center">اسکنر موازی آی‌پی‌های کلودفلر</h4>
        <img src="docs/screenshots/scanner.png" alt="اسکنر کلودفلر" />
      </td>
    </tr>
    <tr>
      <td width="50%">
        <h4 align="center">تغییر دهنده هوشمند DNS (DoH / DoT)</h4>
        <img src="docs/screenshots/dns.png" alt="تغییر دهنده DNS" />
      </td>
      <td width="50%">
        <h4 align="center">تنظیمات پیشرفته ضد DPI و جعل هویت</h4>
        <img src="docs/screenshots/anti_dpi.png" alt="تنظیمات ضد DPI" />
      </td>
    </tr>
  </table>
</div>

---

## ✨ قابلیت‌ها و ویژگی‌های کلیدی

### ⚡️ ۱. فناوری اتصال هیبریدی انقلابی (Hybrid Bridge)
ترافیک شما ابتدا از پل رمزنگاری‌شده فوق‌پایدار **Aether (HTTP/3 QUIC)** عبور کرده و سپس به هسته قدرتمند **Sing-box** زنجیره‌سازی می‌شود. این متد مسدودسازی‌های فیلترینگ را دور زده و سرعت آپلود/دانلود حداکثری بدون بافر ایجاد می‌کند.

### 🌐 ۲. پشتیبانی از مدرن‌ترین پروتکل‌های ضدسانسور
* **Hysteria 2 (`hy2://`):** الگوریتم کنترل ازدحام اختصاصی بر بستر UDP برای عبور پرسرعت از پکت‌لاس‌های شدید شبکه.
* **VLESS Reality (`pbk`, `sid`, `spx`):** بدون نیاز به دامنه با جعل کامل هویت وب‌سایت‌های خارجی معتبر.
* **MASQUE H3 & H2:** اتصال مستقیم به شبکه Zero Trust کلودفلر با پروتکل HTTP/3.
* **VLESS / Trojan / WireGuard / Gool (WARP-in-WARP).**

### 🛡️ ۳. کارت شبکه مجازی سیستمی (TUN Mode)
* مجهز به درایور رسمی **Wintun.dll**
* عبور دادن ۱۰۰٪ ترافیک کل رایانه (شامل بازی‌های آنلاین، برنامه‌های بدون پروکسی، خط فرمان و کلاینت‌ها)
* جلوگیری کامل از نشت اطلاعات (DNS Leak & WebRTC Leak Protection).

### 🔍 ۴. اسکنر موازی آی‌پی‌های تمیز کلودفلر
* تست هم‌زمان TCP Ping و TLS Handshake برای یافتن کم‌تاخیرترین و تمیزترین آی‌پی‌های Cloudflare.
* اتصال مستقیم به ریپازیتوری برای بارگذاری و چرخش خودکار اکانت‌های فعال.

### 🎮 ۵. تغییردهنده هوشمند تحریم‌شکن DNS
* بدون نیاز به روشن کردن VPN، تحریم‌های سایت‌های هوش مصنوعی، دیسکورد، اپیک‌گیمز، گیت‌هاب و داکر را دور بزنید.
* پشتیبانی از DNSهای رمزنگاری‌شده DoH (کلودفلر، ادگارد، نکست‌دی‌ان‌اس) و تحریم‌شکن‌های بومی (شکن، الکترو، ۴۰۳ آنلاین، رادار گیم).

### 🔒 ۶. جعبه‌ابزار پیشرفته ضد DPI
* **شبیه‌ساز اثر انگشت (uTLS Fingerprint):** جعل کامل هویت بسته دست‌دهی به شکل مرورگر Google Chrome، Firefox یا Safari.
* **قطعه‌بندی پکت‌ها (TLS Fragmentation & Record Fragmentation):** خرد کردن بسته‌ها جهت جلوگیری از خوانده شدن SNI توسط حسگرهای فیلترینگ.
* **تزریق دامنه فیک (TLS Spoofing):** دور زدن فیلترینگ هوشمند با تزریق هدر مجاز مانند `zoom.us`.

---

## 🚀 راهنمای دانلود و نصب

### نصب آسان با فایل Setup (پیشنهادی)
1. به **[صفحه آخرین انتشار (Releases)](https://github.com/Devtahas/RedCloud-windows/releases/latest)** بروید.
2. فایل نصبی **`RedCloud_VPN_Setup_v3.5.exe`** را از بخش **Assets** دانلود کنید.
3. فایل را اجرا کرده و مراحل نصب را به‌سادگی طی کنید (برنامه به‌صورت خودکار در منوی استارت و دسکتاپ قرار می‌گیرد).

> [!TIP]
> برنامه دارای قابلیت اجرای در پس‌زمینه (System Tray کنار ساعت ویندوز) و اجرای خودکار با بالا آمدن ویندوز (Startup) است.

---

## 🛠️ کامپایل و بیلد از سورس‌کد (برای توسعه‌دهندگان)

### پیش‌نیازها:
* **Flutter SDK** (نسخه ۳.۲۲ به بالا)
* **Rust Toolchain** (نسخه Stable)
* **Inno Setup 6** (برای ساخت فایل نصبی)

```powershell
# ۱. کلون کردن ریپازیتوری
git clone https://github.com/Devtahas/RedCloud-windows.git
cd RedCloud-windows

# ۲. نصب ابزار کدهای پل Rust-Dart
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked
flutter_rust_bridge_codegen generate

# ۳. دریافت پکیج‌های فلاتر
flutter pub get

# ۴. اجرای برنامه در حالت توسعه (Debug)
flutter run -d windows

# ۵. بیلد نسخه نهایی (Release)
flutter build windows --release

# ۶. ساخت فایل ستاپ ویندوز
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
💡 ساختار پروژه


📁 RedCloud-windows/
├── 📁 lib/                   <-- رابط کاربری و لاجیک کلاینت (Flutter)
│   └── 📄 main.dart
├── 📁 rust/                  <-- هسته نیتیو و کنترل فرآیندها (Rust)
│   ├── 📁 src/api/simple.rs
│   └── 📄 Cargo.toml
├── 📁 .github/workflows/     <-- سیستم بیلد خودکار CI/CD (GitHub Actions)
│   └── 📄 release.yml
├── 📄 installer.iss          <-- اسکریپت ساخت فایل نصبی Inno Setup
└── 📄 pubspec.yaml           <-- تنظیمات و پکیج‌های فلاتر


❤️ حمایت مالی از پروژه
توسعه، نگهداری و ارتقای مداوم سرورهای ضدسانسور نیازمند منابع مالی و سرورهای پایدار است. اگر این نرم‌افزار برای شما مفید بوده است، با حمایت مالی خود به بقا و گسترش اینترنت آزاد کمک کنید:
پ
شبکه (Network)	ارز (Asset)	آدرس ولت (Wallet Address)
BNB Smart Chain (BEP20)	USDT (تتر)	0xDeda28Aa73Ec089A77B3fC616E0011a8fce12900

📢 ارتباط با ما
کانال رسمی تلگرام: DevTaha Project
گزارش باگ و پیشنهادات: بخش Issues گیت‌هاب

ساخته شده با ❤️ برای آزادی اینترنت و حق دسترسی آزاد به اطلاعات برای همه
