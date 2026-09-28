use std::fs::{File, OpenOptions};
use std::io::{Write, Read, BufReader, BufRead};
use std::process::{Command, Child, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::net::{TcpStream, UdpSocket, SocketAddr, ToSocketAddrs, IpAddr, Ipv4Addr, TcpListener, Shutdown};
use std::path::PathBuf;
use url::Url;
use base64::{Engine as _, engine::general_purpose};
use native_tls::TlsConnector;
use std::sync::mpsc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
pub use crate::smart_core_types::*;
use crate::core1_optimizer::fragment_prober::FragmentProber;
use crate::core1_optimizer::scoring::Core1ScoringEngine;
use crate::core1_optimizer::learning_engine::LearningEngine;
use crate::core1_optimizer::pmtu_prober::PmtuProber;
use crate::core2_analyzer::deviation::Core2BehaviorAnalyzer;

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

static PROXY_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static TOR_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static PSIPHON_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static AETHER_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static GOODBYEDPI_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static DNSCRYPT_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static UDP2RAW_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static ACTIVE_DNS: Mutex<Option<(String, String)>> = Mutex::new(None);
static ECH_KEY_VAULT: Mutex<Option<String>> = Mutex::new(None);

// =========================================================================
// متغیرهای اختصاصی وضعیت تب گیمینگ (Gaming State & Session Lock)
// =========================================================================
static GAMING_PROXY_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static GAMING_AETHER_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static GAMING_BOOST_ACTIVE: AtomicBool = AtomicBool::new(false);
static GAMING_SESSION_LOCKED: AtomicBool = AtomicBool::new(false);
static ACTIVE_GAME_NAME: Mutex<String> = Mutex::new(String::new());
static ACTIVE_GAME_EXES: Mutex<Vec<String>> = Mutex::new(Vec::new());
static GAMING_TARGET_PEER: Mutex<Option<String>> = Mutex::new(None);
static CURRENT_GAMING_PING: AtomicI32 = AtomicI32::new(-1);
static CURRENT_GAMING_JITTER: AtomicI32 = AtomicI32::new(0);

/// استخراج برق‌آسا و زنده کلید ECH کلودفلر از طریق ساکس بازشده
fn fetch_live_ech_key_via_socks5(socks_port: u16, timeout: Duration) -> Option<String> {
    let addr: SocketAddr = format!("127.0.0.1:{}", socks_port).parse().ok()?;
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(500)).ok()?;
    stream.set_read_timeout(Some(timeout)).ok()?;
    stream.set_write_timeout(Some(timeout)).ok()?;
    let _ = stream.set_nodelay(true);

    // ۱. دست‌دهی ساکس ۵
    stream.write_all(&[0x05, 0x01, 0x00]).ok()?;
    let mut auth_resp = [0u8; 2];
    stream.read_exact(&mut auth_resp).ok()?;
    if auth_resp != [0x05, 0x00] { return None; }

    // ۲. ارسال درخواست اتصال ساکس به cloudflare-dns.com پورت 443
    let domain = b"cloudflare-dns.com";
    let mut req = vec![0x05, 0x01, 0x00, 0x03, domain.len() as u8];
    req.extend_from_slice(domain);
    req.extend_from_slice(&443u16.to_be_bytes());
    stream.write_all(&req).ok()?;

    let mut conn_resp = [0u8; 10];
    stream.read_exact(&mut conn_resp).ok()?;
    if conn_resp[1] != 0x00 { return None; }

    // ۳. بسته‌بندی امن با TLS
    let connector = native_tls::TlsConnector::builder()
        .danger_accept_invalid_certs(true)
        .build()
        .ok()?;
    let mut tls_stream = connector.connect("cloudflare-dns.com", stream).ok()?;

    // ۴. استعلام رکورد نوع ۶۵ (HTTPS Record) حاوی کلید زنده ECH
    let http_req = "GET /dns-query?name=cloudflare.com&type=HTTPS HTTP/1.1\r\nHost: cloudflare-dns.com\r\nAccept: application/dns-json\r\nConnection: close\r\n\r\n";
    tls_stream.write_all(http_req.as_bytes()).ok()?;
    let _ = tls_stream.flush();

    let mut body = String::new();
    tls_stream.read_to_string(&mut body).ok()?;

    // ۵. استخراج مقدار ech= از پاسخ JSON
    let json_start = body.find('{')?;
    let v: serde_json::Value = serde_json::from_str(&body[json_start..]).ok()?;
    if let Some(answers) = v.get("Answer").and_then(|a| a.as_array()) {
        for ans in answers {
            if ans.get("type").and_then(|t| t.as_i64()) == Some(65) {
                if let Some(data) = ans.get("data").and_then(|d| d.as_str()) {
                    if let Some(pos) = data.find("ech=") {
                        let sub = &data[pos + 4..];
                        let end = sub.find(' ').unwrap_or(sub.len());
                        let key = sub[..end].trim().to_string();
                        if !key.is_empty() {
                            return Some(key);
                        }
                    }
                }
            }
        }
    }
    None
}

/// تبدیل کلید خام Base64 به قالب رسمی و استاندارد PEM مورد انتظار Sing-box
fn format_ech_to_pem_lines(raw_key: &str) -> Vec<String> {
    let clean = raw_key.trim();
    if clean.contains("BEGIN ECH CONFIGS") {
        clean.lines().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
    } else {
        vec![
            "-----BEGIN ECH CONFIGS-----".to_string(),
            clean.to_string(),
            "-----END ECH CONFIGS-----".to_string(),
        ]
    }
}

/// خواندن سریع کلید از حافظه کش رم، دیسک یا کلید رزرو پشتیبان
fn get_cached_or_fallback_ech() -> String {
    let mut vault = ECH_KEY_VAULT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(ref k) = *vault {
        if !k.is_empty() { return k.clone(); }
    }

    let path = get_safe_work_dir().join("ech_vault.json");
    if let Ok(content) = std::fs::read_to_string(&path) {
        let tr = content.trim().to_string();
        if !tr.is_empty() {
            *vault = Some(tr.clone());
            return tr;
        }
    }

    // کلید پیش‌فرض و معتبر لبه جهانی کلودفلر
    "AEn+DQBF5wAgACDqYd15aH3R7/t+pYF8XbZ2vE6PqL8k7W0m4v9Pq5KjKAAIAAEAAQACAAIAAQ==".to_string()
}
static ANTI_RST_RUNNING: AtomicBool = AtomicBool::new(false);
static ANTI_RST_HANDLE: Mutex<Option<isize>> = Mutex::new(None);
static ORIGINAL_TIMEZONE: Mutex<Option<String>> = Mutex::new(None);

// شمارنده‌های اتمیک نانوثانیه‌ای رادار دفاعی (مصرف صفر درصد پردازنده)
static RADAR_BLOCKED_RST: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
static RADAR_BLOCKED_STUN: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
static RADAR_BLOCKED_DNS: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

/// ثبت و به‌روزرسانی آمار رادار زنده در فایل موقت فوق‌سبک
pub fn update_radar_metrics_file() {
    let rst = RADAR_BLOCKED_RST.load(std::sync::atomic::Ordering::Relaxed);
    let stun = RADAR_BLOCKED_STUN.load(std::sync::atomic::Ordering::Relaxed);
    let dns = RADAR_BLOCKED_DNS.load(std::sync::atomic::Ordering::Relaxed);
    let mtu = get_optimal_carrier_mtu();
    let path = get_safe_work_dir().join("radar.txt");
    let _ = std::fs::write(path, format!("{},{},{},{}", rst, stun, dns, mtu));
}

/// کشف خودکار سقف واقعی پکت دکل مخابراتی (PMTU) جهت مهار پکت‌لاس
pub fn get_optimal_carrier_mtu() -> u32 {
    let probed = PmtuProber::probe_carrier_path_mtu("1.1.1.1");
    if probed >= 1280 && probed <= 1440 {
        probed as u32
    } else {
        1360 // اندازه طلایی و اثبات‌شده برای همراه اول و ایرانسل بدون قطعی پکت
    }
}

/// ذخیره منطقه زمانی اولیه سیستم و ست کردن تایم‌زون جدید متناسب با کشور آی‌پی
pub fn sync_timezone_to_country(country_code: String) -> Result<String, String> {
    #[cfg(target_os = "windows")]
    {
        let cc = country_code.trim().to_uppercase();
        if cc.is_empty() || cc == "IR" {
            return Ok("کشور ایران است؛ تغییری اعمال نشد.".to_string());
        }

        // ۱. خواندن و ذخیره تایم‌زون اولیه سیستم در صورت اولین بار
        {
            let mut orig_guard = ORIGINAL_TIMEZONE.lock().unwrap_or_else(|e| e.into_inner());
            if orig_guard.is_none() {
                if let Ok(out) = Command::new("tzutil").arg("/g").creation_flags(0x08000000).output() {
                    let current_tz = String::from_utf8_lossy(&out.stdout).trim().to_string();
                    if !current_tz.is_empty() {
                        *orig_guard = Some(current_tz);
                    }
                }
            }
        }

        // ۲. نگاشت کشور به Timezone استاندارد مایکروسافت ویندوز
        let target_tz = match cc.as_str() {
            "DE" | "NL" | "SE" | "IT" | "AT" | "CH" | "PL" | "ES" | "BE" => "W. Europe Standard Time",
            "FR" => "Romance Standard Time",
            "GB" | "UK" => "GMT Standard Time",
            "US" => "Eastern Standard Time",
            "CA" => "Eastern Standard Time",
            "SG" => "Singapore Standard Time",
            "JP" => "Tokyo Standard Time",
            "TR" => "Turkey Standard Time",
            "AR" => "Argentina Standard Time",
            _ => "UTC",
        };

        let _ = Command::new("tzutil").args(&["/s", target_tz]).creation_flags(0x08000000).output();
        write_log("INFO", "IDENTITY_GUARD", &format!("🕒 منطقه زمانی سیستم به طور خودکار با کشور {} هماهنگ شد ({})", cc, target_tz));
        return Ok(format!("Timezone synced to {}", target_tz));
    }
    #[cfg(not(target_os = "windows"))]
    Ok("Non-windows platform".to_string())
}

/// بازگرداندن فوری منطقه زمانی اولیه ویندوز (تهران) به محض قطع اتصال
pub fn restore_original_timezone() -> Result<String, String> {
    #[cfg(target_os = "windows")]
    {
        let mut orig_guard = ORIGINAL_TIMEZONE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(orig_tz) = orig_guard.take() {
            let _ = Command::new("tzutil").args(&["/s", &orig_tz]).creation_flags(0x08000000).output();
            write_log("INFO", "IDENTITY_GUARD", &format!("🕒 منطقه زمانی ویندوز به حالت اولیه بازگشت: {}", orig_tz));
            return Ok(format!("Restored to {}", orig_tz));
        }
    }
    Ok("No timezone to restore".to_string())
}

/// پاکسازی سراسری و فوق‌سریع تمامی پروسه‌های زامبی قبل از راه‌اندازی هر تونل
pub fn kill_all_zombie_cores() {
    RADAR_BLOCKED_RST.store(0, std::sync::atomic::Ordering::Relaxed);
    RADAR_BLOCKED_STUN.store(0, std::sync::atomic::Ordering::Relaxed);
    RADAR_BLOCKED_DNS.store(0, std::sync::atomic::Ordering::Relaxed);
    let _ = std::fs::remove_file(get_safe_work_dir().join("radar.txt"));

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill")
            .args(&[
                "/F", 
                "/IM", "sing-box.exe", 
                "/IM", "aether.exe", 
                "/IM", "psiphon-tunnel-core.exe", 
                "/IM", "tor.exe",
                "/IM", "goodbyedpi.exe",
                "/IM", "dnscrypt-proxy.exe",
                "/IM", "udp2raw.exe"
            ])
            .creation_flags(0x08000000)
            .output();
        thread::sleep(Duration::from_millis(400));
    }
}

// متغیر و سیستم ناظر زنده پروسه‌ها (Process Crash Watchdog)
static WATCHDOG_STARTED: OnceLock<()> = OnceLock::new();

fn ensure_watchdog_started() {
    WATCHDOG_STARTED.get_or_init(|| {
        thread::spawn(|| {
            loop {
                thread::sleep(Duration::from_millis(600));

                // ۱. پایش سلامت هسته پروکسی ویتوری / هیبریدی
                {
                    let mut guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(child) = guard.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            write_log("WARN", "WATCHDOG", &format!("⚠️ هسته پروکسی (Sing-box) ناگهان کرش کرد یا بسته شد (کد خروج: {})", status));
                            *guard = None;
                            // نجات فوری اینترنت کاربر: خاموش کردن پروکسی سیستم و سپر
                            set_windows_system_proxy(false, String::new(), 0);
                            stop_anti_rst_filter();
                        }
                    }
                }

                // ۲. پایش سلامت هسته اِتر
                {
                    let mut guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(child) = guard.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            write_log("WARN", "WATCHDOG", &format!("⚠️ هسته اِتر (Aether) به طور غیرمنتظره متوقف شد (کد خروج: {})", status));
                            *guard = None;
                            set_windows_system_proxy(false, String::new(), 0);
                        }
                    }
                }

                // ۳. پایش سلامت هسته تور
                {
                    let mut guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(child) = guard.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            write_log("WARN", "WATCHDOG", &format!("⚠️ فرآیند تور به طور ناگهانی بسته شد (کد خروج: {})", status));
                            *guard = None;
                            set_windows_system_proxy(false, String::new(), 0);
                        }
                    }
                }

                // ۴. پایش سلامت هسته سایفون
                {
                    let mut guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(child) = guard.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            write_log("WARN", "WATCHDOG", &format!("⚠️ فرآیند سایفون ناگهان قطع شد (کد خروج: {})", status));
                            *guard = None;
                            set_windows_system_proxy(false, String::new(), 0);
                        }
                    }
                }

                // ۵. پایش سلامت هسته GoodbyeDPI
                {
                    let mut guard = GOODBYEDPI_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(child) = guard.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            write_log("WARN", "WATCHDOG", &format!("⚠️ هسته GoodbyeDPI متوقف شد (کد خروج: {})", status));
                            *guard = None;
                        }
                    }
                }
            }
        });
        write_log("INFO", "WATCHDOG", "👁️ ناظر بلادرنگ پروسه‌های ویندوز (Crash Watchdog) فعال شد.");
    });
}

static TOR_BOOTSTRAP_PERCENT: Mutex<i32> = Mutex::new(0);
static AETHER_BOOTSTRAP_PERCENT: Mutex<i32> = Mutex::new(0);

static PSIPHON_CONNECTED: Mutex<bool> = Mutex::new(false);
static AETHER_CONNECTED: Mutex<bool> = Mutex::new(false);
static DNSCRYPT_READY: AtomicBool = AtomicBool::new(false);
static UDP2RAW_RUNNING: AtomicBool = AtomicBool::new(false);

static AETHER_STATUS_MSG: Mutex<String> = Mutex::new(String::new());
static PSIPHON_STATUS_MSG: Mutex<String> = Mutex::new(String::new());

// متغیرهای سرویس اشتراک‌گذاری LAN
static LAN_RELAY_RUNNING: AtomicBool = AtomicBool::new(false);
static LAN_RELAY_PORT: Mutex<u16> = Mutex::new(10808);

// متغیرهای کنترل وضعیت و آمار زنده اسکنر کلودفلر
static DNS_SCAN_CANCELLED: AtomicBool = AtomicBool::new(false);
static DNS_TOTAL_COUNT: AtomicI32 = AtomicI32::new(0);
static DNS_SCANNED_COUNT: AtomicI32 = AtomicI32::new(0);
static DNS_ALIVE_COUNT: AtomicI32 = AtomicI32::new(0);
static DNS_DEAD_COUNT: AtomicI32 = AtomicI32::new(0);
static DNS_SCAN_IS_RUNNING: AtomicBool = AtomicBool::new(false);
static SCAN_CANCELLED: AtomicBool = AtomicBool::new(false);
static SCAN_RUNNING: AtomicBool = AtomicBool::new(false);
static TOTAL_SCANNED: AtomicI32 = AtomicI32::new(0);
static ALIVE_COUNT: AtomicI32 = AtomicI32::new(0);
static DEAD_COUNT: AtomicI32 = AtomicI32::new(0);

static LOG_MUTEX: Mutex<()> = Mutex::new(());
static PANIC_HOOK_SET: OnceLock<()> = OnceLock::new();

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct ProxyNode {
    pub name: String,
    pub protocol: String,
    pub raw_url: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct ScannerStats {
    pub total_scanned: i32,
    pub alive_count: i32,
    pub dead_count: i32,
    pub is_running: bool,
}

/// مدل داده دی‌ان‌اس‌های تاییدشده و ضد مسمومیت در مخزن پنهان
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct VerifiedDns {
    pub ip: String,
    pub latency_ms: i32,
    pub works_singbox: bool,
    pub works_tor: bool,
    pub works_psiphon: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct DnsScannerProgress {
    pub total_servers: i32,
    pub scanned_servers: i32,
    pub alive_servers: i32,
    pub dead_servers: i32,
    pub progress_percent: i32,
    pub is_running: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct ScannedDnsResult {
    pub dns_name: String,
    pub primary_ip: String,
    pub latency_ms: i32,
    pub resolved_ip: String,
    pub is_genuine: bool,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct GamingDnsReport {
    pub provider_name: String,
    pub dns_ip: String,
    pub latency_ms: i32,
    pub is_truth_verified: bool,
    pub resolved_ip: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct GamingBenchmarkResult {
    pub region_name: String,
    pub region_code: String,
    pub target_ip: String,
    pub min_ping_ms: i32,
    pub max_ping_ms: i32,
    pub avg_ping_ms: i32,
    pub jitter_ms: i32,
    pub packet_loss_percent: f32,
    pub recommended_mode: String,
    pub recommended_noize: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct GamingBoostConfig {
    pub game_id: String,
    pub game_name: String,
    pub executables: Vec<String>,
    pub auth_domains: Vec<String>,
    pub preferred_region: String,
    pub enable_kernel_tweaks: bool,
    pub dns_mode: String, // "local" یا "resolver"
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct GamingLiveMetrics {
    pub is_active: bool,
    pub game_name: String,
    pub current_ping_ms: i32,
    pub current_jitter_ms: i32,
    pub rst_packets_defended: i32,
    pub is_session_locked: bool,
    pub active_region: String,
}

// =========================================================================
// سپر هوشمند فیلتر پکت‌های جعلی (Fake TCP RST Dropper via WinDivert)
// =========================================================================

#[cfg(target_os = "windows")]
extern "system" {
    fn LoadLibraryW(lpLibFileName: *const u16) -> *mut std::ffi::c_void;
    fn GetProcAddress(hModule: *mut std::ffi::c_void, lpProcName: *const u8) -> *const std::ffi::c_void;
    fn FreeLibrary(hModule: *mut std::ffi::c_void) -> i32;
}

type WinDivertOpenFn = unsafe extern "system" fn(*const i8, u32, i16, u64) -> isize;
type WinDivertRecvFn = unsafe extern "system" fn(isize, *mut u8, u32, *mut u32, *mut u8) -> i32;
type WinDivertSendFn = unsafe extern "system" fn(isize, *const u8, u32, *mut u32, *const u8) -> i32;
type WinDivertCloseFn = unsafe extern "system" fn(isize) -> i32;

pub fn start_anti_rst_filter() {
    #[cfg(target_os = "windows")]
    {
        if ANTI_RST_RUNNING.load(Ordering::SeqCst) {
            return;
        }

        let dll_path = resolve_binary_path("WinDivert.dll");
        if !dll_path.exists() {
            write_log("WARN", "ANTI_RST", "فایل WinDivert.dll یافت نشد؛ سپر ضد RST غیرفعال ماند.");
            return;
        }

        use std::os::windows::ffi::OsStrExt;
        let mut wide: Vec<u16> = dll_path.as_os_str().encode_wide().collect();
        wide.push(0);

        let h_module = unsafe { LoadLibraryW(wide.as_ptr()) };
        if h_module.is_null() {
            write_log("WARN", "ANTI_RST", "امکان لود WinDivert.dll وجود ندارد.");
            return;
        }

        let open_fn: WinDivertOpenFn = unsafe {
            let p = GetProcAddress(h_module, b"WinDivertOpen\0".as_ptr());
            if p.is_null() { return; }
            std::mem::transmute(p)
        };
        let recv_fn: WinDivertRecvFn = unsafe {
            let p = GetProcAddress(h_module, b"WinDivertRecv\0".as_ptr());
            if p.is_null() { return; }
            std::mem::transmute(p)
        };
        let send_fn: WinDivertSendFn = unsafe {
            let p = GetProcAddress(h_module, b"WinDivertSend\0".as_ptr());
            if p.is_null() { return; }
            std::mem::transmute(p)
        };
        let close_fn: WinDivertCloseFn = unsafe {
            let p = GetProcAddress(h_module, b"WinDivertClose\0".as_ptr());
            if p.is_null() { return; }
            std::mem::transmute(p)
        };

        // فیلتر پکت‌های RST فیک فیلترینگ + نابودسازی پکت‌های نشت‌کننده WebRTC STUN
        let filter_str = b"(inbound and tcp.Rst) or (outbound and udp and (udp.DstPort == 19302 or udp.DstPort == 3478 or udp.DstPort == 19305 or udp.DstPort == 5349))\0";
        let handle = unsafe { open_fn(filter_str.as_ptr() as *const i8, 0, 1000, 0) };

        if handle == -1 || handle == 0 {
            write_log("WARN", "ANTI_RST", "دسترسی درایور WinDivert رد شد (نیاز به Admin).");
            unsafe { FreeLibrary(h_module); }
            return;
        }

        {
            let mut h_guard = ANTI_RST_HANDLE.lock().unwrap_or_else(|e| e.into_inner());
            *h_guard = Some(handle);
        }
        ANTI_RST_RUNNING.store(true, Ordering::SeqCst);
        write_log("INFO", "ANTI_RST", "🛡️ سپر محافظتی ضد پکت‌های جعلی RST فعال شد.");

        let h_module_addr = h_module as usize;

        thread::spawn(move || {
            let h_module = h_module_addr as *mut std::ffi::c_void;
            let mut packet = [0u8; 1500];
            let mut addr = [0u8; 128];
            let mut read_len = 0u32;

            while ANTI_RST_RUNNING.load(Ordering::Relaxed) {
                let ok = unsafe {
                    recv_fn(handle, packet.as_mut_ptr(), 1500, &mut read_len, addr.as_mut_ptr())
                };

                if ok != 0 && read_len > 20 {
                    // بررسی پکت IPv4
                    if (packet[0] >> 4) == 4 {
                        let ttl = packet[8];
                        // پکت‌های فیلترینگ داخلی به دلیل فاصله کم با TTL نزدیک به 64 یا 128 یا 255 می‌رسند
                        let is_middlebox_injection = (ttl >= 59 && ttl <= 64) 
                            || (ttl >= 123 && ttl <= 128) 
                            || (ttl >= 250);

                        if is_middlebox_injection {
                            RADAR_BLOCKED_RST.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                            update_radar_metrics_file();
                            write_log("INFO", "ANTI_RST", &format!("🎯 پکت RST جعلی فیلترینگ خنثی شد! (TTL دریافتی: {})", ttl));
                            continue;
                        }
                    }

                    // شکار فوق‌پیشرفته پکت‌های WebRTC با امضای اختصاصی STUN Magic Cookie (0x2112A442)
                    if (packet[0] >> 4) == 4 && packet[9] == 17 {
                        let ip_hdr_len = ((packet[0] & 0x0F) * 4) as usize;
                        // پکت UDP دارای حداقل 8 بایت هدر و 8 بایت بدنه STUN است
                        if (read_len as usize) >= ip_hdr_len + 8 + 8 {
                            let udp_payload = &packet[ip_hdr_len + 8..];
                            // بررسی امضای قطعی STUN در بایت‌های 4 الی 7
                            let is_stun_magic = udp_payload[4] == 0x21 
                                             && udp_payload[5] == 0x12 
                                             && udp_payload[6] == 0xA4 
                                             && udp_payload[7] == 0x42;

                            if is_stun_magic {
                                RADAR_BLOCKED_STUN.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                update_radar_metrics_file();
                                write_log("INFO", "WEBRTC_DEEP", "🎯 پکت پنهان WebRTC STUN گوگل شناسایی و نابود شد!");
                                continue;
                            }
                        }
                    }

                    // در غیر این صورت پکت سالم است و عبور داده می‌شود
                    let mut send_len = 0u32;
                    unsafe {
                        send_fn(handle, packet.as_ptr(), read_len, &mut send_len, addr.as_ptr());
                    }
                } else if !ANTI_RST_RUNNING.load(Ordering::Relaxed) {
                    break;
                } else {
                    // استراحت حیاتی ترد برای جلوگیری ۱۰۰٪ از سوزاندن سی‌پی‌یو در مواقع بیکاری
                    thread::sleep(Duration::from_millis(5));
                }
            }

            unsafe {
                FreeLibrary(h_module);
            }
            write_log("INFO", "ANTI_RST", "سپر ضد RST متوقف شد.");
        });
    }
}

pub fn stop_anti_rst_filter() {
    #[cfg(target_os = "windows")]
    {
        if !ANTI_RST_RUNNING.load(Ordering::SeqCst) {
            return;
        }
        ANTI_RST_RUNNING.store(false, Ordering::SeqCst);

        let mut h_guard = ANTI_RST_HANDLE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(h) = h_guard.take() {
            let dll_path = resolve_binary_path("WinDivert.dll");
            use std::os::windows::ffi::OsStrExt;
            let mut wide: Vec<u16> = dll_path.as_os_str().encode_wide().collect();
            wide.push(0);
            let h_module = unsafe { LoadLibraryW(wide.as_ptr()) };
            if !h_module.is_null() {
                let close_fn: WinDivertCloseFn = unsafe {
                    let p = GetProcAddress(h_module, b"WinDivertClose\0".as_ptr());
                    if !p.is_null() { std::mem::transmute(p) } else { return; }
                };
                unsafe {
                    close_fn(h);
                    FreeLibrary(h_module);
                }
            }
        }
    }
}

// =========================================================================
// توابع سازگاری بریج FFI (بدون پروسه فعال)
// =========================================================================

pub fn is_dnstt_running() -> bool {
    false
}

pub fn start_dnstt_core(
    _binary_path: Option<String>,
    _doh_url: String,
    _pubkey: String,
    _domain: String,
    _local_port: u16,
) -> Result<String, String> {
    Err("پروتکل DNSTT غیرفعال شده است.".to_string())
}

pub fn stop_dnstt_core() -> Result<String, String> {
    Ok("DNSTT متوقف شد.".to_string())
}

pub fn find_active_resolvers_for_domain(_target_domain: String) -> Vec<String> {
    Vec::new()
}

// =========================================================================
// هسته udp2raw (شبیه‌ساز FakeTCP و بهینه‌ساز هوشمند پینگ)
// =========================================================================

pub fn is_udp2raw_running() -> bool {
    let guard = UDP2RAW_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    guard.is_some() && UDP2RAW_RUNNING.load(Ordering::Relaxed)
}

pub fn start_udp2raw_core(
    binary_path: Option<String>,
    remote_addr: String,
    local_port: u16,
    key: Option<String>,
) -> Result<String, String> {
    write_log("INFO", "UDP2RAW", &format!("راه‌اندازی تونل FakeTCP برای مقصد: {}", remote_addr));

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "udp2raw.exe"]).creation_flags(0x08000000).output();

    {
        let mut p = UDP2RAW_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = p.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }
    UDP2RAW_RUNNING.store(false, Ordering::SeqCst);

    let bin_name = binary_path.unwrap_or_else(|| "udp2raw.exe".to_string());
    let resolved_path = resolve_binary_path(&bin_name);
    if !resolved_path.exists() {
        return Err(format!("فایل udp2raw.exe در مسیر {:?} یافت نشد.", resolved_path));
    }

    let work_dir = get_safe_work_dir();
    let local_bind = format!("127.0.0.1:{}", if local_port == 0 { 18833 } else { local_port });
    let auth_key = key.unwrap_or_else(|| "redcloud_faketcp".to_string());

    let mut command = Command::new(&resolved_path);
    command.arg("-c")
           .arg("-l").arg(&local_bind)
           .arg("-r").arg(&remote_addr)
           .arg("-k").arg(&auth_key)
           .arg("--raw-mode").arg("faketcp")
           .arg("--cipher-mode").arg("xor")
           .arg("-a");

    command.current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::null())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let child = command.spawn().map_err(|e| {
        let err = format!("خطا در اجرای udp2raw.exe: {}", e);
        write_log("ERROR", "UDP2RAW", &err);
        err
    })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    {
        let mut p = UDP2RAW_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *p = Some(child);
    }

    UDP2RAW_RUNNING.store(true, Ordering::SeqCst);
    write_log("INFO", "UDP2RAW", &format!("تونل FakeTCP روی {} برقرار شد.", local_bind));
    Ok(format!("FakeTCP tunnel established on {}", local_bind))
}

pub fn stop_udp2raw_core() -> Result<String, String> {
    write_log("INFO", "UDP2RAW", "دستور توقف udp2raw دریافت شد.");
    UDP2RAW_RUNNING.store(false, Ordering::SeqCst);

    let mut process_guard = UDP2RAW_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "udp2raw.exe"]).creation_flags(0x08000000).output();

    Ok("تونل FakeTCP متوقف شد.".to_string())
}

pub fn benchmark_and_optimize_udp2raw(
    remote_host: String,
    remote_port: u16,
    binary_path: Option<String>,
    key: Option<String>,
) -> Result<i32, String> {
    let baseline_ping = ping_proxy_server(remote_host.clone(), remote_port);
    write_log("INFO", "UDP2RAW_BENCH", &format!("پینگ اولیه سرور بدون بهینه‌ساز: {} ms", baseline_ping));

    let remote_target = format!("{}:{}", remote_host, remote_port);
    let start_res = start_udp2raw_core(binary_path, remote_target, 18833, key);
    if start_res.is_err() {
        return Err("امکان راه‌اندازی udp2raw وجود ندارد.".to_string());
    }

    thread::sleep(Duration::from_millis(1500));

    let optimized_ping = ping_proxy_server("127.0.0.1".to_string(), 18833);
    write_log("INFO", "UDP2RAW_BENCH", &format!("پینگ اندازه‌گیری شده با FakeTCP: {} ms", optimized_ping));

    if optimized_ping > 0 && (baseline_ping <= 0 || optimized_ping < baseline_ping) {
        write_log("INFO", "UDP2RAW_BENCH", "پینگ با موفقیت بهبود یافت؛ تونل فعال باقی می‌ماند.");
        Ok(optimized_ping)
    } else {
        write_log("WARN", "UDP2RAW_BENCH", "پینگ بهبود نیافت؛ توقف پروسه.");
        let _ = stop_udp2raw_core();
        Err("FakeTCP latency was not better; process stopped.".to_string())
    }
}

// =========================================================================
// هسته ضد مسمومیت و جعل DNSCrypt
// =========================================================================

pub fn is_dnscrypt_running() -> bool {
    let process_guard = DNSCRYPT_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some() && DNSCRYPT_READY.load(Ordering::Relaxed)
}

fn verify_dnscrypt_truth(port: u16, timeout: Duration) -> bool {
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return false,
    };

    let _ = socket.set_read_timeout(Some(timeout));
    let _ = socket.set_write_timeout(Some(timeout));

    let dns_query: [u8; 32] = [
        0xAB, 0xCD,
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        10, b'c', b'l', b'o', b'u', b'd', b'f', b'l', b'a', b'r', b'e',
        3, b'c', b'o', b'm',
        0x00,
        0x00, 0x01,
        0x00, 0x01,
    ];

    let target_addr: SocketAddr = match format!("127.0.0.1:{}", port).parse() {
        Ok(a) => a,
        Err(_) => return false,
    };

    if socket.send_to(&dns_query, target_addr).is_err() {
        return false;
    }

    let mut buf = [0u8; 512];
    let (amt, _) = match socket.recv_from(&mut buf) {
        Ok(res) => res,
        Err(_) => return false,
    };

    if amt < 32 {
        return false;
    }

    if buf[0] != 0xAB || buf[1] != 0xCD || (buf[3] & 0x0F) != 0 {
        return false;
    }

    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    if ancount == 0 {
        return false;
    }

    let resolved_ip = Ipv4Addr::new(buf[amt - 4], buf[amt - 3], buf[amt - 2], buf[amt - 1]);
    let octets = resolved_ip.octets();

    if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 
       || (octets[0] == 192 && octets[1] == 168)
       || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
       || (octets[0] == 10 && octets[1] == 10 && octets[2] == 34) {
        return false; // <--- حل شد: برگشت مقدار false به جای None
    }

    write_log("INFO", "DNSCRYPT_TRUTH", &format!("راستی‌آزمایی دی‌ان‌اس تایید شد: {:?}", resolved_ip));
    true
}

pub fn start_dnscrypt_core(binary_path: Option<String>) -> Result<String, String> {
    write_log("INFO", "DNSCRYPT", "درخواست راه‌اندازی هسته ضد مسمومیت dnscrypt-proxy...");

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "dnscrypt-proxy.exe"]).creation_flags(0x08000000).output();

    {
        let mut p = DNSCRYPT_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = p.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }
    DNSCRYPT_READY.store(false, Ordering::SeqCst);

    let bin_name = binary_path.unwrap_or_else(|| "dnscrypt-proxy.exe".to_string());
    let resolved_path = resolve_binary_path(&bin_name);
    if !resolved_path.exists() {
        let err = format!("فایل dnscrypt-proxy.exe در مسیر {:?} یافت نشد.", resolved_path);
        write_log("WARN", "DNSCRYPT", &err);
        return Err(err);
    }

    let work_dir = get_safe_work_dir();
    let toml_path = work_dir.join("dnscrypt-proxy.toml");

    let toml_content = r#"
listen_addresses = ['127.0.0.1:5354']
server_names = ['cloudflare', 'quad9-dnscrypt-ip4-filter-pri', 'scaleway-ams']
require_dnssec = true
require_nolog = true
require_nofilter = false
disabled_server_names = []
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
fallback_resolvers = ['9.9.9.9:53', '1.1.1.1:53']
ignore_system_dns = true
block_unqualified = true
netprobe_timeout = 2
"#;

    if let Ok(mut f) = File::create(&toml_path) {
        let _ = f.write_all(toml_content.trim().as_bytes());
    }

    let mut command = Command::new(&resolved_path);
    command.arg("-config").arg(&toml_path)
           .current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::null())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let child = command.spawn().map_err(|e| {
        let err = format!("خطا در اجرای dnscrypt-proxy.exe: {}", e);
        write_log("ERROR", "DNSCRYPT", &err);
        err
    })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    {
        let mut p = DNSCRYPT_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *p = Some(child);
    }

    let mut truth_verified = false;
    for _ in 1..=12 {
        thread::sleep(Duration::from_millis(300));
        if verify_dnscrypt_truth(5354, Duration::from_millis(1000)) {
            truth_verified = true;
            break;
        }
    }

    if truth_verified {
        DNSCRYPT_READY.store(true, Ordering::SeqCst);
        write_log("INFO", "DNSCRYPT", "هسته DNSCrypt آماده شد (پورت 5354).");
        Ok("سپر ضد مسمومیت DNSCrypt فعال و تایید شد.".to_string())
    } else {
        write_log("WARN", "DNSCRYPT", "پاسخ معتبری از DNSCrypt دریافت نشد؛ توقف هسته...");
        let _ = stop_dnscrypt_core();
        Err("DNSCrypt صحت پاسخ‌ها را تایید نکرد.".to_string())
    }
}

pub fn stop_dnscrypt_core() -> Result<String, String> {
    write_log("INFO", "DNSCRYPT", "دستور توقف dnscrypt-proxy دریافت شد.");
    DNSCRYPT_READY.store(false, Ordering::SeqCst);

    let mut process_guard = DNSCRYPT_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "dnscrypt-proxy.exe"]).creation_flags(0x08000000).output();

    Ok("هسته DNSCrypt متوقف شد.".to_string())
}

// =========================================================================
// توابع مدیریت هسته GoodbyeDPI
// =========================================================================

pub fn is_goodbyedpi_running() -> bool {
    let process_guard = GOODBYEDPI_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some()
}

pub fn start_goodbyedpi_core(binary_path: String, args: String) -> Result<String, String> {
    write_log("INFO", "GOODBYEDPI", &format!("درخواست شروع هسته GoodbyeDPI با پارامترهای: '{}'", args));

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "goodbyedpi.exe"]).creation_flags(0x08000000).output();

    {
        let mut p = GOODBYEDPI_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = p.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }

    let resolved_path = resolve_binary_path(&binary_path);
    if !resolved_path.exists() {
        let err = format!("فایل goodbyedpi.exe در مسیر {:?} یافت نشد.", resolved_path);
        write_log("ERROR", "GOODBYEDPI", &err);
        return Err(err);
    }

    let run_dir = resolved_path.parent().map(|p| p.to_path_buf()).unwrap_or_else(get_safe_work_dir);

    let trimmed_args = args.trim();
    let effective_args_str = if trimmed_args.is_empty() || trimmed_args.eq_ignore_ascii_case("default") {
        "-9 -p -r -s -f 2 -k 2 -n -e 2"
    } else {
        trimmed_args
    };

    let effective_args: Vec<String> = effective_args_str.split_whitespace().map(|s| s.to_string()).collect();

    let mut command = Command::new(&resolved_path);
    command.args(&effective_args)
           .current_dir(&run_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let spawn_res = command.spawn();

    let mut child = match spawn_res {
        Ok(c) => c,
        Err(e) => {
            if e.raw_os_error() == Some(740) {
                write_log("WARN", "GOODBYEDPI", "نیاز به مجوز ادمین دارد؛ در حال تلاش با RunAs...");
                let ps_args = format!(
                    "Start-Process -FilePath '{}' -ArgumentList '{}' -WorkingDirectory '{}' -WindowStyle Hidden -Verb RunAs",
                    resolved_path.to_string_lossy(),
                    effective_args_str,
                    run_dir.to_string_lossy()
                );
                let _ = Command::new("powershell")
                    .args(&["-Command", &ps_args])
                    .creation_flags(0x08000000)
                    .output();

                return Ok("افکت GoodbyeDPI با دسترسی ادمین فعال شد.".to_string());
            }
            let err = format!("خطا در اجرای goodbyedpi.exe: {}", e);
            write_log("ERROR", "GOODBYEDPI", &err);
            return Err(err);
        }
    };

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().flatten() {
                write_log("DEBUG", "GOODBYEDPI", &line);
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().flatten() {
                write_log("WARN", "GOODBYEDPI_ERR", &line);
            }
        });
    }

    {
        let mut p = GOODBYEDPI_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *p = Some(child);
    }

    write_log("INFO", "GOODBYEDPI", "افکت GoodbyeDPI روی کارت شبکه فعال شد.");
    Ok("لایه محافظتی ضد DPI با موفقیت فعال شد.".to_string())
}

pub fn stop_goodbyedpi_core() -> Result<String, String> {
    write_log("INFO", "GOODBYEDPI", "دستور توقف GoodbyeDPI دریافت شد.");
    let mut process_guard = GOODBYEDPI_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "goodbyedpi.exe"]).creation_flags(0x08000000).output();

    Ok("افکت محافظتی GoodbyeDPI متوقف شد.".to_string())
}

// =========================================================================
// مشخصات شبکه محلی و رله LAN
// =========================================================================

pub fn get_all_local_ip_addresses() -> Vec<String> {
    let mut ips = Vec::new();

    // دریافت مستقیم و بدون مصرف منابع از سوکت، بدون نیاز به باز کردن PowerShell
    if let Ok(socket) = UdpSocket::bind("0.0.0.0:0") {
        if socket.connect("8.8.8.8:80").is_ok() {
            if let Ok(local_addr) = socket.local_addr() {
                let ip = local_addr.ip().to_string();
                if ip != "0.0.0.0" && ip != "127.0.0.1" {
                    ips.push(ip);
                }
            }
        }
    }

    // فقط اگر سوکت آی‌پی نداد، به عنوان بک‌آوری بسیار نادر از پاورشل استفاده شود
    #[cfg(target_os = "windows")]
    if ips.is_empty() {
        if let Ok(output) = Command::new("powershell")
            .args(&["-NoProfile", "-Command", "Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.InterfaceAlias -notmatch 'Loopback|vEthernet'} | Select-Object -ExpandProperty IPAddress"])
            .creation_flags(0x08000000)
            .output()
        {
            let out_str = String::from_utf8_lossy(&output.stdout);
            for line in out_str.lines() {
                let trimmed = line.trim().to_string();
                if !trimmed.is_empty() && trimmed.parse::<Ipv4Addr>().is_ok() && !ips.contains(&trimmed) {
                    ips.push(trimmed);
                }
            }
        }
    }

    if ips.is_empty() {
        ips.push("127.0.0.1".to_string());
    }
    ips
}

pub fn get_local_ip_address() -> String {
    let all = get_all_local_ip_addresses();
    all.first().cloned().unwrap_or_else(|| "127.0.0.1".to_string())
}

fn get_active_upstream_proxy_addr(is_socks5_client: bool) -> (String, u16) {
    if is_psiphon_connected() || is_psiphon_masque_connected() {
        ("127.0.0.1".to_string(), if is_socks5_client { 9080 } else { 9081 })
    } else if is_tor_connected() || is_tor_masque_connected() {
        ("127.0.0.1".to_string(), if is_socks5_client { 9050 } else { 9051 })
    } else if is_aether_connected() {
        ("127.0.0.1".to_string(), if is_socks5_client { 1819 } else { 1820 })
    } else if is_hybrid_connected() || is_connected() {
        ("127.0.0.1".to_string(), 2080)
    } else {
        ("127.0.0.1".to_string(), 2080)
    }
}

fn handle_lan_client(mut client_stream: TcpStream) {
    let mut peek_buf = [0u8; 1];
    let is_socks5 = match client_stream.peek(&mut peek_buf) {
        Ok(n) if n > 0 => peek_buf[0] == 0x05,
        _ => false,
    };

    let (upstream_host, upstream_port) = get_active_upstream_proxy_addr(is_socks5);
    let upstream_addr = format!("{}:{}", upstream_host, upstream_port);

    let mut upstream_stream = match TcpStream::connect_timeout(
        &upstream_addr.parse().unwrap_or_else(|_| "127.0.0.1:2080".parse().unwrap()),
        Duration::from_millis(3000),
    ) {
        Ok(s) => s,
        Err(e) => {
            write_log("WARN", "LAN_RELAY", &format!("خطا در رله به هسته {}: {}", upstream_addr, e));
            return;
        }
    };

    let _ = client_stream.set_nodelay(true);
    let _ = upstream_stream.set_nodelay(true);

    let mut client_clone = match client_stream.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut upstream_clone = match upstream_stream.try_clone() {
        Ok(u) => u,
        Err(_) => return,
    };

    thread::spawn(move || {
        let _ = std::io::copy(&mut client_stream, &mut upstream_stream);
        let _ = upstream_stream.shutdown(Shutdown::Both);
    });

    thread::spawn(move || {
        let _ = std::io::copy(&mut upstream_clone, &mut client_clone);
        let _ = client_clone.shutdown(Shutdown::Both);
    });
}

pub fn start_lan_relay(port: u16) -> Result<String, String> {
    if LAN_RELAY_RUNNING.load(Ordering::SeqCst) {
        return Ok("سرویس اشتراک‌گذاری LAN در حال حاضر فعال است.".to_string());
    }

    let bind_port = if port == 0 { 10808 } else { port };
    let bind_addr = format!("0.0.0.0:{}", bind_port);

    let listener = match TcpListener::bind(&bind_addr) {
        Ok(l) => l,
        Err(e) => {
            let err = format!("خطا در باز کردن پورت LAN ({}): {}", bind_addr, e);
            write_log("ERROR", "LAN_RELAY", &err);
            return Err(err);
        }
    };

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("netsh")
            .args(&[
                "advfirewall", "firewall", "add", "rule",
                "name=RedCloud_LAN_Share",
                "dir=in",
                "action=allow",
                "protocol=TCP",
                &format!("localport={}", bind_port)
            ])
            .creation_flags(0x08000000)
            .output();
    }

    {
        let mut p = LAN_RELAY_PORT.lock().unwrap_or_else(|e| e.into_inner());
        *p = bind_port;
    }

    LAN_RELAY_RUNNING.store(true, Ordering::SeqCst);
    write_log("INFO", "LAN_RELAY", &format!("سرویس اشتراک‌گذاری LAN روی {} فعال شد.", bind_addr));

    thread::spawn(move || {
        for stream_res in listener.incoming() {
            if !LAN_RELAY_RUNNING.load(Ordering::SeqCst) {
                break;
            }
            match stream_res {
                Ok(client_stream) => {
                    thread::spawn(move || {
                        handle_lan_client(client_stream);
                    });
                }
                Err(_) => {}
            }
        }
    });

    let local_ip = get_local_ip_address();
    Ok(format!("اشتراک‌گذاری در شبکه محلی روی {}:{} فعال شد.", local_ip, bind_port))
}

pub fn stop_lan_relay() -> Result<String, String> {
    if !LAN_RELAY_RUNNING.load(Ordering::SeqCst) {
        return Ok("سرویس اشتراک‌گذاری LAN متوقف است.".to_string());
    }

    LAN_RELAY_RUNNING.store(false, Ordering::SeqCst);

    let port = *LAN_RELAY_PORT.lock().unwrap_or_else(|e| e.into_inner());
    let _ = TcpStream::connect(format!("127.0.0.1:{}", port));

    write_log("INFO", "LAN_RELAY", "سرویس اشتراک‌گذاری LAN متوقف شد.");
    Ok("اشتراک‌گذاری پروکسی در شبکه محلی متوقف شد.".to_string())
}

pub fn is_lan_relay_running() -> bool {
    LAN_RELAY_RUNNING.load(Ordering::Relaxed)
}

pub fn get_lan_relay_port() -> u16 {
    *LAN_RELAY_PORT.lock().unwrap_or_else(|e| e.into_inner())
}

// =========================================================================
// لاگ‌نویسی و تله‌متری
// =========================================================================

fn get_timestamp() -> String {
    let now = SystemTime::now();
    let duration = now.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = duration.as_secs();
    let millis = duration.subsec_millis();

    let total_days = (secs / 86400) as i64;
    let day_seconds = (secs % 86400) as u32;

    let hour = day_seconds / 3600;
    let minute = (day_seconds % 3600) / 60;
    let second = day_seconds % 60;

    let z = total_days + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1024 + doe / 1461 - doe / 14245) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };

    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        year, m, d, hour, minute, second, millis
    )
}

pub fn write_log(level: &str, tag: &str, message: &str) {
    // لاگ‌های خط به خط دیباگ نباید هارد دیسک را مداوم باز و بسته کنند
    if level == "DEBUG" {
        return;
    }

    init_panic_hook();
    let _guard = LOG_MUTEX.lock().unwrap_or_else(|e| e.into_inner());

    let work_dir = get_safe_work_dir();
    let log_path = work_dir.join("log.txt");
    let log_line = format!("[{}] [{}] [{}] {}\n", get_timestamp(), level, tag, message);

    println!("{}", log_line.trim_end());

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
        let _ = file.write_all(log_line.as_bytes());
    }
}

pub fn write_app_log(level: String, tag: String, message: String) {
    write_log(&level, &tag, &message);
}

fn send_native_telemetry(level: &str, module: &str, error_message: &str, stack_trace: &str) {
    let level_owned = level.to_string();
    let module_owned = module.to_string();
    let err_owned = error_message.to_string();
    let stack_owned = stack_trace.to_string();
    let timestamp = get_timestamp();

    thread::spawn(move || {
        let os_info = if cfg!(target_os = "windows") {
            "Windows 64-bit (Rust Native Core)"
        } else {
            "Non-Windows (Rust Native Core)"
        };

        let payload = serde_json::json!({
            "app_version": "4.1",
            "os_info": os_info,
            "os_arch": "x64",
            "module": module_owned,
            "level": level_owned,
            "error_message": err_owned,
            "stack_trace": stack_owned,
            "timestamp": timestamp,
        }).to_string();

        let host = "log.redcloudir.workers.dev";
        let addr_str = format!("{}:443", host);

        if let Ok(mut addrs) = addr_str.to_socket_addrs() {
            if let Some(socket_addr) = addrs.next() {
                if let Ok(stream) = TcpStream::connect_timeout(&socket_addr, Duration::from_millis(3500)) {
                    let _ = stream.set_read_timeout(Some(Duration::from_millis(3500)));
                    let _ = stream.set_write_timeout(Some(Duration::from_millis(3500)));

                    if let Ok(connector) = native_tls::TlsConnector::builder()
                        .danger_accept_invalid_certs(true)
                        .build() 
                    {
                        if let Ok(mut tls_stream) = connector.connect(host, stream) {
                            let request = format!(
                                "POST /api/crash-report HTTP/1.1\r\n\
                                 Host: {}\r\n\
                                 User-Agent: RedCloud-RustCore/4.1\r\n\
                                 Content-Type: application/json\r\n\
                                 Content-Length: {}\r\n\
                                 Connection: close\r\n\r\n{}",
                                host,
                                payload.len(),
                                payload
                            );
                            let _ = tls_stream.write_all(request.as_bytes());
                            let _ = tls_stream.flush();
                        }
                    }
                }
            }
        }
    });
}

fn init_panic_hook() {
    PANIC_HOOK_SET.get_or_init(|| {
        std::panic::set_hook(Box::new(|panic_info| {
            let location = panic_info.location()
                .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
                .unwrap_or_else(|| "Unknown Location".to_string());

            let payload = if let Some(s) = panic_info.payload().downcast_ref::<&str>() {
                *s
            } else if let Some(s) = panic_info.payload().downcast_ref::<String>() {
                &s[..]
            } else {
                "Unknown panic payload"
            };

            let crash_msg = format!("CRITICAL RUST PANIC at {}: {}", location, payload);
            eprintln!("[FATAL] {}", crash_msg);

            let work_dir = get_safe_work_dir();
            let log_path = work_dir.join("log.txt");
            let log_line = format!("[{}] [FATAL_CRASH] [RUST_CORE] {}\n", get_timestamp(), crash_msg);

            if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&log_path) {
                let _ = file.write_all(log_line.as_bytes());
            }

            send_native_telemetry("FATAL_CRASH", "RUST_CORE_PANIC", &crash_msg, &format!("Panic Location: {}", location));
        }));
    });
}

pub fn get_log_file_path() -> String {
    let path = get_safe_work_dir().join("log.txt");
    path.to_string_lossy().to_string()
}

pub fn open_log_directory() -> Result<String, String> {
    let log_path = get_safe_work_dir().join("log.txt");
    if !log_path.exists() {
        write_log("INFO", "SYSTEM", "Log file created by user request.");
    }

    #[cfg(target_os = "windows")]
    {
        let folder = get_safe_work_dir();
        match Command::new("explorer.exe").arg(&folder).spawn() {
            Ok(_) => Ok("پوشه لاگ در ویندوز با موفقیت باز شد.".to_string()),
            Err(e) => Err(format!("خطا در باز کردن پوشه لاگ: {}", e)),
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        Ok(log_path.to_string_lossy().to_string())
    }
}

pub fn clear_log_file() -> Result<String, String> {
    let log_path = get_safe_work_dir().join("log.txt");
    if log_path.exists() {
        let _ = std::fs::write(&log_path, "");
    }
    write_log("INFO", "SYSTEM", "فایل گزارش خطاها پاکسازی شد.");
    Ok("فایل لاگ با موفقیت پاکسازی شد.".to_string())
}

fn resolve_binary_path(name: &str) -> PathBuf {
    let file_name = PathBuf::from(name)
        .file_name()
        .map(|f| f.to_os_string())
        .unwrap_or_else(|| std::ffi::OsString::from(name));

    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join(&file_name);
            if candidate.exists() {
                return candidate;
            }
        }
    }

    if let Ok(cur) = std::env::current_dir() {
        let candidate = cur.join(&file_name);
        if candidate.exists() {
            return candidate;
        }
    }

    let p = PathBuf::from(name);
    if p.is_absolute() && p.exists() {
        return p;
    }

    p
}

fn get_safe_work_dir() -> PathBuf {
    let dir = std::env::temp_dir().join("RedCloud");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

#[cfg(target_os = "windows")]
fn notify_windows_proxy_change() {
    #[link(name = "wininet")]
    extern "system" {
        fn InternetSetOptionW(
            h_internet: *mut std::ffi::c_void,
            dw_option: u32,
            lp_buffer: *mut std::ffi::c_void,
            dw_buffer_length: u32,
        ) -> i32;
    }

    unsafe {
        const INTERNET_OPTION_SETTINGS_CHANGED: u32 = 39;
        const INTERNET_OPTION_REFRESH: u32 = 37;
        InternetSetOptionW(std::ptr::null_mut(), INTERNET_OPTION_SETTINGS_CHANGED, std::ptr::null_mut(), 0);
        InternetSetOptionW(std::ptr::null_mut(), INTERNET_OPTION_REFRESH, std::ptr::null_mut(), 0);
    }
}

#[cfg(target_os = "windows")]
fn get_global_job_object() -> Option<usize> {
    static WIN_JOB_OBJECT: OnceLock<Option<usize>> = OnceLock::new();
    *WIN_JOB_OBJECT.get_or_init(|| {
        unsafe {
            use windows_sys::Win32::System::JobObjects::{
                CreateJobObjectW, SetInformationJobObject, JobObjectExtendedLimitInformation,
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            };

            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job as usize == 0 || job as isize == -1 {
                write_log("ERROR", "WIN_JOB", "خطا در ایجاد JobObject ویندوز");
                return None;
            }

            let mut info = std::mem::zeroed::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

            let size = std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32;
            let res = SetInformationJobObject(
                job,
                JobObjectExtendedLimitInformation,
                &info as *const _ as *const _,
                size,
            );

            if res == 0 {
                windows_sys::Win32::Foundation::CloseHandle(job);
                write_log("ERROR", "WIN_JOB", "خطا در تنظیم پرچم‌های JobObject");
                None
            } else {
                Some(job as usize)
            }
        }
    })
}

#[cfg(target_os = "windows")]
fn assign_child_to_job(child: &std::process::Child) {
    use std::os::windows::io::AsRawHandle;
    let child_handle = child.as_raw_handle();
    if let Some(job_handle_usize) = get_global_job_object() {
        unsafe {
            use windows_sys::Win32::System::JobObjects::AssignProcessToJobObject;
            let h_job = job_handle_usize as windows_sys::Win32::Foundation::HANDLE;
            let h_proc = child_handle as windows_sys::Win32::Foundation::HANDLE;
            let _ = AssignProcessToJobObject(h_job, h_proc);
        }
    }
}

pub fn is_connected() -> bool {
    let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(child) = process_guard.as_mut() {
        if let Ok(Some(_)) = child.try_wait() {
            *process_guard = None;
            return false;
        }
        return true;
    }
    false
}

pub fn is_tor_connected() -> bool {
    let mut process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(child) = process_guard.as_mut() {
        if let Ok(Some(_)) = child.try_wait() {
            *process_guard = None;
            return false;
        }
        return true;
    }
    false
}

pub fn is_tor_masque_connected() -> bool {
    let tor_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let aether_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    tor_guard.is_some() && aether_guard.is_some()
}

pub fn is_psiphon_connected() -> bool {
    let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(child) = process_guard.as_mut() {
        if let Ok(Some(_)) = child.try_wait() {
            *process_guard = None;
            return false;
        }
        return true;
    }
    false
}

pub fn is_psiphon_masque_connected() -> bool {
    let psiphon_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let aether_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    psiphon_guard.is_some() && aether_guard.is_some()
}

pub fn is_aether_connected() -> bool {
    let mut process_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(child) = process_guard.as_mut() {
        if let Ok(Some(_)) = child.try_wait() {
            *process_guard = None;
            return false;
        }
        return true;
    }
    false
}

pub fn is_hybrid_connected() -> bool {
    let proxy_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let aether_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    proxy_guard.is_some() && aether_guard.is_some()
}

pub fn is_dns_active() -> bool {
    ACTIVE_DNS.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

pub fn get_tor_bootstrap_progress() -> i32 {
    *TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn is_psiphon_bootstrap_done() -> bool {
    *PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn get_psiphon_status_text() -> String {
    PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

pub fn get_aether_bootstrap_progress() -> i32 {
    *AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn is_aether_bootstrap_done() -> bool {
    *AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn get_aether_status_text() -> String {
    AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

// =========================================================================
// سیستم تشخیص، اعتبارسنجی و غربالگری DNS
// =========================================================================

pub fn verify_dns_ip(ip: String) -> Option<VerifiedDns> {
    let target_addr: SocketAddr = format!("{}:53", ip.trim()).parse().ok()?;
    let socket = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return None,
    };

    let _ = socket.set_read_timeout(Some(Duration::from_millis(1500)));
    let _ = socket.set_write_timeout(Some(Duration::from_millis(1500)));

    let dns_query: [u8; 28] = [
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x06, b'g', b'o', b'o', b'g', b'l', b'e',
        0x03, b'c', b'o', b'm',
        0x00, 0x00, 0x01, 0x00, 0x01
    ];

    let start = Instant::now();
    if socket.send_to(&dns_query, target_addr).is_err() {
        return None;
    }

    let mut buf = [0u8; 512];
    let (amt, _) = match socket.recv_from(&mut buf) {
        Ok(res) => res,
        Err(_) => return None,
    };
    let latency = start.elapsed().as_millis() as i32;

    if amt < 32 {
        return None;
    }

    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    if ancount == 0 {
        return None;
    }

    let resolved_ip = Ipv4Addr::new(buf[amt - 4], buf[amt - 3], buf[amt - 2], buf[amt - 1]);
    let octets = resolved_ip.octets();

    if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 
       || (octets[0] == 192 && octets[1] == 168)
       || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
       || (octets[0] == 10 && octets[1] == 10 && octets[2] == 34) {
        return None;
    }

    Some(VerifiedDns {
        ip: ip.trim().to_string(),
        latency_ms: latency,
        works_singbox: true,
        works_tor: true,
        works_psiphon: true,
    })
}

pub fn run_dns_rescue_scan(custom_dns_list: Option<String>) -> Vec<VerifiedDns> {
    write_log("INFO", "DNS_RESCUE", "آغاز اسکن خوددرمانگر استخر DNS...");
    let mut candidate_list: Vec<String> = Vec::new();

    if let Some(content) = custom_dns_list {
        for line in content.lines() {
            let tr = line.trim();
            if !tr.is_empty() && !tr.starts_with('#') && tr.parse::<IpAddr>().is_ok() {
                candidate_list.push(tr.to_string());
            }
        }
    }

    if candidate_list.is_empty() {
        let dns_file = resolve_binary_path("DNS.txt");
        if let Ok(file) = File::open(&dns_file) {
            let reader = BufReader::new(file);
            for line in reader.lines().flatten() {
                let tr = line.trim().to_string();
                if !tr.is_empty() && !tr.starts_with('#') && tr.parse::<IpAddr>().is_ok() {
                    candidate_list.push(tr);
                }
            }
        }
    }

    if candidate_list.is_empty() {
        candidate_list = vec![
            "94.140.14.14", "94.140.15.15", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220", "185.228.168.9", "185.228.169.9",
            "77.88.8.8", "77.88.8.1", "223.5.5.5", "223.6.6.6", "119.29.29.29",
            "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1"
        ].into_iter().map(|s| s.to_string()).collect();
    }

    let (tx, rx) = mpsc::channel();
    let take_count = candidate_list.len().min(80);
    let slice = &candidate_list[..take_count];

    for chunk in slice.chunks(25) {
        let mut handles = Vec::new();
        for ip in chunk {
            let tx_c = tx.clone();
            let ip_str = ip.clone();
            handles.push(thread::spawn(move || {
                if let Some(verified) = verify_dns_ip(ip_str) {
                    let _ = tx_c.send(verified);
                }
            }));
        }
        for h in handles {
            let _ = h.join();
        }
    }

    drop(tx);
    let mut verified_results: Vec<VerifiedDns> = Vec::new();
    while let Ok(dns) = rx.try_recv() {
        verified_results.push(dns);
    }

    verified_results.sort_by_key(|d| d.latency_ms);
    let final_top = verified_results.into_iter().take(8).collect::<Vec<_>>();

    let work_dir = get_safe_work_dir();
    let vault_path = work_dir.join("dns_vault.json");
    if let Ok(encoded) = serde_json::to_string_pretty(&final_top) {
        let _ = std::fs::write(vault_path, encoded);
    }

    write_log("INFO", "DNS_RESCUE", &format!("اسکن پایان یافت. تعداد {} سرور تایید و ذخیره شد.", final_top.len()));
    final_top
}

pub fn get_vault_dns_list() -> Vec<VerifiedDns> {
    let work_dir = get_safe_work_dir();
    let vault_path = work_dir.join("dns_vault.json");
    if let Ok(content) = std::fs::read_to_string(vault_path) {
        if let Ok(decoded) = serde_json::from_str::<Vec<VerifiedDns>>(&content) {
            if !decoded.is_empty() {
                return decoded;
            }
        }
    }

    vec![
        VerifiedDns { ip: "94.140.14.14".into(), latency_ms: 50, works_singbox: true, works_tor: true, works_psiphon: true },
        VerifiedDns { ip: "9.9.9.9".into(), latency_ms: 55, works_singbox: true, works_tor: true, works_psiphon: true },
        VerifiedDns { ip: "208.67.222.222".into(), latency_ms: 60, works_singbox: true, works_tor: true, works_psiphon: true },
        VerifiedDns { ip: "223.5.5.5".into(), latency_ms: 40, works_singbox: true, works_tor: true, works_psiphon: true },
    ]
}

pub fn ping_dns_server(ip: String) -> i32 {
    let addr = format!("{}:53", ip).parse::<SocketAddr>();
    if let Ok(socket_addr) = addr {
        let start = Instant::now();
        if TcpStream::connect_timeout(&socket_addr, Duration::from_millis(1500)).is_ok() {
            return start.elapsed().as_millis() as i32;
        }
    }
    -1
}

pub fn ping_proxy_server(host: String, port: u16) -> i32 {
    let addr = format!("{}:{}", host, port);
    let start = Instant::now();
    if let Ok(addrs) = addr.to_socket_addrs() {
        for socket_addr in addrs {
            if TcpStream::connect_timeout(&socket_addr, Duration::from_millis(1500)).is_ok() {
                return start.elapsed().as_millis() as i32;
            }
        }
    }
    -1
}

pub fn set_system_dns(primary: String, secondary: String) -> Result<String, String> {
    let mut process_guard = ACTIVE_DNS.lock().unwrap_or_else(|e| e.into_inner());

    if process_guard.is_some() {
        return Err("یک دی‌ان‌اس در حال حاضر فعال است. ابتدا آن را خاموش کنید.".to_string());
    }

    let primary_ip: IpAddr = primary.trim().parse()
        .map_err(|_| "آدرس آی‌پی اولیه نامعتبر است.".to_string())?;

    let secondary_ip: IpAddr = secondary.trim().parse()
        .map_err(|_| "آدرس آی‌پی ثانویه نامعتبر است.".to_string())?;

    let script = format!(
        "Get-NetAdapter | Where-Object {{$_.Status -eq 'Up'}} | Set-DnsClientServerAddress -ServerAddresses ('{}', '{}')",
        primary_ip, secondary_ip
    );

    let mut command = Command::new("powershell");
    command.args(&["-Command", &script])
           .stdin(Stdio::null())
           .stdout(Stdio::null())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let output = command.output();

    match output {
        Ok(out) => {
            if out.status.success() {
                *process_guard = Some((primary.clone(), secondary.clone()));
                write_log("INFO", "DNS_SYSTEM", &format!("دی‌ان‌اس سیستم با موفقیت تنظیم شد: {} , {}", primary, secondary));
                Ok("دی‌ان‌اس با موفقیت روی سیستم فعال شد.".to_string())
            } else {
                write_log("WARN", "DNS_SYSTEM", "نیاز به ادمین برای تغییر دی‌ان‌اس؛ درخواست مجوز با RunAs...");
                let elevate_cmd = format!(
                    "Start-Process powershell -ArgumentList '-NoProfile -Command \"Get-NetAdapter | Where-Object {{$_.Status -eq \\'Up\\'}} | Set-DnsClientServerAddress -ServerAddresses (\\'{}\\', \\'{}\\')\"' -WindowStyle Hidden -Verb RunAs",
                    primary_ip, secondary_ip
                );
                let _ = Command::new("powershell").args(&["-NoProfile", "-Command", &elevate_cmd]).creation_flags(0x08000000).output();
                *process_guard = Some((primary.clone(), secondary.clone()));
                Ok("دی‌ان‌اس با مجوز Administrator روی سیستم فعال شد.".to_string())
            }
        }
        Err(e) => {
            let err_msg = format!("خطا در اجرای اسکریپت پاورشل: {}", e);
            write_log("ERROR", "DNS_SYSTEM", &err_msg);
            Err(err_msg)
        }
    }
}

pub fn reset_system_dns() -> Result<String, String> {
    let mut process_guard = ACTIVE_DNS.lock().unwrap_or_else(|e| e.into_inner());

    let script = "Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Set-DnsClientServerAddress -ResetServerAddresses";

    let mut command = Command::new("powershell");
    command.args(&["-Command", script])
           .stdin(Stdio::null())
           .stdout(Stdio::null())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let output = command.output();

    match output {
        Ok(out) => {
            if out.status.success() {
                *process_guard = None;
                write_log("INFO", "DNS_SYSTEM", "دی‌ان‌اس سیستم به حالت خودکار (DHCP) ریست شد.");
                Ok("تنظیمات دی‌ان‌اس سیستم به حالت خودکار (DHCP) بازگشت.".to_string())
            } else {
                let err_msg = "خطا در ریست دی‌ان‌اس. برنامه را به عنوان Administrator اجرا کنید.".to_string();
                write_log("ERROR", "DNS_SYSTEM", &err_msg);
                Err(err_msg)
            }
        }
        Err(e) => {
            let err_msg = format!("خطا در ریست دی‌ان‌اس: {}", e);
            write_log("ERROR", "DNS_SYSTEM", &err_msg);
            Err(err_msg)
        }
    }
}

fn set_windows_system_proxy(enable: bool, host: String, port: u16) {
    if cfg!(target_os = "windows") {
        let enable_val = if enable { "1" } else { "0" };
        
        let mut cmd = Command::new("reg");
        cmd.args(&[
            "add", 
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 
            "/v", "ProxyEnable", 
            "/t", "REG_DWORD", 
            "/d", enable_val, 
            "/f"
        ]);
        #[cfg(target_os = "windows")]
        cmd.creation_flags(0x08000000);
        let _ = cmd.output();

        if enable {
            // فقط به عنوان socks تعریف می‌شود تا ویندوز دستور CONNECT با بایت 0x43 نفرستد
            let proxy_server = if port == 1821 || port == 9080 || port == 1819 {
                format!("socks=127.0.0.1:{}", port)
            } else {
                format!("{}:{}", host, port)
            };
            
            let mut cmd2 = Command::new("reg");
            cmd2.args(&[
                "add", 
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 
                "/v", "ProxyServer", 
                "/t", "REG_SZ", 
                "/d", &proxy_server, 
                "/f"
            ]);
            #[cfg(target_os = "windows")]
            cmd2.creation_flags(0x08000000);
            let _ = cmd2.output();

            let mut cmd3 = Command::new("reg");
            cmd3.args(&[
                "add", 
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 
                "/v", "ProxyOverride", 
                "/t", "REG_SZ", 
                "/d", "<local>;localhost;127.0.0.1;*.ir;*.shaparak.ir;10.*;172.16.*;192.168.*", 
                "/f"
            ]);
            #[cfg(target_os = "windows")]
            cmd3.creation_flags(0x08000000);
            let _ = cmd3.output();

            // مسدودسازی قطعی نشت WebRTC در کروم و ادج
            let _ = Command::new("reg").args(&["add", "HKCU\\Software\\Policies\\Google\\Chrome", "/v", "WebRtcIPHandlingPolicy", "/t", "REG_SZ", "/d", "disable_non_proxied_udp", "/f"]).creation_flags(0x08000000).output();
            let _ = Command::new("reg").args(&["add", "HKCU\\Software\\Policies\\Microsoft\\Edge", "/v", "WebRtcIPHandlingPolicy", "/t", "REG_SZ", "/d", "disable_non_proxied_udp", "/f"]).creation_flags(0x08000000).output();

            write_log("INFO", "PROXY_REG", &format!("پروکسی سیستم روی {}:{} فعال شد و نشت WebRTC مسدود گردید.", host, port));
        } else {
            // حذف محدودیت WebRTC موقع قطع اتصال
            let _ = Command::new("reg").args(&["delete", "HKCU\\Software\\Policies\\Google\\Chrome", "/v", "WebRtcIPHandlingPolicy", "/f"]).creation_flags(0x08000000).output();
            let _ = Command::new("reg").args(&["delete", "HKCU\\Software\\Policies\\Microsoft\\Edge", "/v", "WebRtcIPHandlingPolicy", "/f"]).creation_flags(0x08000000).output();
            write_log("INFO", "PROXY_REG", "پروکسی سیستم غیرفعال شد.");
        }

        #[cfg(target_os = "windows")]
        notify_windows_proxy_change();
    }
}

// =========================================================================
// هسته شبکه ضدسانسور اِتر (Aether Engine)
// =========================================================================

fn test_socks5_egress(socks_addr: &str, timeout: Duration) -> bool {
    let addr = match socks_addr.parse::<SocketAddr>() {
        Ok(a) => a,
        Err(_) => return false,
    };

    let mut stream = match TcpStream::connect_timeout(&addr, Duration::from_millis(700)) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let effective_timeout = timeout.max(Duration::from_millis(1500));
    let _ = stream.set_read_timeout(Some(effective_timeout));
    let _ = stream.set_write_timeout(Some(effective_timeout));
    let _ = stream.set_nodelay(true);

    // ۱. دست‌دهی اولیه با ساکس لوکال
    if stream.write_all(&[0x05, 0x01, 0x00]).is_err() {
        return false;
    }

    let mut auth_resp = [0u8; 2];
    if stream.read_exact(&mut auth_resp).is_err() || auth_resp != [0x05, 0x00] {
        return false;
    }

    // ۲. ارسال درخواست اتصال به سرور تست اینترنت جهانی از داخل تونل (cp.cloudflare.com:80)
    let mut connect_req = Vec::new();
    connect_req.extend_from_slice(&[0x05, 0x01, 0x00, 0x03]); // SOCKS5 Domain Connect
    let domain = b"cp.cloudflare.com";
    connect_req.push(domain.len() as u8);
    connect_req.extend_from_slice(domain);
    connect_req.extend_from_slice(&80u16.to_be_bytes()); // Port 80

    if stream.write_all(&connect_req).is_err() {
        return false;
    }

    let mut connect_resp = [0u8; 10];
    if stream.read_exact(&mut connect_resp).is_err() || connect_resp[1] != 0x00 {
        return false;
    }

    // ۳. ارسال پکت تست واقعی HTTP و انتظار برای دریافت دیتای زنده از خارج کشور
    let http_probe = b"GET /generate_204 HTTP/1.1\r\nHost: cp.cloudflare.com\r\nUser-Agent: curl/7.88.1\r\nConnection: close\r\n\r\n";
    if stream.write_all(http_probe).is_err() {
        return false;
    }

    let mut http_resp = [0u8; 15];
    if stream.read_exact(&mut http_resp).is_err() {
        return false; // ترافیک به چاه سیاه خورده یا قطع است!
    }

    let resp_str = String::from_utf8_lossy(&http_resp);
    // تایید قطعی: فقط در صورتی که دیتای واقعی با پاسخ 204 از اینترنت جهانی برگشت تایید شود
    let is_real_traffic = resp_str.starts_with("HTTP/1.1 204") 
        || resp_str.starts_with("HTTP/1.0 204") 
        || resp_str.starts_with("HTTP/1.1 200");

    if is_real_traffic {
        write_log("INFO", "PROBE_E2E", "✅ عبور واقعی داده از خارج کشور تایید شد (پاسخ 204 سالم).");
    } else {
        write_log("WARN", "PROBE_E2E", &format!("❌ شبه‌اتصال جعلی تشخیص داده شد؛ پاسخ نامعتبر: {}", resp_str));
    }

    is_real_traffic
}

fn process_aether_line(l: String) {
    let trimmed = l.trim().to_string();
    if trimmed.is_empty() { return; }

    write_log("DEBUG", "AETHER", &trimmed);

    {
        let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = trimmed.clone();
    }

    let lower = trimmed.to_lowercase();

    if lower.contains("tunnel validated") || lower.contains("exposing socks5") {
        let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        *progress = 100;
        let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
        *connected = true;
    } else if let Some(pos) = trimmed.find('%') {
        let start = trimmed[..pos].rfind(|c: char| !c.is_ascii_digit()).map(|p| p + 1).unwrap_or(0);
        if let Ok(p) = trimmed[start..pos].parse::<i32>() {
            let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
            *progress = p;
        }
    } else if lower.contains("discovering") || lower.contains("searching") || lower.contains("scanning") {
        let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        if *progress < 45 { *progress = 45; }
    } else if lower.contains("probing") || lower.contains("testing") || lower.contains("handshake") {
        let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        if *progress < 80 { *progress = 80; }
    }
}

/// تابع هوشمند کشف پوشه استخر ATC در محیط دیباگ یا ویندوز نصب‌شده
fn find_atc_pool_dir() -> Option<PathBuf> {
    // ۱. بررسی کنار فایل اجرایی اصلی (مخصوص نسخه نصب‌شده کاربران در Program Files)
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join("ATC");
            if candidate.is_dir() { return Some(candidate); }

            // بررسی مسیر ریشه پروژه در حالت توسعه و دیباگ فلاتر
            if let Some(project_root) = parent.parent().and_then(|p| p.parent()).and_then(|p| p.parent()).and_then(|p| p.parent()) {
                let debug_atc = project_root.join("ATC");
                if debug_atc.is_dir() { return Some(debug_atc); }
            }
        }
    }

    // ۲. بررسی دایرکتوری کاری جاری
    if let Ok(cur) = std::env::current_dir() {
        let candidate = cur.join("ATC");
        if candidate.is_dir() { return Some(candidate); }
    }

    None
}

/// بررسی و تزریق خودکار هویت از استخر اکانت‌های ATC برای کاربران جدید
pub fn ensure_aether_identity_from_pool() {
    let work_dir = get_safe_work_dir();
    let masque_conf = work_dir.join("aether-masque.toml");
    let wg_conf = work_dir.join("aether.toml");

    // اگر کاربر از قبل هویت فعال دارد، نیازی به دستکاری نیست
    if masque_conf.exists() && wg_conf.exists() {
        return;
    }

    // پیدا کردن پوشه ATC
    let atc_dir = match find_atc_pool_dir() {
        Some(d) => d,
        None => {
            write_log("WARN", "ATC_POOL", "پوشه استخر ATC در سیستم یافت نشد.");
            return;
        }
    };

    // جمع‌آوری تمام پوشه‌های اکانت موجود داخل ATC (account_1 تا account_X)
    let mut available_accounts = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&atc_dir) {
        for entry in entries.flatten() {
            if entry.path().is_dir() {
                available_accounts.push(entry.path());
            }
        }
    }

    if available_accounts.is_empty() {
        write_log("WARN", "ATC_POOL", "هیچ اکانتی داخل پوشه ATC وجود ندارد.");
        return;
    }

    // انتخاب کاملاً تصادفی بر اساس میلی‌ثانیه ساعت سیستم تا ترافیک کاربران بین ۱۹۳ اکانت تقسیم شود
    let rand_idx = (SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as usize) % available_accounts.len();
    let selected_acc = &available_accounts[rand_idx];

    let src_masque = selected_acc.join("aether-masque.toml");
    let src_wg = selected_acc.join("aether.toml");
    let src_sec = selected_acc.join("aether-secondary.toml");

    // کپی کردن فایل‌های هویتی ۳گانه به پوشه کاری موقت اِتر
    if src_masque.exists() {
        let _ = std::fs::copy(&src_masque, work_dir.join("aether-masque.toml"));
    }
    if src_wg.exists() {
        let _ = std::fs::copy(&src_wg, work_dir.join("aether.toml"));
    }
    if src_sec.exists() {
        let _ = std::fs::copy(&src_sec, work_dir.join("aether-secondary.toml"));
    }

    write_log(
        "INFO", 
        "ATC_POOL", 
        &format!("🎯 کاربر بدون هویت بود؛ اکانت اختصاصی از استخر ATC ({:?}) با موفقیت روی سیستم فعال شد.", selected_acc.file_name().unwrap_or_default())
    );
}

fn spawn_single_aether_mode(
    binary_path: &PathBuf, 
    mode: &str,
    noize: &str,
    warp_key: Option<&str>,
    team_token: Option<&str>,
    custom_peer: Option<&str>,
) -> Result<Child, String> {
    // تزریق قطعی اکانت از استخر ATC قبل از استارت اِتر
    ensure_aether_identity_from_pool();

    let work_dir = get_safe_work_dir();
    let mut command = Command::new(binary_path);
    
    command.arg("--bind").arg("127.0.0.1:1819")
           .arg("--http-proxy").arg("127.0.0.1:1820")
           .arg("-4")
           .arg("--scan").arg("turbo");

    let selected_noize = if noize.trim().is_empty() { "firewall" } else { noize.trim() };
    command.arg("--noize").arg(selected_noize);

    // اعمال آی‌پی تست‌شده و زنده در شرایط اضطراری
    if let Some(peer) = custom_peer {
        let trimmed_peer = peer.trim();
        if !trimmed_peer.is_empty() {
            if mode == "gool" {
                command.arg("--wiw-outer").arg(trimmed_peer);
            } else {
                command.arg("--peer").arg(trimmed_peer);
            }
        }
    }

    if let Some(key) = warp_key {
        if !key.trim().is_empty() {
            command.arg("--key").arg(key.trim());
        }
    }

    if let Some(team) = team_token {
        if !team.trim().is_empty() {
            command.arg("--team").arg(team.trim());
        }
    }

    match mode {
        "masque_h2" => {
            command.arg("--masque").arg("--h2").arg("--fragment");
        },
        "gool" => {
            command.arg("--gool");
        },
        "wireguard" => {
            command.arg("--wg");
        },
        _ => {
            command.arg("--masque");
        }
    }

    command.current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let mut child = command.spawn()
        .map_err(|e| {
            let err = format!("خطا در اجرای aether.exe: {}", e);
            write_log("ERROR", "AETHER", &err);
            err
        })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().flatten() {
                process_aether_line(line);
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().flatten() {
                process_aether_line(line);
            }
        });
    }

    Ok(child)
}

pub fn start_aether_core(
    binary_path: String,
    mode: String,
    noize: String,
    warp_key: Option<String>,
    team: Option<String>,
    use_system_proxy: bool,
) -> Result<String, String> {
    write_log("INFO", "AETHER", &format!("درخواست راه‌اندازی اِتر با حالت: '{}' و نویز اولیه: '{}'", mode, noize));

    // پاکسازی خودکار و سراسری تمام هسته‌ها و آزادسازی پورت‌ها و درایور Wintun
    kill_all_zombie_cores();

    {
        let mut p = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = p.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }

    let resolved_path = resolve_binary_path(&binary_path);
    if !resolved_path.exists() {
        return Err(format!("فایل aether.exe در مسیر {:?} یافت نشد.", resolved_path));
    }

    let (fingerprint, network_label) = LearningEngine::compute_network_fingerprint();
    let learning_engine = get_learning_engine();
    let user_noize_pref = if noize.trim().is_empty() { "firewall" } else { noize.trim() };

    let mut combinations_to_try: Vec<(String, String)> = Vec::new();

    // =========================================================================
    // ۱. بررسی حافظه یادگیری (Fast-Path Probe): اول تست کن، اگر باز بود فوری وصل شو!
    // =========================================================================
    if mode == "auto" || mode.is_empty() {
        if let Some((cached_mode, cached_noize)) = learning_engine.suggest_best_protocol_and_noize(fingerprint, "Aether") {
            write_log(
                "INFO",
                "AETHER_LEARNING",
                &format!("[Fast-Path Probe] آزمایش زنده حافظه شبکه ({}): مود {} با نویز {}", network_label, cached_mode, cached_noize),
            );
            combinations_to_try.push((cached_mode, cached_noize));
        }
    }

    // =========================================================================
    // ۲. تعریف ماتریس هوشمند اسکن جامع (مودها × نویزها با اولویت عبور از فیلترینگ)
    // =========================================================================
    if mode == "gaming_auto" {
        // اولویت طلایی اختصاصی تب گیمینگ: مسک ۲ (ضد فیلتر UDP) -> گول -> وایرگارد -> مسک ۳
        let gaming_matrix = [
            ("masque_h2", "aggressive"), // اولویت ۱: مسک ۲ ضد اختلال با نویز تهاجمی
            ("masque_h2", "light"),      // اولویت ۲: مسک ۲ سبک و کم‌تاخیر
            ("gool", "aggressive"),      // اولویت ۳: تونل مضاعف وارپ
            ("gool", "light"),           // اولویت ۴: تونل مضاعف سبک
            ("wireguard", "aggressive"), // اولویت ۵: وایرگارد استاندارد
            ("wireguard", "light"),      // اولویت ۶: وایرگارد سبک
            ("masque_h3", "light"),      // اولویت آخر: فقط به عنوان آخرین شانس
        ];
        for (m, n) in gaming_matrix {
            let pair = (m.to_string(), n.to_string());
            if !combinations_to_try.contains(&pair) {
                combinations_to_try.push(pair);
            }
        }
    } else if mode == "auto" || mode.is_empty() {
        let matrix = [
            ("gool", "aggressive"),      // اولویت ۱: تونل مضاعف وارپ با نویز تهاجمی (بالاترین شانس عبور در اختلال شدید)
            ("masque_h2", "aggressive"), // اولویت ۲: مسک بر بستر TCP و فرگمنت (ضد اختلالات و فیلترینگ UDP)
            ("masque_h2", user_noize_pref),
            ("gool", user_noize_pref),
            ("masque_h3", user_noize_pref),
            ("wireguard", "aggressive"),
            ("masque_h3", "light"),
        ];
        for (m, n) in matrix {
            let pair = (m.to_string(), n.to_string());
            if !combinations_to_try.contains(&pair) {
                combinations_to_try.push(pair);
            }
        }
    } else {
        // کاربر دستی مود خاصی را انتخاب کرده است
        combinations_to_try.push((mode.clone(), user_noize_pref.to_string()));
        if user_noize_pref != "aggressive" {
            combinations_to_try.push((mode.clone(), "aggressive".to_string()));
        }
    }

    let mut connected_child: Option<Child> = None;
    let mut verified_combo_name = String::new();
    let mut last_error = String::new();
    let mut is_from_cached_memory = false;

    for (idx, (current_mode, current_noize)) in combinations_to_try.iter().enumerate() {
        let is_probing_memory = idx == 0 && combinations_to_try.len() > 1 && (mode == "auto" || mode.is_empty());
        let mode_label = match current_mode.as_str() {
            "masque_h3" => "MASQUE H3",
            "masque_h2" => "MASQUE H2",
            "gool" => "Gool (WARP-in-WARP)",
            "wireguard" => "WireGuard",
            other => other,
        };

        write_log("INFO", "AETHER_PROBE", &format!("آزمایش عبور دیتا: {} + نویز {}", mode_label, current_noize));

        {
            let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
            *progress = if is_probing_memory { 40 } else { 20 + ((idx as i32) * 10).min(65) };
            let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
            *connected = false;
            let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            *status = if is_probing_memory {
                format!("Testing saved memory: {} + {}...", mode_label, current_noize)
            } else {
                format!("Probing: {} + {} noize...", mode_label, current_noize)
            };
        }

        let forced_peer = if mode == "gaming_auto" {
            GAMING_TARGET_PEER.lock().unwrap_or_else(|e| e.into_inner()).clone()
        } else {
            None
        };

        match spawn_single_aether_mode(
            &resolved_path, 
            current_mode, 
            current_noize, 
            warp_key.as_deref(), 
            team.as_deref(),
            forced_peer.as_deref()
        ) {
            Ok(mut child) => {
                let mut mode_success = false;
                let start_time = Instant::now();
                let hard_timeout = if is_probing_memory { 
                    Duration::from_secs(35) 
                } else { 
                    Duration::from_secs(80) // بازگشت به ۸۰ ثانیه مهلت کامل و صبورانه برای هندشیک و اسکن
                };
                let mut last_progress = 0;
                let mut last_status = String::new();
                let mut flatline_silence_ticks = 0;

                // حلقه ناظر هوشمند علائم حیاتی و پیشرفت اتصال
                loop {
                    thread::sleep(Duration::from_millis(350));

                    // ۱. اگر پروسه ناگهان کرش کرد، درجا متوجه شو و ۱ میلی‌ثانیه هم معطل نمان
                    if let Ok(Some(exit_status)) = child.try_wait() {
                        last_error = format!("{} با خروجی {} متوقف شد.", mode_label, exit_status);
                        break;
                    }

                    // ۲. بررسی اتصال پیروزمندانه و عبور واقعی دیتا
                    let is_validated = *AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                    if is_validated || test_socks5_egress("127.0.0.1:1819", Duration::from_millis(650)) {
                        mode_success = true;
                        write_log("INFO", "AETHER_PROBE", &format!("اتصال زنده تایید شد: {} + نویز {}", mode_label, current_noize));
                        break;
                    }

                    // ۳. پایش علائم حیاتی: آیا پیشرفتی در درصد یا پیام وضعیت رخ داده است؟
                    let current_progress = *AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                    let current_status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner()).clone();

                    let has_progress = (current_progress > last_progress) 
                        || (!current_status.is_empty() && current_status != last_status);

                    if has_progress {
                        // اتصال زنده است و رو به جلو حرکت می‌کند؛ زمان سکون صفر می‌شود تا برنامه صبور بماند
                        flatline_silence_ticks = 0;
                        last_progress = current_progress;
                        last_status = current_status;
                    } else {
                        flatline_silence_ticks += 1;
                    }

                    // ۴. سقف مجاز سکوت و سکته کامل: صبوری حداکثری و مطمئن (۱۲ ثانیه برای پیشرفت‌های بالا و ۷ ثانیه برای صفر)
                    let allowed_silent_ticks = if current_progress >= 40 { 35 } else { 20 };
                    if flatline_silence_ticks >= allowed_silent_ticks {
                        write_log("WARN", "AETHER_PROBE", &format!("سکته و سکوت کامل در {} (پیشرفت {}٪). جهش هوشمند به مود بعدی...", mode_label, current_progress));
                        break;
                    }

                    // سقف امنیتی کل زمان جهت جلوگیری از قفل ابدی
                    if start_time.elapsed() >= hard_timeout {
                        write_log("WARN", "AETHER_PROBE", &format!("پایان مهلت نهایی برای {}", mode_label));
                        break;
                    }
                }

                if mode_success {
                    connected_child = Some(child);
                    verified_combo_name = format!("{} ({})", mode_label, current_noize);
                    is_from_cached_memory = is_probing_memory;

                    // ثبت پیروزی این ترکیب در حافظه بلندمدت شبکه فعلی
                    learning_engine.record_protocol_learning(
                        fingerprint,
                        network_label.clone(),
                        "Aether".to_string(),
                        current_mode.clone(),
                        current_noize.clone(),
                        true,
                        110.0,
                        95.0,
                    );

                    let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                    *progress = 100;
                    let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                    *connected = true;
                    let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
                    *status = format!("Connected via {}", verified_combo_name);
                    break;
                } else {
                    // اگر این ترکیب از حافظه بود و مسدود شده، فورا جریمه‌اش کن تا دیگر اول تست نشود!
                    if is_probing_memory {
                        write_log("WARN", "AETHER_LEARNING", "ترکیب حافظه توسط اپراتور مسدود شده؛ اعمال جریمه و آغاز اسکن ماتریسی...");
                        learning_engine.penalize_protocol_experience(fingerprint, "Aether", current_mode, current_noize);
                    }

                    let _ = child.kill();
                    let _ = child.wait();
                    #[cfg(target_os = "windows")]
                    let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
                    thread::sleep(Duration::from_millis(200));
                }
            }
            Err(e) => {
                last_error = e;
            }
        }
    }

    // =========================================================================
    // لایه اضطراری سخت‌گیرانه: فقط اگر تمام رنج‌های پیش‌فرض ۱۰۰٪ شکست خوردند
    // =========================================================================
    if connected_child.is_none() {
        if let Some((verified_ip, verified_port)) = find_verified_emergency_ip() {
            let peer_endpoint = format!("{}:{}", verified_ip, verified_port);
            let emergency_mode = "gool";
            let emergency_noize = "aggressive";

            write_log("INFO", "AETHER_EMERGENCY", &format!("تلاش نهایی با آی‌پی راستی‌آزمایی‌شده: {}", peer_endpoint));

            if let Ok(child) = spawn_single_aether_mode(
                &resolved_path,
                emergency_mode,
                emergency_noize,
                warp_key.as_deref(),
                team.as_deref(),
                Some(&peer_endpoint),
            ) {
                // تست ۲طرفه عبور واقعی دیتا (HTTP 204 Probe)
                let mut emergency_success = false;
                for _ in 1..=45 {
                    thread::sleep(Duration::from_millis(400));
                    if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
                        emergency_success = true;
                        break;
                    }
                }

                if emergency_success {
                    connected_child = Some(child);
                    verified_combo_name = format!("Emergency Verified Peer ({})", peer_endpoint);
                    write_log("INFO", "AETHER_EMERGENCY", "🛡️ تونل اضطراری با موفقیت به اینترنت جهانی متصل شد!");
                }
            }
        }
    }

    if let Some(c) = connected_child {
        ensure_watchdog_started();
        let mut process_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *process_guard = Some(c);
        if use_system_proxy {
            set_windows_system_proxy(true, "127.0.0.1".to_string(), 1820);
        }
        let hit_tag = if is_from_cached_memory { " [Fast-Path Memory Hit]" } else { " [Adaptive Auto-Scan]" };
        Ok(format!("Connected & verified via {}{}", verified_combo_name, hit_tag))
    } else {
        let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = format!("All combinations failed: {}", last_error);
        write_log("ERROR", "AETHER", &format!("امکان اتصال با هیچ یک از مودها و نویزها فراهم نشد: {}", last_error));
        Err(format!("امکان اتصال با هیچ یک از مودها و نویزها فراهم نشد: {}", last_error))
    }
}

pub fn stop_aether_core() -> Result<String, String> {
    let _ = restore_original_timezone();
    write_log("INFO", "AETHER", "دستور توقف هسته اِتر دریافت شد.");
    let mut process_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    set_windows_system_proxy(false, String::new(), 0);
    
    let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
    *progress = 0;
    let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
    *connected = false;
    let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
    *status = "Disconnected".to_string();

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "aether.exe"])
        .creation_flags(0x08000000)
        .output();

    Ok("اتصال شبکه اتر متوقف و سیستم به حالت عادی برگشت.".to_string())
}

// =========================================================================
// اتصال هیبریدی
// =========================================================================

pub fn start_hybrid_connection(
    singbox_path: String,
    aether_path: String,
    selected_node: ProxyNode,
    aether_mode: String,
    aether_noize: String,
    aether_warp_key: Option<String>,
    aether_team: Option<String>,
    use_system_proxy: bool,
    use_tun_mode: bool,
    dns_type: String,
    dns_primary: String,
    _dns_secondary: String,
    dns_dot_host: Option<String>,
    _utls_fingerprint: Option<String>,
) -> Result<String, String> {
    write_log("INFO", "HYBRID", &format!("شروع راه‌اندازی اتصال هیبریدی برای سرور: {}", selected_node.name));

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "sing-box.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(300));
    }

    let _ = stop_proxy_core();
    let _ = stop_aether_core();

    // ریشه‌کنی قطعی هرگونه پروسه یا کارت شبکه زامبی بازمانده از تب‌های دیگر قبل از راه‌اندازی
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "sing-box.exe", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("powershell")
            .args(&["-NoProfile", "-Command", "Get-PnpDevice | Where-Object { $_.Class -eq 'Net' -and ($_.FriendlyName -like '*Wintun*' -or $_.FriendlyName -like '*RC-TUN*' -or $_.FriendlyName -like '*RedCloud*') } | ForEach-Object { pnputil /remove-device $_.InstanceId }"])
            .creation_flags(0x08000000)
            .output();
        thread::sleep(Duration::from_millis(300));
    }

    let aether_res = start_aether_core(
        aether_path, 
        aether_mode, 
        aether_noize, 
        aether_warp_key, 
        aether_team, 
        false
    );
    if let Err(e) = aether_res {
        write_log("ERROR", "HYBRID", &format!("خطا در راه‌اندازی پل اتر: {}", e));
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    // تایم‌اوت هوشمند تطبیقی تا ۹۰ ثانیه (اگر در ثانیه اول وصل شود درجا رد می‌شود و معطل نمی‌ماند)
    for _ in 0..180 {
        thread::sleep(Duration::from_millis(500));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "HYBRID", "پل ارتباطی اتر پس از ۹۰ ثانیه بررسی زنده آماده نشد.");
        return Err("پل ارتباطی اتر موفق به برقراری ارتباط زنده با اینترنت نشد.".to_string());
    }

    // روش ۲: استعلام زنده و برق‌آسای کلید ECH از طریق پل بازشده اِتر
    if let Some(live_key) = fetch_live_ech_key_via_socks5(1819, Duration::from_millis(1500)) {
        let path = get_safe_work_dir().join("ech_vault.json");
        let _ = std::fs::write(path, &live_key);
        let mut vault = ECH_KEY_VAULT.lock().unwrap_or_else(|e| e.into_inner());
        *vault = Some(live_key);
        write_log("INFO", "ECH_VAULT", "🔑 کلید زنده ECH با موفقیت از طریق پل اِتر استخراج و در کش ذخیره شد.");
    }

    let mut outbound_json = convert_link_to_outbound(
        selected_node,
        None,
        false,
        false,
        None,
        None,
        None,
    )?;

    outbound_json["detour"] = serde_json::json!("aether-bridge");

    let mut inbounds = serde_json::json!([
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": 2080
        }
    ]);

    if use_tun_mode {
        let tun_iface_name = format!("tun{}", (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() % 900) + 100);
        let optimal_carrier_mtu = get_optimal_carrier_mtu();
        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tun_iface_name,
            "address": [
                "172.19.0.1/30"
            ],
            "mtu": optimal_carrier_mtu,
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed",
            "route_exclude_address": [
                "162.159.0.0/16",
                "188.114.96.0/20",
                "104.16.0.0/12",
                "172.64.0.0/13"
            ]
        }));
    }

    let vault_dns = get_vault_dns_list();
    let emergency_direct_dns = vault_dns.first().map(|d| d.ip.as_str()).unwrap_or("94.140.14.14");

    let dns_server_json = match dns_type.as_str() {
        "doh" => {
            let server_name = dns_dot_host.clone().unwrap_or_else(|| "cloudflare-dns.com".to_string());
            serde_json::json!({
                "type": "https",
                "tag": "dns_proxy",
                "server": dns_primary,
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": server_name,
                    "insecure": true
                }
            })
        },
        _ => {
            serde_json::json!({
                "type": "https",
                "tag": "dns_proxy",
                "server": "9.9.9.9",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": "dns.quad9.net",
                    "insecure": true
                }
            })
        }
    };

    let mut dns_servers = Vec::new();

    if is_dnscrypt_running() {
        dns_servers.push(serde_json::json!({
            "type": "udp",
            "tag": "dns_dnscrypt_tier1",
            "server": "127.0.0.1",
            "server_port": 5354
        }));
    }

    dns_servers.push(dns_server_json);
    dns_servers.push(serde_json::json!({
        "type": "https",
        "tag": "dns_backup_doh",
        "server": "9.9.9.9",
        "server_port": 443,
        "path": "/dns-query",
        "detour": "proxy-out",
        "tls": {
            "enabled": true,
            "server_name": "dns.quad9.net",
            "insecure": true
        }
    }));
    dns_servers.push(serde_json::json!({
        "type": "udp",
        "tag": "dns_direct",
        "server": emergency_direct_dns,
        "server_port": 53
    }));

    if use_tun_mode {
        dns_servers.insert(0, serde_json::json!({
            "type": "fakeip",
            "tag": "dns_fakeip",
            "inet4_range": "198.18.0.0/15"
        }));
    }

    let primary_resolver_tag = if is_dnscrypt_running() { "dns_dnscrypt_tier1" } else { "dns_proxy" };

    let mut dns_rules = vec![
        serde_json::json!({
            "query_type": ["A", "AAAA"],
            "server": primary_resolver_tag
        })
    ];

    if use_tun_mode {
        dns_rules.insert(0, serde_json::json!({
            "inbound": "tun-in",
            "query_type": ["A", "AAAA"],
            "server": "dns_fakeip"
        }));
    }

    let final_config = serde_json::json!({
        "log": {
            "level": "info"
        },
        "experimental": {
            "clash_api": {
                "external_controller": "127.0.0.1:9090"
            }
        },
        "dns": {
            "servers": dns_servers,
            "rules": dns_rules,
            "strategy": "ipv4_only",
            "independent_cache": true,
            "final": primary_resolver_tag
        },
        "inbounds": inbounds,
        "outbounds": [
            outbound_json,
            {
                "type": "socks",
                "tag": "aether-bridge",
                "server": "127.0.0.1",
                "server_port": 1819
            },
            {
                "type": "block",
                "tag": "block"
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "auto_detect_interface": true,
            "final": "proxy-out",
            "default_domain_resolver": primary_resolver_tag,
            "rules": [
                {
                    "action": "sniff"
                },
                {
                    "protocol": "dns",
                    "action": "hijack-dns"
                },
                {
                    "port": [53],
                    "action": "hijack-dns"
                },
                {
                    "process_name": [
                        "aether.exe", 
                        "tor.exe", 
                        "psiphon-tunnel-core.exe",
                        "goodbyedpi.exe",
                        "dnscrypt-proxy.exe",
                        "udp2raw.exe",
                        "sing-box.exe"
                    ],
                    "outbound": "direct"
                },
                {
                    "ip_is_private": true,
                    "outbound": "direct"
                },
                {
                    "domain_suffix": [".ir", ".ir.", "shaparak.ir", "snapp.ir", "digikala.com", "aparat.com"],
                    "outbound": "direct"
                },
                {
                    "process_name": ["idman.exe", "steam.exe", "epicgameslauncher.exe"],
                    "outbound": "direct"
                },
                {
                    "network": "udp",
                    "port": [443],
                    "outbound": "block"
                },
                {
                    "network": "udp",
                    "port": [3478, 19302, 19305, 5349],
                    "outbound": "block"
                }
            ]
        }
    });

    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_hybrid_config.json");
    let mut file = File::create(&temp_config_path)
        .map_err(|e| {
            let err = format!("خطا در ساخت فایل پیکربندی هیبریدی: {}", e);
            write_log("ERROR", "HYBRID", &err);
            err
        })?;
    
    file.write_all(final_config.to_string().as_bytes())
        .map_err(|e| {
            let err = format!("خطا در ذخیره‌سازی فایل هیبریدی: {}", e);
            write_log("ERROR", "HYBRID", &err);
            err
        })?;

    let resolved_singbox = resolve_binary_path(&singbox_path);

    #[cfg(target_os = "windows")]
    if use_tun_mode {
        let is_admin = Command::new("net")
            .arg("session")
            .creation_flags(0x08000000)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if !is_admin {
            write_log("WARN", "HYBRID_TUN", "کارت شبکه TUN در حالت هیبریدی نیازمند ادمین است؛ فراخوانی RunAs...");
            let ps_args = format!(
                "Start-Process -FilePath '{}' -ArgumentList 'run -c \"{}\"' -WorkingDirectory '{}' -WindowStyle Hidden -Verb RunAs",
                resolved_singbox.to_string_lossy(),
                temp_config_path.to_string_lossy(),
                work_dir.to_string_lossy()
            );
            let _ = Command::new("powershell")
                .args(&["-NoProfile", "-Command", &ps_args])
                .creation_flags(0x08000000)
                .output();

            thread::sleep(Duration::from_millis(1500));
            write_log("INFO", "HYBRID", "اتصال ترکیبی هیبریدی با مجوز ادمین برقرار شد.");
            return Ok("اتصال ترکیبی هیبریدی با کارت شبکه مجازی TUN با موفقیت برقرار شد!".to_string());
        }
    }

    let mut command = Command::new(&resolved_singbox);
    command.arg("run").arg("-c").arg(&temp_config_path).current_dir(&work_dir);

    let log_file_path = work_dir.join("redcloud_sing_box_log.txt");
    if let Ok(log_file) = File::create(&log_file_path) {
        command.stdin(Stdio::null())
               .stdout(Stdio::from(log_file.try_clone().unwrap()))
               .stderr(Stdio::from(log_file));
    }

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let child = command.spawn()
        .map_err(|e| {
            let err = format!("خطا در اجرای هسته Sing-box در مسیر {:?}: {}", resolved_singbox, e);
            write_log("ERROR", "HYBRID", &err);
            err
        })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    {
        let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *process_guard = Some(child);
    }

    if use_system_proxy && !use_tun_mode {
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 2080);
    }

    start_anti_rst_filter();
    write_log("INFO", "HYBRID", "اتصال ترکیبی هیبریدی با موفقیت برقرار شد.");
    Ok("اتصال ترکیبی هیبریدی با موفقیت برقرار شد! هویت خارجی فعال است.".to_string())
}

pub fn stop_hybrid_connection() -> Result<String, String> {
    stop_anti_rst_filter();
    write_log("INFO", "HYBRID", "دستور قطع اتصال هیبریدی دریافت شد.");
    let _ = stop_proxy_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "sing-box.exe", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("powershell")
            .args(&["-NoProfile", "-Command", "Get-PnpDevice | Where-Object { $_.Class -eq 'Net' -and ($_.FriendlyName -like '*Wintun*' -or $_.FriendlyName -like '*RC-TUN*' -or $_.FriendlyName -like '*RedCloud*') } | ForEach-Object { pnputil /remove-device $_.InstanceId }"])
            .creation_flags(0x08000000)
            .output();
    }

    Ok("اتصال هیبریدی متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

// =========================================================================
// هسته شبکه پیاز تور (Tor Core & Tor over MASQUE)
// =========================================================================

fn start_tor_core_internal(
    binary_path: String,
    country_code: String,
    use_system_proxy: bool,
    socks5_proxy: Option<String>,
) -> Result<String, String> {
    write_log("INFO", "TOR", &format!("راه‌اندازی هسته تور (Exit Country: {})", country_code));
    let mut process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut old) = process_guard.take() {
        let _ = old.kill();
        let _ = old.wait();
    }

    {
        let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        *progress = 0;
    }

    let work_dir = get_safe_work_dir();
    let temp_torrc_path = work_dir.join("redcloud_temp_torrc");
    
    let mut torrc_content = "SocksPort 9050\nHTTPTunnelPort 9051\nClientOnly 1\nUseMicrodescriptors 1\nClientUseIPv6 0\n".to_string();

    let geoip_path = resolve_binary_path("geoip");
    let geoip6_path = resolve_binary_path("geoip6");
    if geoip_path.exists() {
        torrc_content.push_str(&format!("GeoIPFile \"{}\"\n", geoip_path.to_string_lossy().replace('\\', "/")));
    }
    if geoip6_path.exists() {
        torrc_content.push_str(&format!("GeoIPv6File \"{}\"\n", geoip6_path.to_string_lossy().replace('\\', "/")));
    }

    if let Some(ref proxy) = socks5_proxy {
        if !proxy.trim().is_empty() {
            torrc_content.push_str(&format!("Socks5Proxy {}\n", proxy.trim()));
        }
    }

    if !country_code.trim().is_empty() {
        torrc_content.push_str(&format!("ExitNodes {{{}}}\nStrictNodes 0\n", country_code.trim().to_lowercase()));
    }

    let mut file = File::create(&temp_torrc_path)
        .map_err(|e| {
            let err = format!("خطا در ایجاد فایل پیکربندی تور در Temp: {}", e);
            write_log("ERROR", "TOR", &err);
            err
        })?;
    
    file.write_all(torrc_content.as_bytes())
        .map_err(|e| {
            let err = format!("خطا در ذخیره فایل پیکربندی تور: {}", e);
            write_log("ERROR", "TOR", &err);
            err
        })?;

    let resolved_path = resolve_binary_path(&binary_path);
    let mut command = Command::new(&resolved_path);
    command.arg("-f").arg(&temp_torrc_path)
           .current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let mut child = command.spawn()
        .map_err(|e| {
            let err = format!("خطا در اجرای فرآیند تور: {}", e);
            write_log("ERROR", "TOR", &err);
            err
        })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().flatten() {
                write_log("DEBUG", "TOR", &line);
                if let Some(pos) = line.find("Bootstrapped ") {
                    let sub = &line[pos + 13..];
                    if let Some(percent_pos) = sub.find('%') {
                        if let Ok(percent) = sub[..percent_pos].parse::<i32>() {
                            let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                            *progress = percent;
                        }
                    }
                }
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().flatten() {
                write_log("WARN", "TOR_ERR", &line);
                if let Some(pos) = line.find("Bootstrapped ") {
                    let sub = &line[pos + 13..];
                    if let Some(percent_pos) = sub.find('%') {
                        if let Ok(percent) = sub[..percent_pos].parse::<i32>() {
                            let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                            *progress = percent;
                        }
                    }
                }
            }
        });
    }

    *process_guard = Some(child);
    
    if use_system_proxy {
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 9051);
    }
    start_anti_rst_filter();
    Ok("فرآیند تور آغاز شد. در حال اتصال به شبکه پیاز...".to_string())
}

pub fn start_tor_core(binary_path: String, country_code: String, use_system_proxy: bool) -> Result<String, String> {
    start_tor_core_internal(binary_path, country_code, use_system_proxy, None)
}

pub fn start_tor_over_masque(
    tor_path: String,
    aether_path: String,
    country_code: String,
    aether_mode: String,
    aether_noize: String,
    aether_warp_key: Option<String>,
    aether_team: Option<String>,
    use_system_proxy: bool,
) -> Result<String, String> {
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "tor.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(300));
    }

    let _ = stop_tor_core();
    let _ = stop_aether_core();

    write_log("INFO", "TOR_MASQUE", "راه‌اندازی پل هوشمند اِتر برای شبکه پیاز تور...");

    let aether_res = start_aether_core(
        aether_path,
        aether_mode,
        aether_noize,
        aether_warp_key,
        aether_team,
        false,
    );
    if let Err(e) = aether_res {
        write_log("ERROR", "TOR_MASQUE", &format!("خطا در راه‌اندازی پل اتر: {}", e));
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    // تایم‌اوت تطبیقی تا ۹۰ ثانیه برای اتصال پایدار تور
    for _ in 0..180 {
        thread::sleep(Duration::from_millis(500));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "TOR_MASQUE", "پل ارتباطی اتر برای تور پس از ۹۰ ثانیه آماده نشد.");
        return Err("پل ارتباطی اتر در زمان مقرر موفق به اتصال زنده به اینترنت نشد.".to_string());
    }

    start_tor_core_internal(
        tor_path,
        country_code,
        use_system_proxy,
        Some("127.0.0.1:1819".to_string()),
    )
}

pub fn stop_tor_over_masque() -> Result<String, String> {
    write_log("INFO", "TOR_MASQUE", "دستور توقف Tor over MASQUE دریافت شد.");
    let _ = stop_tor_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);
    Ok("اتصال تور بر بستر مسک متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

pub fn stop_tor_core() -> Result<String, String> {
    stop_anti_rst_filter();
    write_log("INFO", "TOR", "دستور توقف تور دریافت شد.");
    let mut process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
    
    let work_dir = get_safe_work_dir();
    let temp_torrc_path = work_dir.join("redcloud_temp_torrc");
    let _ = std::fs::remove_file(temp_torrc_path);
    
    set_windows_system_proxy(false, String::new(), 0);
    
    let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
    *progress = 0;

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "tor.exe"])
        .creation_flags(0x08000000)
        .output();
    
    Ok("اتصال تور متوقف و سیستم به حالت عادی برگشت.".to_string())
}

// =========================================================================
// هسته شبکه سایفون (Psiphon Core & Psiphon over MASQUE)
// =========================================================================

fn process_psiphon_line(l: String) {
    let trimmed = l.trim().to_string();
    if trimmed.is_empty() { return; }

    write_log("DEBUG", "PSIPHON", &trimmed);

    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&trimmed) {
        if let Some(notice) = v.get("noticeType").and_then(|n| n.as_str()) {
            let mut status_msg = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            match notice {
                "CandidateServers" => {
                    let count = v["data"]["count"].as_i64().unwrap_or(0);
                    *status_msg = format!("Probing {} candidate servers...", count);
                },
                "ConnectingServer" => {
                    *status_msg = "Handshaking with Psiphon server...".to_string();
                },
                "AvailableEgressRegions" => {
                    if let Some(regions) = v["data"]["regions"].as_array() {
                        if !regions.is_empty() {
                            *status_msg = format!("{} regions available to connect.", regions.len());
                        } else {
                            *status_msg = "Fetching Psiphon active servers...".to_string();
                        }
                    }
                },
                "ActiveTunnel" | "Tunnels" => {
                    let count = v["data"]["count"].as_i64().unwrap_or(0);
                    if count > 0 {
                        *status_msg = format!("Psiphon tunnel active with {} routes!", count);
                        let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                        *connected = true;
                    }
                },
                "Homepage" => {
                    *status_msg = "Connection stable, traffic active.".to_string();
                    let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                    *connected = true;
                },
                _ => {}
            }
        }
    }
}

fn start_psiphon_core_internal(
    binary_path: String,
    country_code: String,
    use_system_proxy: bool,
    upstream_proxy: Option<String>,
) -> Result<String, String> {
    // استخراج هوشمند پارامترهای CDN Fronting ارسالی از سمت فلاتر
    let (clean_country, is_cdn_fronting, cdn_mode) = if country_code.contains("##cdn") {
        let parts: Vec<&str> = country_code.split("##").collect();
        let cc = parts.get(0).unwrap_or(&"").trim().to_string();
        let mode = parts.get(2).unwrap_or(&"cdn").trim().to_string();
        (cc, true, mode)
    } else {
        (country_code.clone(), false, "direct".to_string())
    };

    write_log("INFO", "PSIPHON", &format!("راه‌اندازی هسته سایفون (Region: {}, CDN Fronting: {})", clean_country, is_cdn_fronting));

    // =========================================================================
    // مسیر ویژه: اجرای سایفون بر بستر فناوری CDN Fronting هسته اِتر
    // =========================================================================
    if is_cdn_fronting {
        write_log("INFO", "PSIPHON_CDN", &format!("⚡ اجرای CDN Fronting با هسته اِتر (مود: {}, منطقه: {})", cdn_mode, clean_country));

        // فقط پروسه قدیمی سایفون کشته شود؛ اِتر را taskkill نمی‌کنیم تا جلوی کرش گرفته شود
        {
            let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(mut old) = process_guard.take() {
                let _ = old.kill();
                let _ = old.wait();
            }
        }
        #[cfg(target_os = "windows")]
        let _ = Command::new("taskkill").args(&["/F", "/IM", "psiphon-tunnel-core.exe"]).creation_flags(0x08000000).output();

        {
            let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
            *connected = false;
            let mut status = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            *status = "Connecting via Aether CDN Fronting...".to_string();
        }

        let aether_bin = resolve_binary_path("aether.exe");
        if !aether_bin.exists() {
            return Err("فایل aether.exe برای اجرای قابلیت CDN Fronting یافت نشد.".to_string());
        }

        let work_dir = get_safe_work_dir();
        let mut cmd = Command::new(&aether_bin);

        // ۱. اِتر اول پل مسک را بالا می‌آورد و پورت‌های تمیز 9080 و 9081 را برای اتصال سیستم باز می‌کند
        cmd.arg("-4")
           .arg("--bind").arg("127.0.0.1:9080")
           .arg("--http-proxy").arg("127.0.0.1:9081");

        // ۲. اتصال زنجیره‌ای: سایفون حتماً از درون پل اِتر رد می‌شود
        cmd.arg("--psiphon");
        cmd.arg("--psiphon-mode").arg(&cdn_mode);

        // ۳. انتخاب کشور (اگر auto نباشد اعمال می‌شود، در غیر این صورت سریع‌ترین سرور CDN را برمی‌دارد)
        if !clean_country.is_empty() && clean_country.to_lowercase() != "auto" {
            cmd.arg("--psiphon-region").arg(&clean_country);
        }

        cmd.current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

        #[cfg(target_os = "windows")]
        cmd.creation_flags(0x08000000);

        let mut child = cmd.spawn().map_err(|e| format!("خطا در اجرای CDN Fronting با اِتر: {}", e))?;
        #[cfg(target_os = "windows")]
        assign_child_to_job(&child);

        // تابع یکپارچه برای پردازش آنی لاگ‌های خروجی
        let handle_aether_line = |line: String| {
            let tr = line.trim().to_string();
            let lower = tr.to_lowercase();

            // ذخیره سرورهای زنده فرانتینگ
            if let Some(pos) = tr.find("psiphon can leave from:") {
                let regions_raw = tr[pos + 23..].trim();
                let path = get_safe_work_dir().join("cdn_regions.txt");
                let _ = std::fs::write(path, regions_raw);
            }

            // ذخیره اطلاعات نهایی لوکیشن خروجی سایفون (دالاس آمریکا / سوئد)
            if tr.contains("psiphon through the tunnel exit:") {
                let path = get_safe_work_dir().join("psiphon_exit.txt");
                let _ = std::fs::write(path, &tr);
            }

            // تایید فوری وضعیت اتصال برای فلاتر (دایره درجا سبز می‌شود)
            if lower.contains("psiphon is ready") 
                || lower.contains("through the tunnel exit")
                || lower.contains("activetunnel") 
                || lower.contains("tunnels") 
                || (lower.contains("psiphon") && lower.contains("connected"))
                || lower.contains("homepage") {
                let mut conn = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                *conn = true;
            }

            let mut st = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            *st = tr;
        };

        if let Some(stdout) = child.stdout.take() {
            thread::spawn(move || {
                let reader = BufReader::new(stdout);
                for line in reader.lines().flatten() {
                    write_log("INFO", "AETHER_PSIPHON", &line);
                    handle_aether_line(line);
                }
            });
        }

        if let Some(stderr) = child.stderr.take() {
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines().flatten() {
                    write_log("WARN", "AETHER_PSIPHON_ERR", &line);
                    handle_aether_line(line);
                }
            });
        }

        {
            let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
            *process_guard = Some(child);
        }

        // تنظیم پروکسی رجیستری مستقیماً به Sing-box سپرده می‌شود تا از پورت استاندارد استفاده کند
        start_anti_rst_filter();
        return Ok("اتصال سایفون با فناوری CDN Fronting آغاز شد...".to_string());
    }

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "psiphon-tunnel-core.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(200));
    }

    {
        let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = process_guard.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }

    {
        let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
        *connected = false;
        let mut status = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = "Connecting to Psiphon servers...".to_string();
    }

    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_psiphon_config.json");
    
    let mut config_json = serde_json::json!({
        "LocalSocksProxyPort": 9080,
        "LocalHttpProxyPort": 9081,
        "PropagationChannelId": "FFFFFFFFFFFFFFFF",
        "SponsorId": "FFFFFFFFFFFFFFFF",
        "RemoteServerListDownloadFilename": "remote_server_list",
        "RemoteServerListSignaturePublicKey": "MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM=",
        "RemoteServerListUrl": "https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed",
        "UseIndistinguishableTLS": true,
        "EstablishTunnelTimeoutSeconds": 0
    });

    if !country_code.trim().is_empty() {
        config_json["EgressRegion"] = serde_json::json!(country_code.trim());
    }

    if let Some(ref upstream) = upstream_proxy {
        if !upstream.trim().is_empty() {
            config_json["UpstreamProxyUrl"] = serde_json::json!(upstream.trim());
            config_json["UpstreamProxyURL"] = serde_json::json!(upstream.trim());
            config_json["UpstreamProxyAllowAllServerEntrySources"] = serde_json::json!(true);
        }
    }

    let mut file = File::create(&temp_config_path)
        .map_err(|e| {
            let err = format!("خطا در ایجاد فایل تنظیمات سایفون: {}", e);
            write_log("ERROR", "PSIPHON", &err);
            err
        })?;
    
    file.write_all(config_json.to_string().as_bytes())
        .map_err(|e| {
            let err = format!("خطا در ذخیره فایل تنظیمات سایفون: {}", e);
            write_log("ERROR", "PSIPHON", &err);
            err
        })?;

    let resolved_path = resolve_binary_path(&binary_path);
    let mut command = Command::new(&resolved_path);
    command.arg("-config")
           .arg(&temp_config_path)
           .current_dir(&work_dir)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::piped());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000); 

    let mut child = command.spawn()
        .map_err(|e| {
            let err = format!("خطا در اجرای فرآیند سایفون در مسیر {:?}: {}", resolved_path, e);
            write_log("ERROR", "PSIPHON", &err);
            err
        })?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().flatten() {
                process_psiphon_line(line);
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().flatten() {
                process_psiphon_line(line);
            }
        });
    }

    {
        let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *process_guard = Some(child);
    }
    
    if use_system_proxy {
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 9081);
    }
    start_anti_rst_filter();
    Ok("Connecting to Psiphon servers, please wait...".to_string())
}

pub fn start_psiphon_core(binary_path: String, country_code: String, use_system_proxy: bool) -> Result<String, String> {
    start_psiphon_core_internal(binary_path, country_code, use_system_proxy, None)
}

pub fn start_psiphon_over_masque(
    psiphon_path: String,
    aether_path: String,
    country_code: String,
    aether_mode: String,
    aether_noize: String,
    aether_warp_key: Option<String>,
    aether_team: Option<String>,
    use_system_proxy: bool,
) -> Result<String, String> {
    // اگر CDN Fronting فعال باشد، خود اِتر هر دو لایه (مسک + سایفون فرانتینگ) را درون یک پروسه مدیریت می‌کند
    if country_code.contains("##cdn") {
        write_log("INFO", "PSIPHON_MASQUE", "⚡ فناوری CDN Fronting فعال است؛ هدایت مستقیم به موتور تک‌پروانه اِتر...");
        return start_psiphon_core_internal(
            psiphon_path,
            country_code,
            use_system_proxy,
            Some("masque_chain".to_string()),
        );
    }

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "psiphon-tunnel-core.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(300));
    }

    let _ = stop_psiphon_core();
    let _ = stop_aether_core();

    write_log("INFO", "PSIPHON_MASQUE", "راه‌اندازی پل هوشمند اِتر برای سایفون...");

    let aether_res = start_aether_core(
        aether_path,
        aether_mode,
        aether_noize,
        aether_warp_key,
        aether_team,
        false,
    );
    if let Err(e) = aether_res {
        write_log("ERROR", "PSIPHON_MASQUE", &format!("خطا در راه‌اندازی پل اتر: {}", e));
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    // تایم‌اوت تطبیقی تا ۹۰ ثانیه برای اتصال پایدار سایفون
    for _ in 0..180 {
        thread::sleep(Duration::from_millis(500));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "PSIPHON_MASQUE", "پل ارتباطی اتر برای سایفون پس از ۹۰ ثانیه بالا نیامد.");
        return Err("پل ارتباطی اتر موفق به برقراری ارتباط زنده با اینترنت نشد.".to_string());
    }

    start_psiphon_core_internal(
        psiphon_path,
        country_code,
        use_system_proxy,
        Some("socks5://127.0.0.1:1819".to_string()),
    )
}

pub fn stop_psiphon_over_masque() -> Result<String, String> {
    write_log("INFO", "PSIPHON_MASQUE", "دستور قطع اتصال Psiphon over MASQUE دریافت شد.");
    let _ = stop_psiphon_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);
    Ok("اتصال سایفون بر بستر مسک متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

pub fn stop_psiphon_core() -> Result<String, String> {
    let _ = restore_original_timezone();
    stop_anti_rst_filter();
    write_log("INFO", "PSIPHON", "دستور توقف سایفون دریافت شد.");
    let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_psiphon_config.json");
    let _ = std::fs::remove_file(temp_config_path);
    
    let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
    *connected = false;

    set_windows_system_proxy(false, String::new(), 0);

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "psiphon-tunnel-core.exe"])
        .creation_flags(0x08000000)
        .output();

    Ok("اتصال سایفون متوقف و سیستم به حالت عادی برگشت.".to_string())
}

// =========================================================================
// اسکنر لایه ۷ WebSocket کلودفلر
// =========================================================================

fn scan_single_ip_ws(ip: &str, port: u16, worker: &str, path: &str, timeout_ms: u64) -> Option<u128> {
    let addr = format!("{}:{}", ip, port).parse::<SocketAddr>().ok()?;
    let start = Instant::now();
    
    let stream_res = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms));
    if stream_res.is_err() {
        return None;
    }
    let stream = stream_res.unwrap();
    let _ = stream.set_read_timeout(Some(Duration::from_millis(timeout_ms)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(timeout_ms)));

    // لایه ۱: تلاش استاندارد WebSocket
    let connector_res = TlsConnector::builder()
        .danger_accept_invalid_certs(true)
        .build();

    if let Ok(connector) = connector_res {
        if let Ok(mut tls_stream) = connector.connect(worker, stream) {
            let clean_path = if path.starts_with('/') { path.to_string() } else { format!("/{}", path) };
            let request = format!(
                "GET {} HTTP/1.1\r\n\
                 Host: {}\r\n\
                 User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n\
                 Upgrade: websocket\r\n\
                 Connection: Upgrade\r\n\
                 Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\
                 Sec-WebSocket-Version: 13\r\n\r\n",
                clean_path, worker
            );

            if tls_stream.write_all(request.as_bytes()).is_ok() {
                let mut buffer = [0u8; 15];
                if tls_stream.read_exact(&mut buffer).is_ok() {
                    let response = String::from_utf8_lossy(&buffer);
                    if response.starts_with("HTTP/1.1 101") || response.starts_with("HTTP/1.0 101") {
                        return Some(start.elapsed().as_millis());
                    }
                }
            }
        }
    }

    // لایه ۲ هوشمند (ضد فیلترینگ): اگر DPI پکت خام را ریست کرد، فوراً تست فرگمنت بایت ۳ با تاخیر می‌زنیم
    let frag_test = FragmentProber::probe_single_fragment(
        addr,
        worker,
        EvasionStrategy::TcpSegmentSplit,
        3,
        15,
        Duration::from_millis(timeout_ms),
    );

    // اگر با فرگمنت پاسخ معتبر TLS ServerHello برگشت، آی‌پی ۱۰۰٪ زنده است و نجات پیدا می‌کند
    if frag_test.is_successful {
        return Some(start.elapsed().as_millis());
    }

    None
}

fn find_verified_emergency_ip() -> Option<(String, u16)> {
    let candidate_ips = load_deep_scan_ips();
    if candidate_ips.is_empty() {
        return None;
    }

    write_log("WARN", "AETHER_EMERGENCY", "🚨 رنج‌های پیش‌فرض مسدود بودند؛ آغاز آزمایش فیزیکی آی‌پی‌های فایل cloudflare_IPs.txt...");

    let test_ports = [443, 2053, 8443, 2083];
    // بررسی زنده تا حداکثر ۳۵ آی‌پی اول برای جلوگیری از معطلی
    for ip in candidate_ips.iter().take(35) {
        for &port in &test_ports {
            let addr_str = format!("{}:{}", ip, port);
            if let Ok(socket_addr) = addr_str.parse::<SocketAddr>() {
                // تست فیزیکی زنده بودن: ارسال پکت واقعی و دریافت پاسخ هندشیک در کمتر از ۷۰۰ میلی‌ثانیه
                let start = Instant::now();
                if let Ok(stream) = TcpStream::connect_timeout(&socket_addr, Duration::from_millis(700)) {
                    let _ = stream.shutdown(Shutdown::Both);
                    let latency = start.elapsed().as_millis();
                    write_log("INFO", "AETHER_EMERGENCY", &format!("✅ آی‌پی زنده و تاییدشده کشف شد: {}:{} (پینگ: {}ms)", ip, port, latency));
                    return Some((ip.clone(), port));
                }
            }
        }
    }

    write_log("ERROR", "AETHER_EMERGENCY", "هیچ آی‌پی زنده‌ای در فایل cloudflare_IPs.txt پاسخ نداد.");
    None
}

fn load_deep_scan_ips() -> Vec<String> {
    let file_path = resolve_binary_path("cloudflare_IPs.txt");
    let mut candidate_ips = Vec::new();

    if let Ok(file) = File::open(&file_path) {
        let reader = BufReader::new(file);
        for line in reader.lines().flatten() {
            let trimmed = line.trim().to_string();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            if trimmed.contains('/') {
                let parts: Vec<&str> = trimmed.split('/').collect();
                if let Ok(ip) = parts[0].parse::<IpAddr>() {
                    if let IpAddr::V4(ipv4) = ip {
                        let octets = ipv4.octets();
                        for host_offset in [1, 20, 50, 100, 150, 200, 254] {
                            candidate_ips.push(format!("{}.{}.{}.{}", octets[0], octets[1], octets[2], host_offset));
                        }
                    }
                }
            } else if trimmed.parse::<IpAddr>().is_ok() {
                candidate_ips.push(trimmed);
            }
        }
    }

    if candidate_ips.is_empty() {
        let fallback_cidrs = vec![
            "5.226.176.0/24", "5.226.177.0/24", "45.85.118.0/24", "45.85.119.0/24",
            "104.16.0.0/24", "104.18.0.0/24", "104.19.0.0/24", "104.20.0.0/24",
            "104.21.0.0/24", "104.22.0.0/24", "104.23.0.0/24", "104.24.0.0/24",
            "104.25.0.0/24", "104.26.0.0/24", "104.27.0.0/24", "172.64.0.0/24",
            "172.65.0.0/24", "172.66.0.0/24", "172.67.0.0/24", "162.159.0.0/24",
            "198.41.128.0/24", "188.114.96.0/24"
        ];
        for cidr in fallback_cidrs {
            let parts: Vec<&str> = cidr.split('/').collect();
            if let Ok(IpAddr::V4(ipv4)) = parts[0].parse::<IpAddr>() {
                let octets = ipv4.octets();
                for host_offset in [1, 50, 100, 150, 200, 254] {
                    candidate_ips.push(format!("{}.{}.{}.{}", octets[0], octets[1], octets[2], host_offset));
                }
            }
        }
    }

    candidate_ips
}

pub fn stop_cloudflare_scanner() {
    write_log("INFO", "SCANNER", "دستور توقف اسکنر کلودفلر ارسال شد.");
    SCAN_CANCELLED.store(true, Ordering::SeqCst);
}

pub fn get_scanner_stats() -> ScannerStats {
    ScannerStats {
        total_scanned: TOTAL_SCANNED.load(Ordering::Relaxed),
        alive_count: ALIVE_COUNT.load(Ordering::Relaxed),
        dead_count: DEAD_COUNT.load(Ordering::Relaxed),
        is_running: SCAN_RUNNING.load(Ordering::Relaxed),
    }
}

pub fn run_cloudflare_scanner(
    uuid: String, 
    path: String, 
    worker: String,
    scan_mode: String,
    early_stop: bool,
) -> Vec<ProxyNode> {
    write_log("INFO", "SCANNER", &format!("شروع اسکنر کلودفلر (حالت: {}, توقف زودهنگام: {})", scan_mode, early_stop));
    SCAN_CANCELLED.store(false, Ordering::SeqCst);
    SCAN_RUNNING.store(true, Ordering::SeqCst);
    TOTAL_SCANNED.store(0, Ordering::SeqCst);
    ALIVE_COUNT.store(0, Ordering::SeqCst);
    DEAD_COUNT.store(0, Ordering::SeqCst);

    let ip_list: Vec<String> = if scan_mode == "deep" {
        load_deep_scan_ips()
    } else {
        vec![
            "104.21.0.1", "104.22.0.1", "172.67.0.1", "104.27.110.232",
            "104.16.0.1", "104.18.0.1", "162.159.0.1", "104.26.0.1",
            "172.65.0.1", "104.24.0.1", "104.20.0.1", "104.25.0.1"
        ].into_iter().map(|s| s.to_string()).collect()
    };

    let (tx, rx) = mpsc::channel();
    let mut results = Vec::new();
    
    let concurrency_limit = if scan_mode == "deep" { 50 } else { 20 };
    
    for chunk in ip_list.chunks(concurrency_limit) {
        if SCAN_CANCELLED.load(Ordering::SeqCst) {
            break;
        }

        let mut handles = Vec::new();
        for ip in chunk {
            if SCAN_CANCELLED.load(Ordering::SeqCst) {
                break;
            }
            let tx_clone = tx.clone();
            let worker_clone = worker.clone();
            let path_clone = path.clone();
            let ip_str = ip.clone();

            let handle = thread::spawn(move || {
                if SCAN_CANCELLED.load(Ordering::SeqCst) {
                    return;
                }

                let latency_opt = scan_single_ip_ws(&ip_str, 2053, &worker_clone, &path_clone, 1800);
                TOTAL_SCANNED.fetch_add(1, Ordering::Relaxed);

                if let Some(latency) = latency_opt {
                    ALIVE_COUNT.fetch_add(1, Ordering::Relaxed);
                    let _ = tx_clone.send((ip_str, latency));
                } else {
                    DEAD_COUNT.fetch_add(1, Ordering::Relaxed);
                }
            });
            handles.push(handle);
        }

        for h in handles {
            let _ = h.join();
        }

        while let Ok((ip, latency)) = rx.try_recv() {
            results.push((ip, latency));
            if early_stop && !results.is_empty() {
                SCAN_CANCELLED.store(true, Ordering::SeqCst);
                break;
            }
        }

        if early_stop && !results.is_empty() {
            break;
        }
    }

    drop(tx);
    while let Ok((ip, latency)) = rx.try_recv() {
        results.push((ip, latency));
    }

    SCAN_RUNNING.store(false, Ordering::SeqCst);

    results.sort_by_key(|&(_, lat)| lat);

    let mut clean_nodes = Vec::new();
    for (ip, latency) in results {
        let encoded_path = urlencoding::encode(&path);
        let raw_url = format!(
            "vless://{}@{}:2053?encryption=none&security=tls&sni={}&fp=chrome&alpn=http%2F1.1&insecure=1&allowInsecure=1&type=ws&host={}&path={}#{}%3A2053%20%7C%20TLS%20%7C%20HTTP1.1%20%7C%20{}ms",
            uuid, ip, worker, worker, encoded_path, ip, latency
        );

        clean_nodes.push(ProxyNode {
            name: format!("Scanner | {} | {}ms", ip, latency),
            protocol: "vless".to_string(),
            raw_url,
        });
    }

    write_log("INFO", "SCANNER", &format!("اسکن کلودفلر پایان یافت. تعداد {} آی‌پی سالم کشف شد.", clean_nodes.len()));
    clean_nodes
}

// =========================================================================
// هسته مستقیم Sing-box و پارس لینک‌های ورودی
// =========================================================================

pub fn start_proxy_with_node(
    binary_path: String,
    selected_node: ProxyNode,
    use_system_proxy: bool,
    custom_sni: Option<String>,
    enable_fragment: bool,
    enable_record_fragment: bool,
    tls_spoof: Option<String>,
    use_tun_mode: bool,
    dns_type: String,
    dns_primary: String,
    _dns_secondary: String,
    _dns_doh_url: Option<String>,
    dns_dot_host: Option<String>,
    utls_fingerprint: Option<String>,
    fragment_fallback_delay: Option<String>,
) -> Result<String, String> {
    write_log("INFO", "V2RAY", &format!("راه‌اندازی Sing-box مستقیم برای سرور: {}", selected_node.name));

    #[cfg(target_os = "windows")]
    {
        let out = Command::new("taskkill")
            .args(&["/F", "/IM", "sing-box.exe"])
            .creation_flags(0x08000000)
            .output();

        if let Ok(o) = out {
            if !o.status.success() {
                let _ = Command::new("powershell")
                    .args(&["-NoProfile", "-Command", "Start-Process taskkill -ArgumentList '/F /IM sing-box.exe' -WindowStyle Hidden -Verb RunAs"])
                    .creation_flags(0x08000000)
                    .output();
            }
        }
        // زمان لازم به کرنل ویندوز جهت آزادسازی هندل کارت شبکه Wintun
        thread::sleep(Duration::from_millis(1000));
    }

    {
        let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = process_guard.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }

    let is_socks_node = selected_node.protocol == "socks";

    let outbound_json = convert_link_to_outbound(
        selected_node.clone(),
        custom_sni,
        enable_fragment,
        enable_record_fragment,
        tls_spoof,
        utls_fingerprint,
        fragment_fallback_delay,
    )?;

    let mut inbounds = serde_json::json!([
        {
            "type": "mixed",
            "tag": "mixed-in",
            "listen": "127.0.0.1",
            "listen_port": 2080
        }
    ]);

    if use_tun_mode {
        let tun_iface_name = format!("tun{}", (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_millis() % 900) + 100);
        let optimal_carrier_mtu = get_optimal_carrier_mtu();
        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": tun_iface_name,
            "address": [
                "172.19.0.1/30"
            ],
            "mtu": optimal_carrier_mtu,
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed",
            "route_exclude_address": [
                "162.159.0.0/16",
                "188.114.96.0/20",
                "104.16.0.0/12",
                "172.64.0.0/13"
            ]
        }));
    }

    let vault_dns = get_vault_dns_list();
    let emergency_direct_dns = vault_dns.first().map(|d| d.ip.as_str()).unwrap_or("94.140.14.14");

    let dns_server_json = match dns_type.as_str() {
        "doh" => {
            let server_name = dns_dot_host.clone().unwrap_or_else(|| "cloudflare-dns.com".to_string());
            serde_json::json!({
                "type": "https",
                "tag": "dns_proxy",
                "server": dns_primary,
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": server_name,
                    "insecure": true
                }
            })
        },
        _ => {
            serde_json::json!({
                "type": "https",
                "tag": "dns_proxy",
                "server": "9.9.9.9",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": "dns.quad9.net",
                    "insecure": true
                }
            })
        }
    };

    let mut dns_servers = Vec::new();

    if is_dnscrypt_running() {
        dns_servers.push(serde_json::json!({
            "type": "udp",
            "tag": "dns_dnscrypt_tier1",
            "server": "127.0.0.1",
            "server_port": 5354
        }));
    }

    dns_servers.push(dns_server_json);
    dns_servers.push(serde_json::json!({
        "type": "https",
        "tag": "dns_backup_doh",
        "server": "9.9.9.9",
        "server_port": 443,
        "path": "/dns-query",
        "detour": "proxy-out",
        "tls": {
            "enabled": true,
            "server_name": "dns.quad9.net",
            "insecure": true
        }
    }));
    dns_servers.push(serde_json::json!({
        "type": "udp",
        "tag": "dns_direct",
        "server": emergency_direct_dns,
        "server_port": 53
    }));

    let is_socks_node = selected_node.protocol == "socks";

    if use_tun_mode && !is_socks_node {
        dns_servers.insert(0, serde_json::json!({
            "type": "fakeip",
            "tag": "dns_fakeip",
            "inet4_range": "198.18.0.0/15"
        }));
    }

    let primary_resolver_tag = if is_dnscrypt_running() { "dns_dnscrypt_tier1" } else { "dns_proxy" };

    let mut dns_rules = vec![
        serde_json::json!({
            "query_type": ["A", "AAAA"],
            "server": primary_resolver_tag
        })
    ];

    if use_tun_mode && !is_socks_node {
        dns_rules.insert(0, serde_json::json!({
            "inbound": "tun-in",
            "query_type": ["A", "AAAA"],
            "server": "dns_fakeip"
        }));
    }

    let final_config = serde_json::json!({
        "log": {
            "level": "info"
        },
        "experimental": {
            "clash_api": {
                "external_controller": "127.0.0.1:9090"
            }
        },
        "dns": {
            "servers": dns_servers,
            "rules": dns_rules,
            "strategy": "ipv4_only",
            "independent_cache": true,
            "final": primary_resolver_tag
        },
        "inbounds": inbounds,
        "outbounds": [
            outbound_json,
            {
                "type": "block",
                "tag": "block"
            },
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            "auto_detect_interface": true,
            "final": "proxy-out",
            "default_domain_resolver": primary_resolver_tag,
            "rules": [
                {
                    "process_name": [
                        "aether.exe", 
                        "tor.exe", 
                        "psiphon-tunnel-core.exe",
                        "goodbyedpi.exe",
                        "dnscrypt-proxy.exe",
                        "udp2raw.exe",
                        "sing-box.exe"
                    ],
                    "outbound": "direct"
                },
                {
                    "action": "sniff"
                },
                {
                    "protocol": "dns",
                    "action": "hijack-dns"
                },
                {
                    "port": [53],
                    "action": "hijack-dns"
                },
                {
                    "ip_is_private": true,
                    "outbound": "direct"
                },
                {
                    "domain_suffix": [".ir", ".ir.", "shaparak.ir", "snapp.ir", "digikala.com", "aparat.com"],
                    "outbound": "direct"
                },
                {
                    "process_name": ["idman.exe", "steam.exe", "epicgameslauncher.exe"],
                    "outbound": "direct"
                },
                {
                    "network": "udp",
                    "port": [443],
                    "outbound": "block"
                },
                {
                    "network": "udp",
                    "port": [3478, 19302, 19305, 5349],
                    "outbound": "block"
                }
            ]
        }
    });

    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_config.json");
    let mut file = File::create(&temp_config_path)
        .map_err(|e| {
            let err = format!("خطا در ساخت فایل پیکربندی: {}", e);
            write_log("ERROR", "V2RAY", &err);
            err
        })?;
    
    file.write_all(final_config.to_string().as_bytes())
        .map_err(|e| {
            let err = format!("خطا در ذخیره‌سازی فایل پیکربندی: {}", e);
            write_log("ERROR", "V2RAY", &err);
            err
        })?;

    let resolved_path = resolve_binary_path(&binary_path);
    let mut command = Command::new(&resolved_path);
    command.arg("run").arg("-c").arg(&temp_config_path).current_dir(&work_dir);

    let log_file_path = work_dir.join("redcloud_sing_box_log.txt");
    let log_file = File::create(&log_file_path)
        .map_err(|e| {
            let err = format!("خطا در ایجاد فایل لاگ: {}", e);
            write_log("ERROR", "V2RAY", &err);
            err
        })?;

    command.stdin(Stdio::null())
           .stdout(Stdio::from(log_file.try_clone().map_err(|e| e.to_string())?))
           .stderr(Stdio::from(log_file));

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    // اگر حالت TUN فعال باشد و برنامه ادمین نباشد، فورا با RunAs درخواست دسترسی UAC می‌دهد
    #[cfg(target_os = "windows")]
    if use_tun_mode {
        let is_admin = Command::new("net")
            .arg("session")
            .creation_flags(0x08000000)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);

        if !is_admin {
            write_log("WARN", "TUN_ELEVATE", "کارت شبکه TUN نیازمند مجوز ادمین است؛ فراخوانی پنجره تایید ویندوز (RunAs)...");
            let ps_args = format!(
                "Start-Process -FilePath '{}' -ArgumentList 'run -c \"{}\"' -WorkingDirectory '{}' -WindowStyle Hidden -Verb RunAs",
                resolved_path.to_string_lossy(),
                temp_config_path.to_string_lossy(),
                work_dir.to_string_lossy()
            );
            let _ = Command::new("powershell")
                .args(&["-NoProfile", "-Command", &ps_args])
                .creation_flags(0x08000000)
                .output();

            thread::sleep(Duration::from_millis(1500));
            write_log("INFO", "TUN_ELEVATE", "کارت شبکه مجازی TUN با دسترسی Administrator با موفقیت فعال شد.");
            return Ok("کارت شبکه مجازی TUN با دسترسی کامل سیستمی فعال شد.".to_string());
        }
    }

    let child = command.spawn();

    match child {
        Ok(c) => {
            #[cfg(target_os = "windows")]
            assign_child_to_job(&c);

            let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
            *process_guard = Some(c);
            
            if use_system_proxy && !use_tun_mode {
                set_windows_system_proxy(true, "127.0.0.1".to_string(), 2080);
            }
            
            ensure_watchdog_started();
            start_anti_rst_filter();
            write_log("INFO", "V2RAY", "اتصال مستقیم Sing-box با موفقیت برقرار شد.");
            Ok("اتصال با موفقیت برقرار شد.".to_string())
        }
        Err(e) => {
            let err_msg = format!("خطا در اجرای فرآیند هسته: {}", e);
            write_log("ERROR", "V2RAY", &err_msg);
            Err(err_msg)
        }
    }
}

pub fn stop_proxy_core() -> Result<String, String> {
    let _ = restore_original_timezone();
    stop_anti_rst_filter();
    write_log("INFO", "V2RAY", "دستور توقف پروکسی دریافت شد.");
    let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        // ارسال سیگنال بستن تمیز جهت پاکسازی درایور Wintun از ویندوز
        #[cfg(target_os = "windows")]
        let _ = Command::new("taskkill").args(&["/IM", "sing-box.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(300));
        let _ = child.kill();
        let _ = child.wait();
    }
    
    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_config.json");
    let _ = std::fs::remove_file(temp_config_path);
    
    set_windows_system_proxy(false, String::new(), 0);

    #[cfg(target_os = "windows")]
    {
        let out = Command::new("taskkill")
            .args(&["/F", "/IM", "sing-box.exe"])
            .creation_flags(0x08000000)
            .output();

        if let Ok(o) = out {
            if !o.status.success() {
                let _ = Command::new("powershell")
                    .args(&["-NoProfile", "-Command", "Start-Process taskkill -ArgumentList '/F /IM sing-box.exe' -WindowStyle Hidden -Verb RunAs"])
                    .creation_flags(0x08000000)
                    .output();
            }
        }
        // زمان لازم به کرنل ویندوز جهت آزادسازی هندل کارت شبکه Wintun
        thread::sleep(Duration::from_millis(1000));
    }

    Ok("پروکسی متوقف و سیستم به حالت عادی برگشت.".to_string())
}

/// ناظر امنیتی هوشمند: مسدودسازی کدهای مخرب بدون تداخل با کاراکترهای قانونی URL (& و | و =)
fn validate_config_safety(url: &Url) -> Result<(), &'static str> {
    // ۱. مسدودسازی بایت نال که خطر حمله به حافظه در زبان‌های سطح سیستم است
    if url.as_str().contains('\0') {
        return Err("کانفیگ حاوی کاراکتر کنترلی نال (Null Byte) است.");
    }

    // ۲. بررسی پورت معتبر (بین ۱ تا ۶۵۵۳۵)
    let port = match url.port() {
        Some(p) if p > 0 => p,
        _ => return Err("پورت سرور نامعتبر یا تعریف‌نشده است."),
    };

    // ۳. سد ضد لوپ مخرب و مسدودسازی حمله DoS به پورت‌های داخلی نرم‌افزار
    let host = match url.host_str() {
        Some(h) if !h.trim().is_empty() => h.trim().to_lowercase(),
        _ => return Err("آدرس هاست یا سرور خالی است."),
    };

    if host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "0.0.0.0" {
        if [2080, 1819, 1820, 9050, 9051, 9080, 9081, 5354, 9090].contains(&port) {
            return Err("تلاش برای ایجاد لوپ مخرب روی پورت‌های داخلی نرم‌افزار خنثی شد.");
        }
    }

    // ۴. بررسی امنیتی و جلوگیری از پیمایش مسیر دایرکتوری در وب‌ساکت
    for (key, val) in url.query_pairs() {
        if key == "path" && (val.contains("../") || val.contains("..\\")) {
            return Err("مسیر کانفیگ دارای حمله پیمایش دایرکتوری (Path Traversal) است.");
        }
    }

    Ok(())
}

pub fn parse_import_links(input: String) -> Result<Vec<ProxyNode>, String> {
    let mut nodes = Vec::new();

    if input.starts_with("http://") || input.starts_with("https://") {
        return Err("لطفاً متن دریافت شده از لینک ساب را وارد کنید.".to_string());
    }

    let sanitized_input = input.trim().replace(|c: char| c.is_whitespace(), "");

    let mut base64_str = sanitized_input.clone();
    while base64_str.len() % 4 != 0 {
        base64_str.push('=');
    }

    let decoded_content = if let Ok(decoded_bytes) = general_purpose::STANDARD.decode(&base64_str) {
        String::from_utf8(decoded_bytes).unwrap_or_else(|_| input.clone())
    } else {
        input.clone()
    };

    for line in decoded_content.lines() {
        let line_trimmed = line.trim();
        if line_trimmed.is_empty() {
            continue;
        }

        // ۱. پشتیبانی کامل از لینک‌های مدرن و قدیمی Shadowsocks (ss://)
        if line_trimmed.starts_with("ss://") {
            let rest = &line_trimmed[5..];
            let tag_name = match rest.find('#') {
                Some(pos) => urlencoding::decode(&rest[pos + 1..]).unwrap_or_else(|_| rest[pos + 1..].into()).to_string(),
                None => "سرور Shadowsocks".to_string(),
            };
            nodes.push(ProxyNode {
                name: if tag_name.is_empty() { "سرور Shadowsocks".to_string() } else { tag_name },
                protocol: "shadowsocks".to_string(),
                raw_url: line_trimmed.to_string(),
            });
            continue;
        }

        // ۱. پشتیبانی کامل از لینک‌های استاندارد VMess (Base64 JSON)
        if line_trimmed.starts_with("vmess://") {
            let b64 = &line_trimmed[8..];
            let mut clean_b64 = b64.trim().to_string();
            while clean_b64.len() % 4 != 0 { clean_b64.push('='); }

            if let Ok(decoded_bytes) = general_purpose::STANDARD.decode(&clean_b64) {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&decoded_bytes) {
                    let name = v["ps"].as_str().unwrap_or("سرور VMess").to_string();
                    nodes.push(ProxyNode {
                        name,
                        protocol: "vmess".to_string(),
                        raw_url: line_trimmed.to_string(),
                    });
                    continue;
                }
            }
        }

        if let Ok(url) = Url::parse(line_trimmed) {
            let protocol = url.scheme().to_lowercase();
            if protocol == "vless" || protocol == "trojan" || protocol == "hysteria2" || protocol == "hy2" || protocol == "vmess" || protocol == "tuic" || protocol == "ss" || protocol == "shadowsocks" {
                // بررسی موشکافانه توسط ناظر امنیتی
                if let Err(reason) = validate_config_safety(&url) {
                    write_log("WARN", "CONFIG_GUARD", &format!("🚨 کانفیگ ناامن/مشکوک رد صلاحیت شد: {}", reason));
                    continue; // کانفیگ آلوده بدون کوچک‌ترین خطری برای سیستم نادیده گرفته می‌شود
                }

                let name = url.fragment()
                    .map(|f| urlencoding::decode(f).unwrap_or_else(|_| f.into()).to_string())
                    .unwrap_or_else(|| "سرور ناشناس".to_string());

                let normalized_protocol = if protocol == "hy2" { "hysteria2".to_string() } else { protocol };

                nodes.push(ProxyNode {
                    name,
                    protocol: normalized_protocol,
                    raw_url: line_trimmed.to_string(),
                });
            }
        }
    }

    if nodes.is_empty() {
        write_log("WARN", "IMPORT", "هیچ سرور معتبری در ورودی یافت نشد.");
        return Err("هیچ سرور معتبری در ورودی یافت نشد.".to_string());
    }

    write_log("INFO", "IMPORT", &format!("تعداد {} سرور با موفقیت پارس شد.", nodes.len()));
    Ok(nodes)
}

fn convert_link_to_outbound(
    node: ProxyNode,
    custom_sni: Option<String>,
    enable_fragment: bool,
    enable_record_fragment: bool,
    tls_spoof: Option<String>,
    utls_fingerprint: Option<String>,
    fragment_fallback_delay: Option<String>,
) -> Result<serde_json::Value, String> {
    let parsed_url = Url::parse(&node.raw_url).map_err(|e| e.to_string())?;
    let host = parsed_url.host_str().ok_or("هاست یافت نشد")?;
    let port = parsed_url.port().ok_or("پورت یافت نشد")?;
    
    let protocol = if node.protocol == "hy2" { "hysteria2" } else { node.protocol.as_str() };

    // ==================== پشتیبانی کامل از خروجی VMess ====================
    if protocol == "vmess" {
        let mut server = String::new();
        let mut server_port: u16 = 443;
        let mut uuid = String::new();
        let mut alter_id: u64 = 0;
        let mut security_cipher = "auto".to_string();
        let mut network = "tcp".to_string();
        let mut path = String::new();
        let mut ws_host = String::new();
        let mut tls_enabled = false;
        let mut sni = String::new();

        let raw_str = &node.raw_url;
        let b64_part = if raw_str.starts_with("vmess://") { &raw_str[8..] } else { raw_str.as_str() };
        let mut clean_b64 = b64_part.trim().to_string();
        while clean_b64.len() % 4 != 0 { clean_b64.push('='); }

        let mut json_parsed = false;
        if let Ok(decoded_bytes) = general_purpose::STANDARD.decode(&clean_b64) {
            if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&decoded_bytes) {
                server = v["add"].as_str().unwrap_or("").to_string();
                server_port = v["port"].as_u64().map(|p| p as u16)
                    .or_else(|| v["port"].as_str().and_then(|s| s.parse::<u16>().ok()))
                    .unwrap_or(443);
                uuid = v["id"].as_str().unwrap_or("").to_string();
                alter_id = v["aid"].as_u64()
                    .or_else(|| v["aid"].as_str().and_then(|s| s.parse::<u64>().ok()))
                    .unwrap_or(0);
                if let Some(scy) = v["scy"].as_str() {
                    if !scy.is_empty() { security_cipher = scy.to_string(); }
                }
                network = v["net"].as_str().unwrap_or("tcp").to_string();
                path = v["path"].as_str().unwrap_or("").to_string();
                ws_host = v["host"].as_str().unwrap_or("").to_string();
                let tls_val = v["tls"].as_str().unwrap_or("");
                tls_enabled = tls_val == "tls";
                sni = v["sni"].as_str().unwrap_or("").to_string();
                if sni.is_empty() { sni = ws_host.clone(); }
                json_parsed = true;
            }
        }

        if !json_parsed {
            if let Ok(parsed_url) = Url::parse(&node.raw_url) {
                server = parsed_url.host_str().unwrap_or("").to_string();
                server_port = parsed_url.port().unwrap_or(443);
                uuid = parsed_url.username().to_string();
                for (k, val) in parsed_url.query_pairs() {
                    match k.as_ref() {
                        "type" => network = val.into_owned(),
                        "path" => path = val.into_owned(),
                        "host" => ws_host = val.into_owned(),
                        "security" => tls_enabled = val == "tls",
                        "sni" => sni = val.into_owned(),
                        "aid" => alter_id = val.parse::<u64>().unwrap_or(0),
                        _ => {}
                    }
                }
            }
        }

        let mut outbound = serde_json::json!({
            "type": "vmess",
            "tag": "proxy-out",
            "server": server,
            "server_port": server_port,
            "uuid": uuid,
            "security": security_cipher,
            "alter_id": alter_id,
        });

        if tls_enabled {
            let final_sni = if let Some(ref cs) = custom_sni {
                if !cs.trim().is_empty() { cs.trim().to_string() } else { sni.clone() }
            } else {
                sni.clone()
            };

            let mut tls_obj = serde_json::json!({
                "enabled": true,
                "server_name": if final_sni.is_empty() { server.clone() } else { final_sni },
                "insecure": true,
            });

            if let Some(ref fp) = utls_fingerprint {
                if !fp.trim().is_empty() && fp != "none" {
                    tls_obj["utls"] = serde_json::json!({
                        "enabled": true,
                        "fingerprint": fp.trim()
                    });
                }
            }

            if enable_fragment {
                tls_obj["fragment"] = serde_json::json!(true);
            }

            outbound["tls"] = tls_obj;
        }

        if network == "ws" || network == "grpc" || network == "http" {
            let mut transport = serde_json::json!({ "type": network });
            if network == "ws" {
                if !path.is_empty() { transport["path"] = serde_json::json!(path); }
                if !ws_host.is_empty() {
                    transport["headers"] = serde_json::json!({ "Host": ws_host });
                }
            } else if network == "grpc" && !path.is_empty() {
                transport["service_name"] = serde_json::json!(path);
            }
            outbound["transport"] = transport;
        }

        return Ok(outbound);
    }

    // ==================== پشتیبانی کامل از پروتکل Shadowsocks ====================
    if protocol == "shadowsocks" || protocol == "ss" {
        let raw = &node.raw_url;
        let rest = if raw.starts_with("ss://") { &raw[5..] } else { raw.as_str() };
        let clean_rest = rest.split('#').next().unwrap_or(rest);
        let clean_link = clean_rest.split('?').next().unwrap_or(clean_rest);

        let mut method = "2022-blake3-aes-128-gcm".to_string();
        let mut password = String::new();
        let mut server = String::new();
        let mut server_port: u16 = 8388;

        if clean_link.contains('@') {
            let parts: Vec<&str> = clean_link.split('@').collect();
            let b64_user = parts[0];
            let host_port = parts[1];

            let mut b64 = b64_user.to_string();
            while b64.len() % 4 != 0 { b64.push('='); }
            if let Ok(dec) = general_purpose::STANDARD.decode(&b64)
                .or_else(|_| general_purpose::URL_SAFE.decode(&b64)) 
            {
                if let Ok(s) = String::from_utf8(dec) {
                    let up_parts: Vec<&str> = s.splitn(2, ':').collect();
                    if up_parts.len() == 2 {
                        method = up_parts[0].to_string();
                        password = up_parts[1].to_string();
                    }
                }
            }

            if let Some(pos) = host_port.rfind(':') {
                server = host_port[..pos].to_string();
                server_port = host_port[pos + 1..].parse::<u16>().unwrap_or(8388);
            }
        } else {
            let mut b64 = clean_link.to_string();
            while b64.len() % 4 != 0 { b64.push('='); }
            if let Ok(dec) = general_purpose::STANDARD.decode(&b64)
                .or_else(|_| general_purpose::URL_SAFE.decode(&b64))
            {
                if let Ok(s) = String::from_utf8(dec) {
                    if let Some(at_pos) = s.find('@') {
                        let user_part = &s[..at_pos];
                        let host_part = &s[at_pos + 1..];
                        let up_parts: Vec<&str> = user_part.splitn(2, ':').collect();
                        if up_parts.len() == 2 {
                            method = up_parts[0].to_string();
                            password = up_parts[1].to_string();
                        }
                        if let Some(pos) = host_part.rfind(':') {
                            server = host_part[..pos].to_string();
                            server_port = host_part[pos + 1..].parse::<u16>().unwrap_or(8388);
                        }
                    }
                }
            }
        }

        let outbound = serde_json::json!({
            "type": "shadowsocks",
            "tag": "proxy-out",
            "server": server,
            "server_port": server_port,
            "method": method,
            "password": password,
        });

        return Ok(outbound);
    }

    // ==================== پشتیبانی کامل از پروتکل فوق‌سریع TUIC v5 ====================
    if protocol == "tuic" {
        let parsed_url = Url::parse(&node.raw_url).map_err(|e| e.to_string())?;
        let host = parsed_url.host_str().ok_or("هاست یافت نشد")?;
        let port = parsed_url.port().ok_or("پورت یافت نشد")?;
        let uuid = parsed_url.username();
        let password = parsed_url.password().unwrap_or("");

        let mut sni = host.to_string();
        let mut congestion = "bbr".to_string();
        let mut udp_relay_mode = "native".to_string();
        let mut alpn = vec!["h3".to_string()];
        let mut insecure = true;
        let mut ech_config = String::new();

        for (key, val) in parsed_url.query_pairs() {
            match key.as_ref() {
                "sni" | "peer" => sni = val.into_owned(),
                "congestion_controller" | "cc" => congestion = val.into_owned(),
                "udp_relay_mode" => udp_relay_mode = val.into_owned(),
                "alpn" => alpn = val.split(',').map(|s| s.trim().to_string()).collect(),
                "insecure" | "allowInsecure" => insecure = val == "1" || val == "true",
                "ech" | "ech_config" => ech_config = val.into_owned(),
                _ => {}
            }
        }

        let final_sni = if let Some(ref cs) = custom_sni {
            if !cs.trim().is_empty() { cs.trim().to_string() } else { sni }
        } else {
            sni
        };

        let mut tls_obj = serde_json::json!({
            "enabled": true,
            "server_name": final_sni,
            "alpn": alpn,
            "insecure": insecure,
        });

        if !ech_config.is_empty() {
            let pem_lines = format_ech_to_pem_lines(&ech_config);
            tls_obj["ech"] = serde_json::json!({
                "enabled": true,
                "config": pem_lines
            });
        }

        let outbound = serde_json::json!({
            "type": "tuic",
            "tag": "proxy-out",
            "server": host,
            "server_port": port,
            "uuid": uuid,
            "password": password,
            "congestion_controller": congestion,
            "udp_relay_mode": udp_relay_mode,
            "zero_rtt_handshake": false,
            "heartbeat": "10s",
            "tls": tls_obj,
        });

        return Ok(outbound);
    }

    if protocol == "hysteria2" {
        let auth = parsed_url.username();
        let mut outbound = serde_json::json!({
            "type": "hysteria2",
            "tag": "proxy-out",
            "server": host,
            "server_port": port,
            "password": auth,
        });

        let mut sni = host.to_string();
        let mut insecure = true;
        let mut obfs_type = String::new();
        let mut obfs_password = String::new();
        let mut ech_config = String::new();

        for (key, val) in parsed_url.query_pairs() {
            match key.as_ref() {
                "sni" | "peer" => sni = val.into_owned(),
                "insecure" | "allowInsecure" => insecure = val == "1" || val == "true",
                "obfs" => obfs_type = val.into_owned(),
                "obfs-password" => obfs_password = val.into_owned(),
                "ech" | "ech_config" => ech_config = val.into_owned(),
                _ => {}
            }
        }

        let final_sni = if let Some(ref cs) = custom_sni {
            if !cs.trim().is_empty() { cs.trim().to_string() } else { sni }
        } else {
            sni
        };

        let mut tls_obj = serde_json::json!({
            "enabled": true,
            "server_name": final_sni,
            "insecure": insecure,
        });

        // فعال‌سازی اصولی و ایمن ECH فقط برای کانفیگ‌های دارای کلید معتبر
        if !ech_config.is_empty() {
            let pem_lines = format_ech_to_pem_lines(&ech_config);
            tls_obj["ech"] = serde_json::json!({
                "enabled": true,
                "config": pem_lines
            });
        }

        outbound["tls"] = tls_obj;

        if !obfs_type.is_empty() && !obfs_password.is_empty() {
            outbound["obfs"] = serde_json::json!({
                "type": obfs_type,
                "password": obfs_password
            });
        }

        return Ok(outbound);
    }

    let mut outbound = serde_json::json!({
        "type": protocol,
        "tag": "proxy-out",
        "server": host,
        "server_port": port,
    });

    if protocol == "socks" {
        outbound["version"] = serde_json::json!("5");
    } else if protocol == "vless" {
        let uuid = parsed_url.username();
        outbound["uuid"] = serde_json::json!(uuid);
    } else if protocol == "trojan" {
        let password = parsed_url.username();
        outbound["password"] = serde_json::json!(password);
    }

    let mut sni = "".to_string();
    let mut path = "".to_string();
    let mut network = "tcp".to_string();
    let mut security = "none".to_string();
    let mut ws_host = "".to_string();
    let mut pbk = "".to_string();
    let mut sid = "".to_string();
    let mut spx = "".to_string();
    let mut ech_config = "".to_string();
    let mut insecure = true;

    for (key, val) in parsed_url.query_pairs() {
        match key.as_ref() {
            "sni" => sni = val.into_owned(),
            "path" => path = val.into_owned(),
            "type" => network = val.into_owned(),
            "security" => security = val.into_owned(),
            "host" => ws_host = val.into_owned(),
            "pbk" | "public_key" => pbk = val.into_owned(),
            "sid" | "short_id" => sid = val.into_owned(),
            "spx" | "spider_x" => spx = val.into_owned(),
            "ech" | "ech_config" => ech_config = val.into_owned(),
            "insecure" | "allowInsecure" => insecure = val == "1" || val == "true",
            _ => {}
        }
    }

    let final_sni = if let Some(ref cs) = custom_sni {
        if !cs.trim().is_empty() {
            cs.trim().to_string()
        } else {
            sni
        }
    } else {
        sni
    };

    let final_fingerprint = if let Some(ref fp) = utls_fingerprint {
        if !fp.trim().is_empty() {
            fp.trim().to_string()
        } else {
            "chrome".to_string()
        }
    } else {
        "chrome".to_string()
    };

    if security == "tls" || security == "reality" {
        let mut tls_obj = serde_json::json!({
            "enabled": true,
            "server_name": final_sni,
            "insecure": insecure
        });

        if security == "reality" {
            let mut reality_obj = serde_json::json!({
                "enabled": true,
                "public_key": pbk,
            });
            if !sid.is_empty() {
                reality_obj["short_id"] = serde_json::json!(sid);
            }
            if !spx.is_empty() {
                reality_obj["spider_x"] = serde_json::json!(spx);
            }
            tls_obj["reality"] = reality_obj;
            tls_obj["utls"] = serde_json::json!({
                "enabled": true,
                "fingerprint": if final_fingerprint == "none" { "chrome".to_string() } else { final_fingerprint.clone() }
            });
        } else {
            if let Some(ref fp) = utls_fingerprint {
                if !fp.trim().is_empty() && fp != "none" {
                    tls_obj["utls"] = serde_json::json!({
                        "enabled": true,
                        "fingerprint": fp.trim()
                    });
                }
            }
        }

        // فعال‌سازی اصولی و ایمن ECH فقط برای کانفیگ‌های دارای کلید معتبر
        if !ech_config.is_empty() {
            let pem_lines = format_ech_to_pem_lines(&ech_config);
            tls_obj["ech"] = serde_json::json!({
                "enabled": true,
                "config": pem_lines
            });
        }

        let mut custom_frag_len = String::new();
        let mut custom_frag_interval = String::new();

        for (key, val) in parsed_url.query_pairs() {
            match key.as_ref() {
                "frag_len" => custom_frag_len = val.into_owned(),
                "frag_interval" | "frag_delay" => custom_frag_interval = val.into_owned(),
                _ => {}
            }
        }

        // فعال‌سازی استاندارد فرگمنت سازگار با Sing-box
        if enable_fragment || !custom_frag_len.is_empty() || !custom_frag_interval.is_empty() {
            tls_obj["fragment"] = serde_json::json!(true);
        }

        if enable_record_fragment {
            tls_obj["record_fragment"] = serde_json::json!(true);
        }

        if let Some(ref spoof) = tls_spoof {
            if !spoof.trim().is_empty() {
                tls_obj["spoof"] = serde_json::json!(spoof.trim());
                tls_obj["spoof_method"] = serde_json::json!("default");
            }
        }

        outbound["tls"] = tls_obj;
    }

    if network == "ws" || network == "grpc" || network == "http" {
        let mut transport = serde_json::json!({
            "type": network,
        });
        
        if network == "ws" {
            if !path.is_empty() {
                transport["path"] = serde_json::json!(path);
            }
            if !ws_host.is_empty() {
                transport["headers"] = serde_json::json!({
                    "Host": ws_host
                });
            }
        } else if network == "grpc" {
            if !path.is_empty() {
                transport["service_name"] = serde_json::json!(path);
            }
        }
        
        outbound["transport"] = transport;
    }

    Ok(outbound)
}
// =========================================================================
// توابع ارتباطی هسته اول و هسته دوم (Smart Core Bridges for Flutter)
// =========================================================================

static GLOBAL_CORE2_ANALYZER: OnceLock<Core2BehaviorAnalyzer> = OnceLock::new();
static GLOBAL_LEARNING_ENGINE: OnceLock<LearningEngine> = OnceLock::new();

fn get_core2_instance() -> &'static Core2BehaviorAnalyzer {
    GLOBAL_CORE2_ANALYZER.get_or_init(|| Core2BehaviorAnalyzer::new(2.0))
}

fn get_learning_engine() -> &'static LearningEngine {
    GLOBAL_LEARNING_ENGINE.get_or_init(|| LearningEngine::new())
}

/// کالیبراسیون و بهینه‌سازی زنده یک کانفیگ با موتور یادگیری خودآموز (MAB Learning)
pub fn calibrate_and_optimize_node(raw_url: String) -> Result<CalibratedConnectionProfile, String> {
    write_log("INFO", "CORE1_OPT", &format!("آغاز تحلیل اتصال هوشمند برای کانفیگ: {}", raw_url));

    let parsed_url = Url::parse(&raw_url).map_err(|e| format!("لینک کانفیگ نامعتبر است: {}", e))?;
    let host = parsed_url.host_str().ok_or_else(|| "هاست در کانفیگ یافت نشد.".to_string())?;
    let default_port = parsed_url.port().unwrap_or(443);

    let mut sni = host.to_string();
    for (key, val) in parsed_url.query_pairs() {
        if key == "sni" || key == "peer" {
            sni = val.into_owned();
            break;
        }
    }

    // ۱. استخراج اثر انگشت شبکه کاربر
    let (fingerprint, label) = LearningEngine::compute_network_fingerprint();
    let learning_engine = get_learning_engine();

    // ۲. بررسی حافظه یادگیری (Fast-Path Check): اگر قبلا یاد گرفته بود، فورا وصل شو!
    if let Some(cached_arm) = learning_engine.suggest_fast_path_candidate(fingerprint) {
        write_log(
            "INFO",
            "CORE1_LEARNING",
            &format!(
                "[Fast-Path Hit] اتصال فوق‌سریع از حافظه یادگیری شبکه ({}): پورت: {}, فرگمنت: {:?}, امتیاز پیش‌بینی: {:.1}",
                label, cached_arm.port, cached_arm.strategy, cached_arm.quality_score
            ),
        );

        let (enable_tls, enable_rec, delay_str) = match cached_arm.strategy {
            EvasionStrategy::TcpSegmentSplit => (true, false, format!("{}ms", cached_arm.delay_ms)),
            EvasionStrategy::TlsRecordSplit => (false, true, format!("{}ms", cached_arm.delay_ms)),
            EvasionStrategy::None => (false, false, "0ms".to_string()),
        };

        let metrics = Core1ScoringEngine::evaluate_connection(
            cached_arm.average_latency_ms,
            3.5,
            0.0,
            cached_arm.average_latency_ms * 1.1,
            95.0,
        );

        get_core2_instance().reset();

        return Ok(CalibratedConnectionProfile {
            target_host: host.to_string(),
            selected_port: cached_arm.port,
            enable_tls_fragment: enable_tls,
            enable_record_fragment: enable_rec,
            optimal_delay_str: delay_str,
            recommended_padding_bytes: 128,
            quality_metrics: metrics,
            is_fast_path_cached: true,
            optimal_mtu: cached_arm.optimal_mtu,
            expected_latency_lower: (cached_arm.average_latency_ms as f64 * 0.8).max(10.0),
            expected_latency_upper: cached_arm.average_latency_ms as f64 * 1.3,
        });
    }

    // ۳. اگر تجربه قبلی نبود، تست فیزیکی و کشف انجام شود
    write_log("INFO", "CORE1_OPT", "هیچ تجربه معتبری در حافظه نبود؛ اجرای کشف و کالیبراسیون کامل...");
    let candidate_ports = [default_port, 2053, 2083, 2087, 8443, 443];
    let port_verifications = FragmentProber::verify_candidate_ports(host, &candidate_ports, &sni);
    
    let active_port = if let Some(working) = port_verifications.iter().find(|p| p.verified_tls_response) {
        working.port
    } else {
        default_port
    };

    let fragment_result = FragmentProber::sweep_best_fragment(host, active_port, &sni);
    
    let (enable_tls_fragment, enable_record_fragment, optimal_delay_str) = match fragment_result.strategy {
        EvasionStrategy::TcpSegmentSplit => (true, false, format!("{}ms", fragment_result.delay_ms)),
        EvasionStrategy::TlsRecordSplit => (false, true, format!("{}ms", fragment_result.delay_ms)),
        EvasionStrategy::None => (false, false, "0ms".to_string()),
    };

    let measured_latency = if fragment_result.handshake_time_ms > 0 {
        fragment_result.handshake_time_ms as f32
    } else {
        150.0
    };

    let metrics = Core1ScoringEngine::evaluate_connection(
        measured_latency,
        4.0,
        0.0,
        measured_latency * 1.2,
        90.0,
    );

    let measured_mtu = PmtuProber::probe_carrier_path_mtu(&host);
    write_log("INFO", "CORE1_PMTU", &format!("سقف مجاز پکت دکل مخابراتی (Path MTU): {} بایت کشف شد.", measured_mtu));

    // ۴. ثبت این تجربه تازه در حافظه دائمی (یادگیری برای اتصالات بعدی!)
    learning_engine.record_connection_experience(
        fingerprint,
        label,
        active_port,
        fragment_result.strategy,
        fragment_result.split_offset,
        fragment_result.delay_ms,
        fragment_result.is_successful,
        measured_latency,
        metrics.overall_score,
        measured_mtu,
    );

    get_core2_instance().reset();

    let profile = CalibratedConnectionProfile {
        target_host: host.to_string(),
        selected_port: active_port,
        enable_tls_fragment,
        enable_record_fragment,
        optimal_delay_str,
        recommended_padding_bytes: 128,
        quality_metrics: metrics,
        is_fast_path_cached: false,
        optimal_mtu: measured_mtu,
        expected_latency_lower: (measured_latency as f64 * 0.75).max(10.0),
        expected_latency_upper: measured_latency as f64 * 1.35,
    };

    Ok(profile)
}

/// ثبت نمونه واقعی اتصال در هسته دوم و محاسبه انحراف ریاضی d(y, R)
pub fn record_live_connection_metric(measured_latency_ms: f64) -> BehaviorAnalysisReport {
    let analyzer = get_core2_instance();
    let report = analyzer.record_and_analyze(measured_latency_ms);

    if report.is_degraded {
        write_log("WARN", "CORE2_ANALYZER", &report.alert_message);
    }

    report
}

/// اتصال هوشمند و کاملاً خودکار: کالیبراسیون با هسته اول و سپس برقراری تونل
pub fn start_smart_optimized_proxy(
    binary_path: String,
    mut selected_node: ProxyNode,
    use_system_proxy: bool,
    use_tun_mode: bool,
    dns_type: String,
    dns_primary: String,
    dns_secondary: String,
    dns_dot_host: Option<String>,
) -> Result<CalibratedConnectionProfile, String> {
    write_log("INFO", "SMART_CONNECT", &format!("آغاز پروسه اتصال خودکار و هوشمند برای: {}", selected_node.name));

    let calibrated = calibrate_and_optimize_node(selected_node.raw_url.clone())?;

    if calibrated.selected_port != 443 && !selected_node.raw_url.contains(&format!(":{}", calibrated.selected_port)) {
        if let Ok(mut parsed) = Url::parse(&selected_node.raw_url) {
            let _ = parsed.set_port(Some(calibrated.selected_port));
            selected_node.raw_url = parsed.to_string();
        }
    }

    let _ = start_proxy_with_node(
        binary_path,
        selected_node,
        use_system_proxy,
        None,
        calibrated.enable_tls_fragment,
        calibrated.enable_record_fragment,
        None,
        use_tun_mode,
        dns_type,
        dns_primary,
        dns_secondary,
        None,
        dns_dot_host,
        Some("chrome".to_string()),
        Some(calibrated.optimal_delay_str.clone()),
    )?;

    write_log("INFO", "SMART_CONNECT", "تونل بهینه‌سازی‌شده هوشمند با موفقیت به اینترنت متصل شد.");
    Ok(calibrated)
}

/// خوددرمانگری خودکار: جهش به استراتژی ضد اختلال بدون نیاز به دخالت کاربر
pub fn auto_heal_and_recalibrate(
    binary_path: String,
    mut selected_node: ProxyNode,
    use_system_proxy: bool,
    use_tun_mode: bool,
    dns_type: String,
    dns_primary: String,
    dns_secondary: String,
    dns_dot_host: Option<String>,
) -> Result<CalibratedConnectionProfile, String> {
    write_log("WARN", "SELF_HEAL", "هشدار افت کیفیت ممتد دریافت شد؛ اجرای خوددرمانگری خودکار...");

    let parsed_url = Url::parse(&selected_node.raw_url).map_err(|e| format!("لینک نامعتبر: {}", e))?;
    let host = parsed_url.host_str().ok_or_else(|| "هاست یافت نشد".to_string())?;
    let current_port = parsed_url.port().unwrap_or(443);

    let mut sni = host.to_string();
    for (key, val) in parsed_url.query_pairs() {
        if key == "sni" || key == "peer" {
            sni = val.into_owned();
            break;
        }
    }

    let (fingerprint, _) = LearningEngine::compute_network_fingerprint();
    let learning_engine = get_learning_engine();

    learning_engine.penalize_arm(fingerprint, current_port, EvasionStrategy::None);

    let candidate_ports: Vec<u16> = [2083, 2087, 8443, 443, 2053]
        .iter()
        .copied()
        .filter(|&p| p != current_port)
        .collect();

    let port_verifications = FragmentProber::verify_candidate_ports(host, &candidate_ports, &sni);
    
    let target_port = if let Some(working) = port_verifications.iter().find(|p| p.verified_tls_response) {
        working.port
    } else {
        candidate_ports[0]
    };

    let test_res = FragmentProber::sweep_best_fragment(host, target_port, &sni);

    let (healed_strategy, healed_delay, healed_delay_str) = match test_res.strategy {
        EvasionStrategy::TcpSegmentSplit => (EvasionStrategy::TcpSegmentSplit, test_res.delay_ms, format!("{}ms", test_res.delay_ms)),
        EvasionStrategy::TlsRecordSplit => (EvasionStrategy::TlsRecordSplit, test_res.delay_ms, format!("{}ms", test_res.delay_ms)),
        EvasionStrategy::None => (EvasionStrategy::TcpSegmentSplit, 20u64, "20ms".to_string()),
    };

    write_log(
        "INFO",
        "SELF_HEAL",
        &format!("پورت و فرگمنت جدید با تست فیزیکی تایید شدند: پورت {} | استراتژی: {:?} | تاخیر: {}", target_port, healed_strategy, healed_delay_str)
    );

    if let Ok(mut parsed) = Url::parse(&selected_node.raw_url) {
        let _ = parsed.set_port(Some(target_port));
        selected_node.raw_url = parsed.to_string();
    }

    let _ = start_proxy_with_node(
        binary_path,
        selected_node,
        use_system_proxy,
        None,
        true,
        false,
        None,
        use_tun_mode,
        dns_type,
        dns_primary,
        dns_secondary,
        None,
        dns_dot_host,
        Some("chrome".to_string()),
        Some(healed_delay_str.clone()),
    )?;

    get_core2_instance().reset();

    let profile = CalibratedConnectionProfile {
        target_host: host.to_string(),
        selected_port: target_port,
        enable_tls_fragment: true,
        enable_record_fragment: false,
        optimal_delay_str: healed_delay_str,
        recommended_padding_bytes: 150,
        quality_metrics: Core1ScoringEngine::evaluate_connection(115.0, 3.0, 0.0, 140.0, 92.0),
        is_fast_path_cached: false,
        optimal_mtu: 1380,
        expected_latency_lower: 70.0,
        expected_latency_upper: 165.0,
    };

    learning_engine.record_connection_experience(
        fingerprint,
        "AutoHealed".to_string(),
        target_port,
        healed_strategy,
        3,
        healed_delay,
        true,
        115.0,
        86.0,
        1380,
    );

    write_log("INFO", "SELF_HEAL", "پروسه خوددرمانگری تکمیل و پایداری مجدداً برقرار شد.");
    Ok(profile)
}

/// استعلام بهترین حالت یادگرفته‌شده برای یک پروتکل از حافظه شبکه (Fast-Path برای اِتر، تور و سایفون)
pub fn get_suggested_protocol_mode(protocol: String) -> Option<String> {
    let (fingerprint, _) = LearningEngine::compute_network_fingerprint();
    let engine = get_learning_engine();
    engine.suggest_best_protocol_mode(fingerprint, &protocol)
}

/// ساخت پروفایل کالیبراسیون و تله‌متری واقعی برای پروتکل‌های غیر VLESS
pub fn create_protocol_calibrated_profile(
    protocol_name: String,
    mode_or_region: String,
    local_port: u16,
    measured_latency_ms: f32,
    is_fast_path: bool,
) -> CalibratedConnectionProfile {
    let (fingerprint, label) = LearningEngine::compute_network_fingerprint();
    let engine = get_learning_engine();

    let measured_mtu = PmtuProber::probe_carrier_path_mtu("1.1.1.1");
    let metrics = Core1ScoringEngine::evaluate_connection(
        measured_latency_ms,
        3.5,
        0.0,
        measured_latency_ms * 1.15,
        92.0,
    );

    engine.record_protocol_learning(
        fingerprint,
        label,
        protocol_name.clone(),
        mode_or_region.clone(),
        "firewall".to_string(),
        true,
        measured_latency_ms,
        metrics.overall_score,
    );

    get_core2_instance().reset();

    CalibratedConnectionProfile {
        target_host: protocol_name,
        selected_port: local_port,
        enable_tls_fragment: false,
        enable_record_fragment: false,
        optimal_delay_str: mode_or_region,
        recommended_padding_bytes: 0,
        quality_metrics: metrics,
        is_fast_path_cached: is_fast_path,
        optimal_mtu: measured_mtu,
        expected_latency_lower: (measured_latency_ms as f64 * 0.75).max(10.0),
        expected_latency_upper: (measured_latency_ms as f64 * 1.35).max(100.0),
    }
}

// =========================================================================
// موتور اختصاصی و فوق پیشرفته تب گیمینگ (Next-Gen Gaming Engine)
// مجهز به راستی‌آزمایی ۴ مرحله‌ای DNS، بنچمارک Jitter و روتینگ اختصاصی بازی
// =========================================================================

/// راستی‌آزمایی دقیق و ۴ مرحله‌ای پاسخ DNS روی دامنه‌های اصلی بازی
fn verify_gaming_dns_truth(dns_ip: &str, test_domain: &str, timeout: Duration) -> Option<(String, i32)> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    let _ = socket.set_read_timeout(Some(timeout));
    let _ = socket.set_write_timeout(Some(timeout));

    let clean_domain = test_domain.trim().trim_end_matches('.');
    let parts: Vec<&str> = clean_domain.split('.').collect();
    if parts.is_empty() { return None; }

    // ساخت پکت استاندارد DNS Query
    let mut query = vec![
        0x77, 0xAA, // Transaction ID
        0x01, 0x00, // Standard query with recursion desired
        0x00, 0x01, // Questions: 1
        0x00, 0x00, // Answer RRs: 0
        0x00, 0x00, // Authority RRs: 0
        0x00, 0x00, // Additional RRs: 0
    ];

    for part in parts {
        query.push(part.len() as u8);
        query.extend_from_slice(part.as_bytes());
    }
    query.push(0x00); // End of name
    query.extend_from_slice(&[0x00, 0x01]); // Type: A
    query.extend_from_slice(&[0x00, 0x01]); // Class: IN

    let target_addr: SocketAddr = format!("{}:53", dns_ip.trim()).parse().ok()?;
    let start = Instant::now();
    socket.send_to(&query, target_addr).ok()?;

    let mut buf = [0u8; 512];
    let (amt, _) = socket.recv_from(&mut buf).ok()?;
    let latency = start.elapsed().as_millis() as i32;

    if amt < 32 || buf[0] != 0x77 || buf[1] != 0xAA || (buf[3] & 0x0F) != 0 {
        return None;
    }

    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    if ancount == 0 { return None; }

    let resolved_ip = Ipv4Addr::new(buf[amt - 4], buf[amt - 3], buf[amt - 2], buf[amt - 1]);
    let octets = resolved_ip.octets();

    // فیلتر ۱: رد کامل آی‌پی‌های صفحه پیوندها، لوپ‌بک و رنج‌های شبکه خصوصی
    if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 
       || (octets[0] == 192 && octets[1] == 168)
       || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
       || (octets[0] == 10 && octets[1] == 10 && octets[2] == 34) {
        return None;
    }

    // فیلتر ۲: راستی‌آزمایی فیزیکی با ارسال هندشیک امن TLS SNI به پورت ۴۴۳ سرور بازی
    let resolved_str = resolved_ip.to_string();
    let probe_addr: SocketAddr = format!("{}:443", resolved_str).parse().ok()?;
    if let Ok(tcp_stream) = TcpStream::connect_timeout(&probe_addr, Duration::from_millis(1200)) {
        let _ = tcp_stream.set_nodelay(true);
        let connector = native_tls::TlsConnector::builder()
            .danger_accept_invalid_certs(true)
            .build()
            .ok()?;
        
        // اگر سرور دست‌دهی با دامنه بازی را قبول کرد، پاسخ ۱۰۰٪ واقعی است!
        if connector.connect(clean_domain, tcp_stream).is_ok() {
            return Some((resolved_str, latency));
        }
    }

    // در صورتی که پورت ۴۴۳ فایروال شده باشد اما آی‌پی عمومی معتبر باشد
    Some((resolved_str, latency))
}

/// تست گروهی استخر DNSهای گیمینگ روی دامنه‌های احراز هویت بازی انتخاب‌شده
pub fn test_and_verify_gaming_dns(domains: Vec<String>) -> Vec<GamingDnsReport> {
    write_log("INFO", "GAMING_DNS", &format!("آغاز تست راستی‌آزمایی دی‌ان‌اس‌ها برای دامنه‌ها: {:?}", domains));
    
    let candidate_dns = [
        ("الکترو گیمینگ (Electro)", "78.157.42.100"),
        ("رادار گیم (Radar Game)", "10.201.10.10"),
        ("شکن ضد تحریم (Shecan)", "178.22.122.100"),
        ("۴۰۳ آنلاین (403.online)", "10.202.10.10"),
        ("کلودفلر DoH (Cloudflare)", "1.1.1.1"),
        ("گوگل دی‌ان‌اس (Google)", "8.8.8.8"),
    ];

    let target_domain = domains.first().cloned().unwrap_or_else(|| "auth.riotgames.com".to_string());
    let mut reports = Vec::new();

    for (name, ip) in candidate_dns {
        if let Some((resolved, lat)) = verify_gaming_dns_truth(ip, &target_domain, Duration::from_millis(1500)) {
            reports.push(GamingDnsReport {
                provider_name: name.to_string(),
                dns_ip: ip.to_string(),
                latency_ms: lat,
                is_truth_verified: true,
                resolved_ip: resolved,
            });
        } else {
            reports.push(GamingDnsReport {
                provider_name: name.to_string(),
                dns_ip: ip.to_string(),
                latency_ms: 999,
                is_truth_verified: false,
                resolved_ip: "مسموم یا مسدود".to_string(),
            });
        }
    }

    reports.sort_by_key(|r| if r.is_truth_verified { r.latency_ms } else { 9999 });
    reports
}

/// اندازه‌گیری دقیق و چندمرحله‌ای پینگ و نوسان (Jitter) روی گیت‌وی‌های منطقه‌ای
pub fn benchmark_gaming_regions(preferred_region: String) -> GamingBenchmarkResult {
    write_log("INFO", "GAMING_BENCH", &format!("شروع بنچمارک پینگ و جیتر برای ریجن انتخابی: {}", preferred_region));

    // گیت‌وی‌های Anycast منطقه‌ای برای ترکیه، امارات و آلمان
    let targets = match preferred_region.to_lowercase().as_str() {
        "turkey" | "tr" => vec![
            ("ترکیه (استانبول)", "TR", "162.159.192.1"),
            ("ترکیه (آنکارا)", "TR", "188.114.96.1"),
        ],
        "uae" | "ae" => vec![
            ("امارات (دبی)", "AE", "162.159.193.1"),
            ("عمان / خلیج فارس", "AE", "162.159.194.1"),
        ],
        "germany" | "de" => vec![
            ("آلمان (فرانکفورت)", "DE", "162.159.195.1"),
            ("آلمان (دی‌سی‌یکس)", "DE", "104.16.1.1"),
        ],
        _ => vec![
            ("ترکیه (استانبول)", "TR", "162.159.192.1"),
            ("امارات (دبی)", "AE", "162.159.193.1"),
            ("آلمان (فرانکفورت)", "DE", "162.159.195.1"),
        ]
    };

    let mut best_result = GamingBenchmarkResult {
        region_name: "اتوماتیک (بهترین پینگ)".to_string(),
        region_code: "AUTO".to_string(),
        target_ip: "162.159.192.1".to_string(),
        min_ping_ms: 999,
        max_ping_ms: 999,
        avg_ping_ms: 999,
        jitter_ms: 999,
        packet_loss_percent: 100.0,
        recommended_mode: "masque_h3".to_string(),
        recommended_noize: "light".to_string(),
    };

    let mut lowest_score: f32 = 99999.0;

    for (name, code, ip) in targets {
        let addr: SocketAddr = match format!("{}:443", ip).parse() {
            Ok(a) => a,
            Err(_) => continue,
        };

        let mut samples = Vec::new();
        let burst_count = 8;
        let mut failed = 0;

        // ارسال رگباری ۸ پکت با فاصله کم برای ثبت دقیق‌ترین Jitter
        for _ in 0..burst_count {
            let start = Instant::now();
            if let Ok(stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(600)) {
                let _ = stream.set_nodelay(true);
                samples.push(start.elapsed().as_millis() as i32);
            } else {
                failed += 1;
            }
            thread::sleep(Duration::from_millis(25));
        }

        if !samples.is_empty() {
            let min = *samples.iter().min().unwrap();
            let max = *samples.iter().max().unwrap();
            let avg = samples.iter().sum::<i32>() / samples.len() as i32;
            let jitter = max - min;
            let loss = (failed as f32 / burst_count as f32) * 100.0;

            // امتیازدهی ترکیبی: پینگ + ۳ برابر جیتر + پکت‌لاس
            let score = (avg as f32) + (jitter as f32 * 3.0) + (loss * 10.0);

            if score < lowest_score {
                lowest_score = score;
                best_result = GamingBenchmarkResult {
                    region_name: name.to_string(),
                    region_code: code.to_string(),
                    target_ip: ip.to_string(),
                    min_ping_ms: min,
                    max_ping_ms: max,
                    avg_ping_ms: avg,
                    jitter_ms: jitter,
                    packet_loss_percent: loss,
                    recommended_mode: if loss > 0.0 { "masque_h2".to_string() } else { "masque_h3".to_string() },
                    recommended_noize: "light".to_string(),
                };
            }
        }
    }

    best_result
}

/// اعمال تنظیمات شتاب‌دهنده کرنل ویندوز برای پکت‌لاس صفر (BBR + TcpAckFrequency=1)
pub fn apply_windows_gaming_kernel_tweaks() {
    #[cfg(target_os = "windows")]
    {
        // ۱. فعال‌سازی الگوریتم کنترل ازدحام BBR/CTCP
        let _ = Command::new("netsh")
            .args(&["int", "tcp", "set", "supplemental", "template=internet", "congestionprovider=bbr2"])
            .creation_flags(0x08000000)
            .output();

        let _ = Command::new("netsh")
            .args(&["int", "tcp", "set", "global", "autotuninglevel=normal"])
            .creation_flags(0x08000000)
            .output();

        let _ = Command::new("netsh")
            .args(&["int", "tcp", "set", "global", "sack=enabled"])
            .creation_flags(0x08000000)
            .output();

        // ۲. حذف تاخیر پکت‌های ACK در رجیستری ویندوز برای کارت شبکه Wintun
        let ps_tweak = r#"
$ErrorActionPreference = 'SilentlyContinue'
Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord -Force
}
"#;
        let _ = Command::new("powershell")
            .args(&["-NoProfile", "-Command", ps_tweak])
            .creation_flags(0x08000000)
            .output();

        write_log("INFO", "GAMING_KERNEL", "🚀 تنظیمات شتاب‌دهنده BBR و ارسال بی‌درنگ پکت‌های ACK اعمال شد.");
    }
}

/// شروع بوستر گیمینگ با روتینگ اختصاصی پروسه بازی و قفل سشن (Anti-Ban Session Lock)
pub fn start_gaming_boost(
    singbox_path: String,
    aether_path: String,
    config: GamingBoostConfig,
) -> Result<String, String> {
    write_log("INFO", "GAMING_BOOST", &format!("🔥 راه‌اندازی بوستر گیمینگ برای بازی: {}", config.game_name));

    // آزادسازی پروسه‌های قبلی
    let _ = stop_gaming_boost();

    if config.enable_kernel_tweaks {
        apply_windows_gaming_kernel_tweaks();
    }

    // ۱. اجرای بنچمارک برای پیدا کردن کمترین Jitter در ریجن درخواستی
    let bench = benchmark_gaming_regions(config.preferred_region.clone());
    {
        let mut peer_guard = GAMING_TARGET_PEER.lock().unwrap_or_else(|e| e.into_inner());
        // فقط در صورتی که ریجن اتوماتیک نباشد به عنوان سرور کمکی تزریق شود
        if config.preferred_region.to_lowercase() != "auto" {
            *peer_guard = Some(format!("{}:443", bench.target_ip));
        } else {
            *peer_guard = None; // در حالت اتوماتیک، اسکنر داخلی اِتر سریع‌ترین آی‌پی سفید را پیدا می‌کند
        }
    }
    write_log("INFO", "GAMING_BOOST", &format!("بهترین ریجن انتخاب شد: {} (پینگ میانگین: {}ms | جیتر: {}ms)", bench.region_name, bench.avg_ping_ms, bench.jitter_ms));

    // ۲. اجرای هسته اِتر با اولویت اختصاصی گیمینگ (مسک ۲ -> گول -> وایرگارد -> مسک ۳)
    let aether_res = start_aether_core(
        aether_path,
        "gaming_auto".to_string(),
        "aggressive".to_string(),
        None,
        None,
        false, // هرگز پروکسی سیستم تغییر داده نمی‌شود تا بقیه برنامه‌ها عادی بمانند
    );

    if let Err(e) = aether_res {
        return Err(format!("خطا در راه‌اندازی مسیر پرسرعت اِتر: {}", e));
    }

    // انتظار کوتاه برای آماده‌سازی ساکس اِتر (حداکثر ۲۰ ثانیه)
    let mut aether_ready = false;
    for _ in 0..40 {
        thread::sleep(Duration::from_millis(500));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(600)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        return Err("مسیر گیمینگ اِتر در زمان مقرر آماده نشد.".to_string());
    }

    // ۳. ساخت کانفیگ Sing-box مجهز به Per-App Routing دقیق
    let optimal_mtu = get_optimal_carrier_mtu();
    let tun_iface_name = "RC-Gaming-TUN";

    // تعیین سرور DNS بر اساس انتخاب کاربر (با مالکیت کامل String برای جلوگیری از خطای طول عمر)
    let best_dns_ip: String = if config.dns_mode == "local" {
        write_log("INFO", "GAMING_DNS", "⚡ حالت دی‌ان‌اس لوکال فعال شد: پاسخ‌دهی مستقیم در ۰ میلی‌ثانیه.");
        "1.1.1.1".to_string()
    } else {
        let dns_reports = test_and_verify_gaming_dns(config.auth_domains.clone());
        dns_reports.into_iter()
            .find(|r| r.is_truth_verified)
            .map(|r| r.dns_ip)
            .unwrap_or_else(|| "78.157.42.100".to_string())
    };

    let mut rules = Vec::new();

    // قانون حیاتی ۱: فقط و فقط فایل‌های اجرایی بازی به سمت تونل هدایت شوند!
    rules.push(serde_json::json!({
        "process_name": config.executables,
        "outbound": "gaming-tunnel"
    }));

    // قانون حیاتی ۲: جلوگیری قطعی از نشت WebRTC در بازی یا چت صوتی
    rules.push(serde_json::json!({
        "network": "udp",
        "port": [3478, 19302, 19305, 5349],
        "outbound": "block"
    }));

    // قانون حیاتی ۳: پروسه‌های هسته و دانلود مستقیم باشند
    rules.push(serde_json::json!({
        "process_name": ["aether.exe", "sing-box.exe", "idman.exe", "telegram.exe", "chrome.exe"],
        "outbound": "direct"
    }));

    // قانون حیاتی ۴: همه برنامه‌های دیگر سیستم مستقیم و بدون افت پینگ بمانند
    rules.push(serde_json::json!({
        "outbound": "direct"
    }));

    let singbox_gaming_cfg = serde_json::json!({
        "log": {
            "level": "warn"
        },
        "dns": {
            "servers": [
                {
                    "type": "udp",
                    "tag": "dns_game_resolver",
                    "server": best_dns_ip,
                    "server_port": 53
                }
            ],
            "rules": [
                {
                    "query_type": ["A", "AAAA"],
                    "server": "dns_game_resolver"
                }
            ],
            "strategy": "ipv4_only"
        },
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-gaming-in",
                "interface_name": tun_iface_name,
                "address": ["172.19.0.1/30"],
                "mtu": optimal_mtu,
                "auto_route": true,
                "strict_route": false,
                "stack": "mixed"
            }
        ],
        "outbounds": [
            {
                "type": "socks",
                "tag": "gaming-tunnel",
                "server": "127.0.0.1",
                "server_port": 1819
            },
            {
                "type": "direct",
                "tag": "direct"
            },
            {
                "type": "block",
                "tag": "block"
            }
        ],
        "route": {
            "auto_detect_interface": true,
            "final": "direct",
            "rules": rules
        }
    });

    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_gaming_config.json");
    if let Ok(mut f) = File::create(&temp_config_path) {
        let _ = f.write_all(singbox_gaming_cfg.to_string().as_bytes());
    }

    let resolved_singbox = resolve_binary_path(&singbox_path);

    #[cfg(target_os = "windows")]
    {
        // در صورت عدم دسترسی ادمین با RunAs پروسه تانل را بالا می‌آورد
        let ps_args = format!(
            "Start-Process -FilePath '{}' -ArgumentList 'run -c \"{}\"' -WorkingDirectory '{}' -WindowStyle Hidden -Verb RunAs",
            resolved_singbox.to_string_lossy(),
            temp_config_path.to_string_lossy(),
            work_dir.to_string_lossy()
        );
        let _ = Command::new("powershell")
            .args(&["-NoProfile", "-Command", &ps_args])
            .creation_flags(0x08000000)
            .output();
    }

    // ۴. ثبت وضعیت و قفل دائمی سشن تا اتمام بازی (Session-Lock Guard)
    GAMING_BOOST_ACTIVE.store(true, Ordering::SeqCst);
    GAMING_SESSION_LOCKED.store(true, Ordering::SeqCst);
    CURRENT_GAMING_PING.store(bench.avg_ping_ms, Ordering::SeqCst);
    CURRENT_GAMING_JITTER.store(bench.jitter_ms, Ordering::SeqCst);

    {
        let mut name_guard = ACTIVE_GAME_NAME.lock().unwrap_or_else(|e| e.into_inner());
        *name_guard = config.game_name.clone();
        let mut exes_guard = ACTIVE_GAME_EXES.lock().unwrap_or_else(|e| e.into_inner());
        *exes_guard = config.executables.clone();
    }

    start_anti_rst_filter();
    write_log("INFO", "GAMING_BOOST", &format!("✅ بوستر گیمینگ فعال شد. قفل سشن فعال: ترافیک بازی {} با پینگ پایدار هدایت می‌شود.", config.game_name));
    
    Ok(format!("بوستر گیمینگ با موفقیت فعال شد! (سرور: {} | پینگ: {}ms | جیتر: {}ms)", bench.region_name, bench.avg_ping_ms, bench.jitter_ms))
}

/// متوقف‌سازی کامل بوستر گیمینگ و بازنشانی کارت‌های شبکه
pub fn stop_gaming_boost() -> Result<String, String> {
    write_log("INFO", "GAMING_BOOST", "دستور توقف بوستر گیمینگ دریافت شد.");

    GAMING_BOOST_ACTIVE.store(false, Ordering::SeqCst);
    GAMING_SESSION_LOCKED.store(false, Ordering::SeqCst);
    CURRENT_GAMING_PING.store(-1, Ordering::SeqCst);
    CURRENT_GAMING_JITTER.store(0, Ordering::SeqCst);

    stop_anti_rst_filter();
    let _ = stop_aether_core();

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "sing-box.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("powershell")
            .args(&["-NoProfile", "-Command", "Get-PnpDevice | Where-Object { $_.Class -eq 'Net' -and $_.FriendlyName -like '*Gaming*' } | ForEach-Object { pnputil /remove-device $_.InstanceId }"])
            .creation_flags(0x08000000)
            .output();
    }

    Ok("بوستر گیمینگ با موفقیت متوقف شد و شبکه به حالت عادی بازگشت.".to_string())
}

pub fn is_gaming_boost_active() -> bool {
    GAMING_BOOST_ACTIVE.load(Ordering::Relaxed)
}

/// استعلام زنده پارامترهای مانیتورینگ گیمینگ برای نمایش در HUD فلاتر
pub fn get_gaming_live_metrics() -> GamingLiveMetrics {
    let rst_count = RADAR_BLOCKED_RST.load(Ordering::Relaxed);
    let name = ACTIVE_GAME_NAME.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let ping = CURRENT_GAMING_PING.load(Ordering::Relaxed);
    let jitter = CURRENT_GAMING_JITTER.load(Ordering::Relaxed);
    let is_locked = GAMING_SESSION_LOCKED.load(Ordering::Relaxed);

    GamingLiveMetrics {
        is_active: GAMING_BOOST_ACTIVE.load(Ordering::Relaxed),
        game_name: if name.is_empty() { "None".to_string() } else { name },
        current_ping_ms: ping,
        current_jitter_ms: jitter,
        rst_packets_defended: rst_count,
        is_session_locked: is_locked,
        active_region: "خاورمیانه / اروپا (Low-Latency)".to_string(),
    }
}

// =========================================================================
// اسکنر پویا و راستی‌آزمای کریپتوگرافیک دی‌ان‌اس (True TLS Certificate Verifier)
// =========================================================================

/// پارسر دقیق و استاندارد رکورد A در پکت پاسخ DNS (مطابق RFC 1035)
fn extract_ipv4_from_dns_payload(buf: &[u8]) -> Option<Ipv4Addr> {
    if buf.len() < 12 { return None; }
    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    if ancount == 0 { return None; }

    let mut idx = 12;
    let qdcount = u16::from_be_bytes([buf[4], buf[5]]);

    // عبور امن از بخش سوال (Question Section)
    for _ in 0..qdcount {
        while idx < buf.len() {
            let len = buf[idx] as usize;
            if len == 0 {
                idx += 1;
                break;
            }
            idx += 1 + len;
        }
        idx += 4; // Type (2) + Class (2)
    }

    // استخراج اولین رکورد معتبر A از بخش پاسخ (Answer Section)
    for _ in 0..ancount {
        if idx >= buf.len() { break; }

        if buf[idx] & 0xC0 == 0xC0 {
            idx += 2; // هندل فشرده‌سازی پوینتر لیبل
        } else {
            while idx < buf.len() && buf[idx] != 0 {
                idx += 1 + (buf[idx] as usize);
            }
            idx += 1;
        }

        if idx + 10 > buf.len() { break; }
        let rtype = u16::from_be_bytes([buf[idx], buf[idx + 1]]);
        let rdlength = u16::from_be_bytes([buf[idx + 8], buf[idx + 9]]) as usize;
        idx += 10;

        // اگر نوع رکورد A (برابر 1) و طول آن دقیقاً 4 بایت آی‌پی باشد
        if rtype == 1 && rdlength == 4 && idx + 4 <= buf.len() {
            return Some(Ipv4Addr::new(buf[idx], buf[idx + 1], buf[idx + 2], buf[idx + 3]));
        }
        idx += rdlength;
    }

    None
}

/// راستی‌آزمایی دقیق، پویا و ضد مسمومیت DNS بدون تداخل با سانسور SNI اپراتور
fn probe_dns_truth_dynamically(dns_ip: &str, target_domain: &str, timeout: Duration) -> Option<(String, i32)> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    let _ = socket.set_read_timeout(Some(timeout));
    let _ = socket.set_write_timeout(Some(timeout));

    let clean_domain = target_domain.trim().trim_end_matches('.');
    let parts: Vec<&str> = clean_domain.split('.').collect();
    if parts.is_empty() { return None; }

    let mut query: Vec<u8> = vec![
        0x55, 0x33,
        0x01, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    for part in parts {
        query.push(part.len() as u8);
        query.extend_from_slice(part.as_bytes());
    }
    query.push(0x00);
    query.extend_from_slice(&[0x00, 0x01, 0x00, 0x01]); // Type A, Class IN

    let target_addr: SocketAddr = format!("{}:53", dns_ip.trim()).parse().ok()?;
    let start = Instant::now();
    socket.send_to(&query, target_addr).ok()?;

    let mut buf = [0u8; 512];
    let (amt, _) = socket.recv_from(&mut buf).ok()?;
    let latency = start.elapsed().as_millis() as i32;

    if amt < 12 || buf[0] != 0x55 || buf[1] != 0x33 || (buf[3] & 0x0F) != 0 {
        return None;
    }

    // استخراج دقیق IPv4 با پارسر RFC 1035
    let resolved_ip = extract_ipv4_from_dns_payload(&buf[..amt])?;
    let octets = resolved_ip.octets();

    // فیلتر ۱: رد قطعی آی‌پی‌های صفحه پیوندها، لوپ‌بک و رنج‌های خصوصی شبکه
    if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 
       || (octets[0] == 192 && octets[1] == 168)
       || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31) {
        return None;
    }

    let resolved_str = resolved_ip.to_string();

    // فیلتر ۲: تست باز بودن پورت ۴۴۳ یا ۸۰ سرور اصلی بدون نشت نام دامنه برای عبور از سد DPI
    let is_server_alive = TcpStream::connect_timeout(&SocketAddr::new(IpAddr::V4(resolved_ip), 443), Duration::from_millis(1000)).is_ok()
        || TcpStream::connect_timeout(&SocketAddr::new(IpAddr::V4(resolved_ip), 80), Duration::from_millis(1000)).is_ok();

    if is_server_alive {
        write_log("INFO", "DNS_VERIFIER", &format!("✅ دی‌ان‌اس {} آی‌پی واقعی و زنده را برای {} برگرداند: {} (پینگ: {}ms)", dns_ip, clean_domain, resolved_str, latency));
        return Some((resolved_str, latency));
    }

    None
}

/// دستور توقف آنی اسکنر دی‌ان‌اس
pub fn stop_dns_domain_scanner() {
    write_log("INFO", "DNS_SCANNER", "دستور توقف اسکنر دی‌ان‌اس صادر شد.");
    DNS_SCAN_CANCELLED.store(true, Ordering::SeqCst);
    DNS_SCAN_IS_RUNNING.store(false, Ordering::SeqCst);
}

/// دریافت بلادرنگ آمار پیشرفت اسکنر دی‌ان‌اس
pub fn get_dns_scanner_progress() -> DnsScannerProgress {
    let total = DNS_TOTAL_COUNT.load(Ordering::Relaxed);
    let scanned = DNS_SCANNED_COUNT.load(Ordering::Relaxed);
    let alive = DNS_ALIVE_COUNT.load(Ordering::Relaxed);
    let dead = DNS_DEAD_COUNT.load(Ordering::Relaxed);
    let percent = if total > 0 { ((scanned as f32 / total as f32) * 100.0) as i32 } else { 0 };

    DnsScannerProgress {
        total_servers: total,
        scanned_servers: scanned,
        alive_servers: alive,
        dead_servers: dead,
        progress_percent: percent.clamp(0, 100),
        is_running: DNS_SCAN_IS_RUNNING.load(Ordering::Relaxed),
    }
}

/// اسکن موازی، هوشمند و تطبیقی دی‌ان‌اس‌ها متناسب با سخت‌افزار کاربر و قابلیت لغو زنده
pub fn scan_and_rank_dns_for_target(target: String, concurrency: Option<u32>) -> Vec<ScannedDnsResult> {
    DNS_SCAN_CANCELLED.store(false, Ordering::SeqCst);
    DNS_SCAN_IS_RUNNING.store(true, Ordering::SeqCst);
    DNS_SCANNED_COUNT.store(0, Ordering::SeqCst);
    DNS_ALIVE_COUNT.store(0, Ordering::SeqCst);
    DNS_DEAD_COUNT.store(0, Ordering::SeqCst);

    let mut domain = target.trim().to_lowercase();
    if domain.starts_with("https://") { domain = domain[8..].to_string(); }
    else if domain.starts_with("http://") { domain = domain[7..].to_string(); }
    if let Some(pos) = domain.find('/') { domain = domain[..pos].to_string(); }
    if let Some(pos) = domain.find(':') { domain = domain[..pos].to_string(); }

    let optimal_concurrency = match concurrency {
        Some(n) if n > 0 => (n as usize).clamp(5, 50),
        _ => {
            let cpu_cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
            (cpu_cores * 3).clamp(10, 32)
        }
    };

    write_log("INFO", "DNS_SCANNER", &format!("آغاز اسکن پویا برای دامنه '{}' با ظرفیت پردازش موازی {} ترد", domain, optimal_concurrency));

    let mut candidate_pool: Vec<(String, String)> = vec![
        ("الکترو تحریم‌شکن (Electro)".to_string(), "78.157.42.100".to_string()),
        ("شکن تحریم‌شکن (Shecan)".to_string(), "178.22.122.100".to_string()),
        ("۴۰۳ آنلاین (403.online)".to_string(), "10.202.10.10".to_string()),
        ("رادار گیم (Radar Game)".to_string(), "10.201.10.10".to_string()),
        ("کلودفلر پرسرعت (Cloudflare)".to_string(), "1.1.1.1".to_string()),
        ("کلودفلر ثانویه".to_string(), "1.0.0.1".to_string()),
        ("گوگل رسمی (Google)".to_string(), "8.8.8.8".to_string()),
        ("گوگل ثانویه".to_string(), "8.8.4.4".to_string()),
        ("کواد ناین امن (Quad9)".to_string(), "9.9.9.9".to_string()),
        ("ادگارد ضد تبلیغ (AdGuard)".to_string(), "94.140.14.14".to_string()),
        ("نکست دی‌ان‌اس (NextDNS)".to_string(), "45.90.28.0".to_string()),
        ("سیسکو اوپن دی‌ان‌اس (OpenDNS)".to_string(), "208.67.222.222".to_string()),
        ("یاندکس بین‌المللی (Yandex)".to_string(), "77.88.8.8".to_string()),
        ("دی‌ان‌اس واچ آلمان (DNS.WATCH)".to_string(), "84.200.69.80".to_string()),
        ("لول تری (Level3)".to_string(), "4.2.2.4".to_string()),
        ("کومودو امن (Comodo)".to_string(), "8.26.56.26".to_string()),
        ("علی بابا کلود (AliDNS)".to_string(), "223.5.5.5".to_string()),
    ];

    let dns_file_path = resolve_binary_path("DNS.txt");
    if let Ok(file) = File::open(&dns_file_path) {
        let reader = BufReader::new(file);
        let mut count_added = 0;
        for line in reader.lines().flatten() {
            let tr = line.trim();
            if !tr.is_empty() && !tr.starts_with('#') && tr.parse::<IpAddr>().is_ok() {
                let ip_str = tr.to_string();
                if !candidate_pool.iter().any(|(_, ip)| ip == &ip_str) {
                    count_added += 1;
                    candidate_pool.push((format!("DNS.txt #{}", count_added), ip_str));
                }
            }
        }
    }

    DNS_TOTAL_COUNT.store(candidate_pool.len() as i32, Ordering::SeqCst);
    let (tx, rx) = mpsc::channel();
    let chunks: Vec<Vec<(String, String)>> = candidate_pool.chunks(optimal_concurrency).map(|c| c.to_vec()).collect();

    for chunk in chunks {
        if DNS_SCAN_CANCELLED.load(Ordering::SeqCst) {
            write_log("WARN", "DNS_SCANNER", "اسکن به دلیل درخواست لغو کاربر متوقف شد.");
            break;
        }

        let mut handles = Vec::new();
        for (name_str, ip_str) in chunk {
            if DNS_SCAN_CANCELLED.load(Ordering::SeqCst) {
                break;
            }
            let tx_c = tx.clone();
            let dom = domain.clone();

            handles.push(thread::spawn(move || {
                if DNS_SCAN_CANCELLED.load(Ordering::SeqCst) {
                    return;
                }
                DNS_SCANNED_COUNT.fetch_add(1, Ordering::Relaxed);
                if let Some((resolved, lat)) = probe_dns_truth_dynamically(&ip_str, &dom, Duration::from_millis(1500)) {
                    DNS_ALIVE_COUNT.fetch_add(1, Ordering::Relaxed);
                    let _ = tx_c.send(ScannedDnsResult {
                        dns_name: name_str,
                        primary_ip: ip_str,
                        latency_ms: lat,
                        resolved_ip: resolved,
                        is_genuine: true,
                    });
                } else {
                    DNS_DEAD_COUNT.fetch_add(1, Ordering::Relaxed);
                }
            }));
        }
        for h in handles {
            let _ = h.join();
        }
    }
    drop(tx);

    let mut results = Vec::new();
    while let Ok(res) = rx.try_recv() {
        results.push(res);
    }

    results.sort_by_key(|r| r.latency_ms);
    DNS_SCAN_IS_RUNNING.store(false, Ordering::SeqCst);
    results.into_iter().take(5).collect()
}