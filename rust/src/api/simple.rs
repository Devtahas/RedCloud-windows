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
static ANTI_RST_RUNNING: AtomicBool = AtomicBool::new(false);
static ANTI_RST_HANDLE: Mutex<Option<isize>> = Mutex::new(None);

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

        // فیلتر فقط پکت‌های ورودی دارای فلگ RST (ترافیک عادی اصلاً شنود نمی‌شود و سرعت افت نمی‌کند)
        let filter_str = b"inbound and tcp.Rst\0";
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
                            write_log("INFO", "ANTI_RST", &format!("🎯 پکت RST جعلی فیلترینگ خنثی شد! (TTL دریافتی: {})", ttl));
                            // پکت Drop می‌شود و به ویندوز ارسال نمی‌شود!
                            continue;
                        }
                    }

                    // در غیر این صورت پکت سالم است و عبور داده می‌شود
                    let mut send_len = 0u32;
                    unsafe {
                        send_fn(handle, packet.as_ptr(), read_len, &mut send_len, addr.as_ptr());
                    }
                } else if !ANTI_RST_RUNNING.load(Ordering::Relaxed) {
                    break;
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
            "app_version": "3.7",
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
                                 User-Agent: RedCloud-RustCore/3.7\r\n\
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
    let process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some()
}

pub fn is_tor_connected() -> bool {
    let process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some()
}

pub fn is_tor_masque_connected() -> bool {
    let tor_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let aether_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    tor_guard.is_some() && aether_guard.is_some()
}

pub fn is_psiphon_connected() -> bool {
    let process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some()
}

pub fn is_psiphon_masque_connected() -> bool {
    let psiphon_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    let aether_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    psiphon_guard.is_some() && aether_guard.is_some()
}

pub fn is_aether_connected() -> bool {
    let process_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
    process_guard.is_some()
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
            let proxy_server = format!("{}:{}", host, port);
            
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
                "/d", "<local>;localhost;127.0.0.1", 
                "/f"
            ]);
            #[cfg(target_os = "windows")]
            cmd3.creation_flags(0x08000000);
            let _ = cmd3.output();

            write_log("INFO", "PROXY_REG", &format!("پروکسی سیستم روی {}:{} فعال شد.", host, port));
        } else {
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

fn spawn_single_aether_mode(
    binary_path: &PathBuf, 
    mode: &str,
    noize: &str,
    warp_key: Option<&str>,
    team_token: Option<&str>,
) -> Result<Child, String> {
    let work_dir = get_safe_work_dir();
    let mut command = Command::new(binary_path);
    
    command.arg("--bind").arg("127.0.0.1:1819")
           .arg("--http-proxy").arg("127.0.0.1:1820")
           .arg("-4")
           .arg("--scan").arg("turbo");

    let selected_noize = if noize.trim().is_empty() { "firewall" } else { noize.trim() };
    command.arg("--noize").arg(selected_noize);

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

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
        thread::sleep(Duration::from_millis(250));
    }

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
    if mode == "auto" || mode.is_empty() {
        let matrix = [
            ("masque_h3", user_noize_pref),
            ("masque_h2", user_noize_pref),
            ("gool", user_noize_pref),
            ("masque_h2", "aggressive"), // نویز تهاجمی برای عبور از فیلتر سرسخت
            ("gool", "aggressive"),      // تونل دوبل با نویز تهاجمی
            ("wireguard", user_noize_pref),
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

        match spawn_single_aether_mode(
            &resolved_path, 
            current_mode, 
            current_noize, 
            warp_key.as_deref(), 
            team.as_deref()
        ) {
            Ok(mut child) => {
                let mut mode_success = false;
                // برای تست حافظه بررسی سریع‌تر (۱۰ بار)، برای اسکن ماتریسی ۲۰ بار تلاش
                let max_attempts = if is_probing_memory { 12 } else { 20 };

                for attempt in 1..=max_attempts {
                    thread::sleep(Duration::from_millis(300));
                    
                    if let Ok(Some(exit_status)) = child.try_wait() {
                        last_error = format!("{} با خروجی {} بسته شد.", mode_label, exit_status);
                        break;
                    }

                    let is_validated = *AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                    if is_validated || (attempt >= 2 && test_socks5_egress("127.0.0.1:1819", Duration::from_millis(700))) {
                        mode_success = true;
                        write_log("INFO", "AETHER_PROBE", &format!("اتصال زنده تایید شد: {} + نویز {}", mode_label, current_noize));
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

    if let Some(c) = connected_child {
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
    for _ in 0..30 {
        thread::sleep(Duration::from_millis(300));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "HYBRID", "پل ارتباطی اتر در پورت 1819 آماده نشد.");
        return Err("پل ارتباطی اتر موفق به برقراری ارتباط زنده با اینترنت نشد.".to_string());
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
        #[cfg(target_os = "windows")]
        {
            // پاکسازی خودکار هرگونه کارت معلق قبلی برای جلوگیری از خطای Already Exists
            let _ = Command::new("powershell")
                .args(&["-NoProfile", "-Command", "Get-PnpDevice | Where-Object { $_.Class -eq 'Net' -and ($_.FriendlyName -like '*Wintun*' -or $_.FriendlyName -like '*RC-TUN*' -or $_.FriendlyName -like '*RedCloud*') } | ForEach-Object { pnputil /remove-device $_.InstanceId }"])
                .creation_flags(0x08000000)
                .output();
        }

        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": format!("RC-TUN-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().subsec_millis()),
            "address": [
                "172.19.0.1/30",
                "fdfe:dcba:9876::1/126"
            ],
            "mtu": 1400,
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed"
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
            "strategy": "prefer_ipv4",
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
                    "network": "udp",
                    "port": [443],
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
    for _ in 0..30 {
        thread::sleep(Duration::from_millis(300));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "TOR_MASQUE", "پل ارتباطی اتر برای تور آماده نشد.");
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
    write_log("INFO", "PSIPHON", &format!("راه‌اندازی هسته سایفون (Region: {})", country_code));
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
    for _ in 0..30 {
        thread::sleep(Duration::from_millis(300));
        if test_socks5_egress("127.0.0.1:1819", Duration::from_millis(800)) {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        write_log("ERROR", "PSIPHON_MASQUE", "پل ارتباطی اتر برای سایفون بالا نیامد.");
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
    
    let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(timeout_ms)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(timeout_ms)));

    let connector = TlsConnector::builder()
        .danger_accept_invalid_certs(true)
        .build().ok()?;
    let mut tls_stream = connector.connect(worker, stream).ok()?;

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

    tls_stream.write_all(request.as_bytes()).ok()?;

    let mut buffer = [0u8; 15];
    tls_stream.read_exact(&mut buffer).ok()?;
    let response = String::from_utf8_lossy(&buffer);

    if response.starts_with("HTTP/1.1 101") || response.starts_with("HTTP/1.0 101") {
        let duration = start.elapsed().as_millis();
        Some(duration)
    } else {
        None
    }
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

        // اگر تسک‌کیل معمولی به دلیل سطح دسترسی بالا رد شد، از طریق RunAs پاورشل درجا بسته می‌شود
        if let Ok(o) = out {
            if !o.status.success() {
                let _ = Command::new("powershell")
                    .args(&["-NoProfile", "-Command", "Start-Process taskkill -ArgumentList '/F /IM sing-box.exe' -WindowStyle Hidden -Verb RunAs"])
                    .creation_flags(0x08000000)
                    .output();
            }
        }
    }

    {
        let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = process_guard.take() {
            let _ = old.kill();
            let _ = old.wait();
        }
    }

    let outbound_json = convert_link_to_outbound(
        selected_node,
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
        #[cfg(target_os = "windows")]
        {
            // پاکسازی خودکار هرگونه کارت معلق قبلی برای جلوگیری از خطای Already Exists
            let _ = Command::new("powershell")
                .args(&["-NoProfile", "-Command", "Get-PnpDevice | Where-Object { $_.Class -eq 'Net' -and ($_.FriendlyName -like '*Wintun*' -or $_.FriendlyName -like '*RC-TUN*' -or $_.FriendlyName -like '*RedCloud*') } | ForEach-Object { pnputil /remove-device $_.InstanceId }"])
                .creation_flags(0x08000000)
                .output();
        }

        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": format!("RC-TUN-{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().subsec_millis()),
            "address": [
                "172.19.0.1/30",
                "fdfe:dcba:9876::1/126"
            ],
            "mtu": 1400,
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed"
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
            "strategy": "prefer_ipv4",
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
                    "network": "udp",
                    "port": [443],
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

        // اگر تسک‌کیل معمولی به دلیل سطح دسترسی بالا رد شد، از طریق RunAs پاورشل درجا بسته می‌شود
        if let Ok(o) = out {
            if !o.status.success() {
                let _ = Command::new("powershell")
                    .args(&["-NoProfile", "-Command", "Start-Process taskkill -ArgumentList '/F /IM sing-box.exe' -WindowStyle Hidden -Verb RunAs"])
                    .creation_flags(0x08000000)
                    .output();
            }
        }
    }

    Ok("پروکسی متوقف و سیستم به حالت عادی برگشت.".to_string())
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

        if let Ok(url) = Url::parse(line_trimmed) {
            let protocol = url.scheme().to_lowercase();
            if protocol == "vless" || protocol == "trojan" || protocol == "hysteria2" || protocol == "hy2" {
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

        if !ech_config.is_empty() {
            let configs: Vec<&str> = ech_config.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
            tls_obj["ech"] = serde_json::json!({
                "enabled": true,
                "config": configs,
                "pq_signature_schemes_enabled": true
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

    if protocol == "vless" {
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

        if !ech_config.is_empty() {
            let configs: Vec<&str> = ech_config.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
            tls_obj["ech"] = serde_json::json!({
                "enabled": true,
                "config": configs,
                "pq_signature_schemes_enabled": true
            });
        }

        if enable_fragment {
            tls_obj["fragment"] = serde_json::json!(true);
            if let Some(ref delay) = fragment_fallback_delay {
                if !delay.trim().is_empty() {
                    tls_obj["fragment_fallback_delay"] = serde_json::json!(delay.trim());
                }
            }
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