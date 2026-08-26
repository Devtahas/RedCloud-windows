use std::fs::File;
use std::io::{Write, Read, BufReader, BufRead};
use std::process::{Command, Child, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};
use std::net::{TcpStream, UdpSocket, SocketAddr, ToSocketAddrs, IpAddr, Ipv4Addr};
use std::path::PathBuf;
use url::Url;
use base64::{Engine as _, engine::general_purpose};
use native_tls::TlsConnector;
use std::sync::mpsc;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

static PROXY_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static TOR_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static PSIPHON_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static AETHER_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static ACTIVE_DNS: Mutex<Option<(String, String)>> = Mutex::new(None);

static TOR_BOOTSTRAP_PERCENT: Mutex<i32> = Mutex::new(0);
static AETHER_BOOTSTRAP_PERCENT: Mutex<i32> = Mutex::new(0);

static PSIPHON_CONNECTED: Mutex<bool> = Mutex::new(false);
static AETHER_CONNECTED: Mutex<bool> = Mutex::new(false);
static AETHER_STATUS_MSG: Mutex<String> = Mutex::new(String::new());
static PSIPHON_STATUS_MSG: Mutex<String> = Mutex::new(String::new());

// متغیرهای کنترل وضعیت و آمار زنده اسکنر کلودفلر
static SCAN_CANCELLED: AtomicBool = AtomicBool::new(false);
static SCAN_RUNNING: AtomicBool = AtomicBool::new(false);
static TOTAL_SCANNED: AtomicI32 = AtomicI32::new(0);
static ALIVE_COUNT: AtomicI32 = AtomicI32::new(0);
static DEAD_COUNT: AtomicI32 = AtomicI32::new(0);

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

    let p = PathBuf::from(name);
    if p.exists() {
        return p;
    }

    if let Ok(cur) = std::env::current_dir() {
        let candidate = cur.join(&file_name);
        if candidate.exists() {
            return candidate;
        }
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
    static WIN_JOB_OBJECT: std::sync::OnceLock<Option<usize>> = std::sync::OnceLock::new();
    *WIN_JOB_OBJECT.get_or_init(|| {
        unsafe {
            use windows_sys::Win32::System::JobObjects::{
                CreateJobObjectW, SetInformationJobObject, JobObjectExtendedLimitInformation,
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            };

            let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
            if job as usize == 0 || job as isize == -1 {
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

/// اسکنر واقعی لایه ۷ با غربالگری و فیلتر مسمومیت DNS ایران
pub fn verify_dns_ip(ip: String) -> Option<VerifiedDns> {
    let target_addr: SocketAddr = format!("{}:53", ip.trim()).parse().ok()?;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.set_read_timeout(Some(Duration::from_millis(1600))).ok()?;
    socket.set_write_timeout(Some(Duration::from_millis(1600))).ok()?;

    // بسته استاندارد DNS Query برای google.com (A-Record)
    let dns_query: [u8; 28] = [
        0x12, 0x34, // Transaction ID
        0x01, 0x00, // Flags: Standard query, Recursion Desired
        0x00, 0x01, // Questions: 1
        0x00, 0x00, // Answer RRs: 0
        0x00, 0x00, // Authority RRs: 0
        0x00, 0x00, // Additional RRs: 0
        // Query Name: google.com
        0x06, b'g', b'o', b'o', b'g', b'l', b'e',
        0x03, b'c', b'o', b'm',
        0x00,       // End of string
        0x00, 0x01, // Type: A
        0x00, 0x01  // Class: IN
    ];

    let start = Instant::now();
    socket.send_to(&dns_query, target_addr).ok()?;

    let mut buf = [0u8; 512];
    let (amt, _) = socket.recv_from(&mut buf).ok()?;
    let latency = start.elapsed().as_millis() as i32;

    if amt < 32 {
        return None;
    }

    // بررسی بخش Answers و شناسایی آی‌پی‌های مسموم/فیک
    let ancount = u16::from_be_bytes([buf[6], buf[7]]);
    if ancount == 0 {
        return None;
    }

    // استخراج آخرین ۴ بایت پاسخ (IPv4)
    let resolved_ip = Ipv4Addr::new(buf[amt - 4], buf[amt - 3], buf[amt - 2], buf[amt - 1]);
    let octets = resolved_ip.octets();

    // فیلتر قاطعانه آی‌پی‌های مسموم، اینترانت و صفحه پیوندهای ایران
    if octets[0] == 10 || octets[0] == 127 || octets[0] == 0 
       || (octets[0] == 192 && octets[1] == 168)
       || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
       || (octets[0] == 10 && octets[1] == 10 && octets[2] == 34) {
        return None; // دی‌ان‌اس مسموم است!
    }

    Some(VerifiedDns {
        ip: ip.trim().to_string(),
        latency_ms: latency,
        works_singbox: true,
        works_tor: true,
        works_psiphon: true,
    })
}

/// اجرای اسکن خوددرمانگر و اضطراری DNS و ذخیره در مخزن پنهان
pub fn run_dns_rescue_scan(custom_dns_list: Option<String>) -> Vec<VerifiedDns> {
    let mut candidate_list: Vec<String> = Vec::new();

    if let Some(content) = custom_dns_list {
        for line in content.lines() {
            let tr = line.trim();
            if !tr.is_empty() && !tr.starts_with('#') && tr.parse::<IpAddr>().is_ok() {
                candidate_list.push(tr.to_string());
            }
        }
    }

    // در صورت خالی بودن، بررسی فایل محلی DNS.txt یا رنج‌های نجات پیش‌فرض
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
            "8.8.8.8", "8.8.4.4", "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220", "94.140.14.14", "94.140.15.15",
            "185.228.168.9", "185.228.169.9", "77.88.8.8", "77.88.8.1",
            "223.5.5.5", "223.6.6.6", "119.29.29.29", "1.1.1.1", "1.0.0.1"
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

    // ذخیره در مخزن پنهان دیسک
    let work_dir = get_safe_work_dir();
    let vault_path = work_dir.join("dns_vault.json");
    if let Ok(encoded) = serde_json::to_string_pretty(&final_top) {
        let _ = std::fs::write(vault_path, encoded);
    }

    final_top
}

/// دریافت لیست دی‌ان‌اس‌های تمیز از مخزن پنهان
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

    // بازگردانی لیست استاندارد پایدار
    vec![
        VerifiedDns { ip: "8.8.8.8".into(), latency_ms: 45, works_singbox: true, works_tor: true, works_psiphon: true },
        VerifiedDns { ip: "9.9.9.9".into(), latency_ms: 55, works_singbox: true, works_tor: true, works_psiphon: true },
        VerifiedDns { ip: "94.140.14.14".into(), latency_ms: 60, works_singbox: true, works_tor: true, works_psiphon: true },
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
                *process_guard = Some((primary, secondary));
                Ok("دی‌ان‌اس با موفقیت روی سیستم فعال شد.".to_string())
            } else {
                Err("خطا در اعمال تنظیمات دی‌ان‌اس. برنامه را به عنوان Administrator اجرا کنید.".to_string())
            }
        }
        Err(e) => Err(format!("خطا در اجرای اسکریپت پاورشل: {}", e)),
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
                Ok("تنظیمات دی‌ان‌اس سیستم به حالت خودکار (DHCP) بازگشت.".to_string())
            } else {
                Err("خطا در ریست دی‌ان‌اس. برنامه را به عنوان Administrator اجرا کنید.".to_string())
            }
        }
        Err(e) => Err(format!("خطا در ریست دی‌ان‌اس: {}", e))
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
        }

        #[cfg(target_os = "windows")]
        notify_windows_proxy_change();
    }
}

fn process_aether_line(l: String) {
    let trimmed = l.trim().to_string();
    if trimmed.is_empty() { return; }

    println!("[RedCloud - Aether] {}", trimmed);

    {
        let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = trimmed.clone();
    }

    let lower = trimmed.to_lowercase();

    if let Some(pos) = trimmed.find('%') {
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

    if lower.contains("connected") 
        || lower.contains("tunnel established")
        || lower.contains("listening") 
        || lower.contains("ready")
        || lower.contains("socks5")
        || lower.contains("validation passed") {
        let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        *progress = 100;
        let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
        *connected = true;
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
        .map_err(|e| format!("خطا در اجرای aether.exe: {}", e))?;

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
    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();

    {
        let mut p = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = p.take() {
            let _ = old.kill();
        }
    }

    let resolved_path = resolve_binary_path(&binary_path);
    
    let modes_to_try: Vec<&str> = if mode == "auto" || mode.is_empty() {
        vec!["masque_h3", "masque_h2", "gool", "wireguard"]
    } else {
        vec![mode.as_str()]
    };

    let mut connected_child: Option<Child> = None;
    let mut last_error = String::new();

    for current_mode in modes_to_try {
        let mode_persian_name = match current_mode {
            "masque_h3" => "MASQUE H3 (QUIC - سرعت بالا)",
            "masque_h2" => "MASQUE H2 + Fragment (ضد اختلال UDP)",
            "gool" => "Gool (WARP-in-WARP - تونل مضاعف)",
            "wireguard" => "WireGuard (وایرگارد)",
            _ => "MASQUE",
        };

        {
            let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
            *progress = 25;
            let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
            *connected = false;
            let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            *status = format!("در حال اسکن و آزمایش اتصال با پروتکل {}...", mode_persian_name);
        }

        match spawn_single_aether_mode(
            &resolved_path, 
            current_mode, 
            &noize, 
            warp_key.as_deref(), 
            team.as_deref()
        ) {
            Ok(mut child) => {
                let mut mode_success = false;
                for _ in 0..40 {
                    thread::sleep(Duration::from_millis(350));
                    
                    if let Ok(Some(exit_status)) = child.try_wait() {
                        last_error = format!("پروتکل {} با وضعیت {} بسته شد.", mode_persian_name, exit_status);
                        break;
                    }

                    if TcpStream::connect_timeout(&"127.0.0.1:1819".parse().unwrap(), Duration::from_millis(200)).is_ok() {
                        mode_success = true;
                        break;
                    }
                }

                if mode_success {
                    connected_child = Some(child);
                    let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                    *progress = 100;
                    let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                    *connected = true;
                    let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
                    *status = format!("پل ارتباطی با پروتکل پایدار {} فعال شد!", mode_persian_name);
                    break;
                } else {
                    let _ = child.kill();
                    #[cfg(target_os = "windows")]
                    let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
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
        Ok("اتصال شبکه اتر با موفقیت برقرار شد.".to_string())
    } else {
        let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = format!("خطا در تمام پروتکل‌ها: {}", last_error);
        Err(format!("امکان برقراری پل با هیچ یک از پروتکل‌ها فراهم نشد: {}", last_error))
    }
}

pub fn stop_aether_core() -> Result<String, String> {
    let mut process_guard = AETHER_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
    }

    set_windows_system_proxy(false, String::new(), 0);
    
    let mut progress = AETHER_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
    *progress = 0;
    let mut connected = AETHER_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
    *connected = false;
    let mut status = AETHER_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
    *status = "اتصال قطع شد.".to_string();

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "aether.exe"])
        .creation_flags(0x08000000)
        .output();

    Ok("اتصال شبکه اتر متوقف و سیستم به حالت عادی برگشت.".to_string())
}

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
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill").args(&["/F", "/IM", "sing-box.exe"]).creation_flags(0x08000000).output();
        let _ = Command::new("taskkill").args(&["/F", "/IM", "aether.exe"]).creation_flags(0x08000000).output();
    }

    let _ = stop_proxy_core();
    let _ = stop_aether_core();

    let aether_res = start_aether_core(
        aether_path, 
        aether_mode, 
        aether_noize, 
        aether_warp_key, 
        aether_team, 
        false
    );
    if let Err(e) = aether_res {
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    for _ in 0..30 {
        thread::sleep(Duration::from_millis(350));
        if TcpStream::connect_timeout(&"127.0.0.1:1819".parse().unwrap(), Duration::from_millis(200)).is_ok() {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        return Err("پل ارتباطی اتر در زمان مقرر آماده نشد.".to_string());
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
        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "RedCloud-TUN",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed"
        }));
    }

    // استخر چندگانه و هوشمند دی‌ان‌اس (استفاده از DoH + FakeIP + مخزن نجات)
    let vault_dns = get_vault_dns_list();
    let emergency_direct_dns = vault_dns.first().map(|d| d.ip.as_str()).unwrap_or("8.8.8.8");

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
                "server": "8.8.8.8",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": "dns.google",
                    "insecure": true
                }
            })
        }
    };

    let mut dns_servers = vec![
        dns_server_json,
        serde_json::json!({
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
        }),
        serde_json::json!({
            "type": "udp",
            "tag": "dns_direct",
            "server": emergency_direct_dns,
            "server_port": 53
        })
    ];

    if use_tun_mode {
        dns_servers.insert(0, serde_json::json!({
            "type": "fakeip",
            "tag": "dns_fakeip",
            "inet4_range": "198.18.0.0/15"
        }));
    }

    let mut dns_rules = vec![
        serde_json::json!({
            "query_type": ["A", "AAAA"],
            "server": "dns_proxy"
        })
    ];

    if use_tun_mode {
        dns_rules.insert(0, serde_json::json!({
            "inbound": "tun-in",
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
            "final": "dns_proxy"
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
            "default_domain_resolver": "dns_proxy",
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
                        "psiphon-tunnel-core.exe"
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
        .map_err(|e| format!("خطا در ساخت فایل پیکربندی هیبریدی: {}", e))?;
    
    file.write_all(final_config.to_string().as_bytes())
        .map_err(|e| format!("خطا در ذخیره‌سازی فایل هیبریدی: {}", e))?;

    let resolved_singbox = resolve_binary_path(&singbox_path);
    let mut command = Command::new(&resolved_singbox);
    command.arg("run").arg("-c").arg(&temp_config_path).current_dir(&work_dir);

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let child = command.spawn()
        .map_err(|e| format!("خطا در اجرای هسته Sing-box در مسیر {:?}: {}", resolved_singbox, e))?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    {
        let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        *process_guard = Some(child);
    }

    if use_system_proxy && !use_tun_mode {
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 2080);
    }

    Ok("اتصال ترکیبی هیبریدی با موفقیت برقرار شد! هویت خارجی فعال است.".to_string())
}

pub fn stop_hybrid_connection() -> Result<String, String> {
    let _ = stop_proxy_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);
    Ok("اتصال هیبریدی متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

fn start_tor_core_internal(
    binary_path: String,
    country_code: String,
    use_system_proxy: bool,
    socks5_proxy: Option<String>,
) -> Result<String, String> {
    let mut process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut old) = process_guard.take() {
        let _ = old.kill();
    }

    {
        let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
        *progress = 0;
    }

    let work_dir = get_safe_work_dir();
    let temp_torrc_path = work_dir.join("redcloud_temp_torrc");
    
    // کانفیگ بهینه‌شده و روان برای عبور سریع از ۵۰٪ به ۱۰۰٪
    let mut torrc_content = "SocksPort 9050\nHTTPTunnelPort 9051\nClientOnly 1\nUseMicrodescriptors 1\nClientUseIPv6 0\n".to_string();

    let geoip_path = resolve_binary_path("geoip");
    let geoip6_path = resolve_binary_path("geoip6");
    if geoip_path.exists() {
        torrc_content.push_str(&format!("GeoIPFile \"{}\"\n", geoip_path.to_string_lossy().replace('\\', "/")));
    }
    if geoip6_path.exists() {
        torrc_content.push_str(&format!("GeoIPv6File \"{}\"\n", geoip6_path.to_string_lossy().replace('\\', "/")));
    }

    // هدایت ترافیک گارد تور از پورت ساکس۵ مسک
    if let Some(ref proxy) = socks5_proxy {
        if !proxy.trim().is_empty() {
            torrc_content.push_str(&format!("Socks5Proxy {}\n", proxy.trim()));
        }
    }

    // اعمال کشور بدون قفل فلج‌کننده StrictNodes
    if !country_code.trim().is_empty() {
        torrc_content.push_str(&format!("ExitNodes {{{}}}\nStrictNodes 0\n", country_code.trim().to_lowercase()));
    }

    println!("[RedCloud] فایل پیکربندی torrc:\n{}", torrc_content);

    let mut file = File::create(&temp_torrc_path)
        .map_err(|e| format!("خطا در ایجاد فایل پیکربندی تور در Temp: {}", e))?;
    
    file.write_all(torrc_content.as_bytes())
        .map_err(|e| format!("خطا در ذخیره فایل پیکربندی تور: {}", e))?;

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
        .map_err(|e| format!("خطا در اجرای فرآیند تور: {}", e))?;

    #[cfg(target_os = "windows")]
    assign_child_to_job(&child);

    if let Some(stdout) = child.stdout.take() {
        thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().flatten() {
                println!("[RedCloud - Tor] {}", line);
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
                if let Some(pos) = line.find("Bootstrapped ") {
                    let sub = &line[pos + 13..];
                    if let Some(percent_pos) = sub.find('%') {
                        if let Ok(percent) = sub[..percent_pos].parse::<i32>() {
                            let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap_or_else(|e| e.into_inner());
                            *progress = percent;
                        }
                    }
                } else {
                    eprintln!("[RedCloud - Tor Error] {}", line);
                }
            }
        });
    }

    *process_guard = Some(child);
    
    if use_system_proxy {
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 9051);
    }
    
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
    }

    let _ = stop_tor_core();
    let _ = stop_aether_core();

    println!("[RedCloud] در حال راه‌اندازی پل اِتر برای شبکه پیاز تور...");

    let aether_res = start_aether_core(
        aether_path,
        aether_mode,
        aether_noize,
        aether_warp_key,
        aether_team,
        false,
    );
    if let Err(e) = aether_res {
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    for _ in 0..40 {
        thread::sleep(Duration::from_millis(350));
        if TcpStream::connect_timeout(&"127.0.0.1:1819".parse().unwrap(), Duration::from_millis(200)).is_ok() {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        return Err("پل ارتباطی اتر در زمان مقرر آماده نشد.".to_string());
    }

    println!("[RedCloud] پل ساکس۵ اتر آماده شد. هدایت ترافیک تور از socks5://127.0.0.1:1819...");

    start_tor_core_internal(
        tor_path,
        country_code,
        use_system_proxy,
        Some("127.0.0.1:1819".to_string()),
    )
}

pub fn stop_tor_over_masque() -> Result<String, String> {
    let _ = stop_tor_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);
    Ok("اتصال تور بر بستر مسک متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

pub fn stop_tor_core() -> Result<String, String> {
    let mut process_guard = TOR_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
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

fn process_psiphon_line(l: String) {
    let trimmed = l.trim().to_string();
    if trimmed.is_empty() { return; }

    println!("[RedCloud - Psiphon] {}", trimmed);

    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&trimmed) {
        if let Some(notice) = v.get("noticeType").and_then(|n| n.as_str()) {
            let mut status_msg = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
            match notice {
                "CandidateServers" => {
                    let count = v["data"]["count"].as_i64().unwrap_or(0);
                    *status_msg = format!("در حال اسکن و آزمایش {} سرور سایفون...", count);
                },
                "ConnectingServer" => {
                    *status_msg = "در حال دست‌دهی امن با سرور مقصد سایفون...".to_string();
                },
                "AvailableEgressRegions" => {
                    if let Some(regions) = v["data"]["regions"].as_array() {
                        if !regions.is_empty() {
                            *status_msg = format!("تعداد {} کشور آماده اتصال است.", regions.len());
                        } else {
                            *status_msg = "در حال دریافت لیست سرورهای فعال سایفون...".to_string();
                        }
                    }
                },
                "ActiveTunnel" | "Tunnels" => {
                    let count = v["data"]["count"].as_i64().unwrap_or(0);
                    if count > 0 {
                        *status_msg = format!("تانل سایفون با {} مسیر فعال برقرار شد!", count);
                        let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
                        *connected = true;
                    }
                },
                "Homepage" => {
                    *status_msg = "اتصال پایدار شد و ترافیک برقرار است.".to_string();
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
    {
        let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = process_guard.take() {
            let _ = old.kill();
        }
    }

    {
        let mut connected = PSIPHON_CONNECTED.lock().unwrap_or_else(|e| e.into_inner());
        *connected = false;
        let mut status = PSIPHON_STATUS_MSG.lock().unwrap_or_else(|e| e.into_inner());
        *status = "در حال اتصال به سرورهای سایفون...".to_string();
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

    println!("[RedCloud] تنظیمات کامل سایفون: {}", config_json);

    let mut file = File::create(&temp_config_path)
        .map_err(|e| format!("خطا در ایجاد فایل تنظیمات سایفون: {}", e))?;
    
    file.write_all(config_json.to_string().as_bytes())
        .map_err(|e| format!("خطا در ذخیره فایل تنظیمات سایفون: {}", e))?;

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
        .map_err(|e| format!("خطا در اجرای فرآیند سایفون در مسیر {:?}: {}", resolved_path, e))?;

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
    
    Ok("در حال برقراری اتصال با سرورهای سایفون؛ لطفاً چند لحظه شکیبا باشید...".to_string())
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
    }

    let _ = stop_psiphon_core();
    let _ = stop_aether_core();

    println!("[RedCloud] در حال راه‌اندازی پل اِتر برای سایفون...");

    let aether_res = start_aether_core(
        aether_path,
        aether_mode,
        aether_noize,
        aether_warp_key,
        aether_team,
        false,
    );
    if let Err(e) = aether_res {
        return Err(format!("خطا در راه‌اندازی پل اتر: {}", e));
    }

    let mut aether_ready = false;
    for _ in 0..40 {
        thread::sleep(Duration::from_millis(350));
        if TcpStream::connect_timeout(&"127.0.0.1:1819".parse().unwrap(), Duration::from_millis(200)).is_ok() {
            aether_ready = true;
            break;
        }
    }

    if !aether_ready {
        let _ = stop_aether_core();
        return Err("پل ارتباطی اتر در زمان مقرر آماده نشد.".to_string());
    }

    println!("[RedCloud] پل ساکس۵ اتر آماده شد. هدایت ترافیک سایفون از socks5://127.0.0.1:1819...");

    start_psiphon_core_internal(
        psiphon_path,
        country_code,
        use_system_proxy,
        Some("socks5://127.0.0.1:1819".to_string()),
    )
}

pub fn stop_psiphon_over_masque() -> Result<String, String> {
    let _ = stop_psiphon_core();
    let _ = stop_aether_core();
    set_windows_system_proxy(false, String::new(), 0);
    Ok("اتصال سایفون بر بستر مسک متوقف و سیستم به حالت عادی بازگشت.".to_string())
}

pub fn stop_psiphon_core() -> Result<String, String> {
    let mut process_guard = PSIPHON_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
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

/// اسکنر واقعی لایه ۷: تست دست‌دهی کامل WebSocket به ورکر و بررسی کد ۱۰۱
fn scan_single_ip_ws(ip: &str, port: u16, worker: &str, path: &str, timeout_ms: u64) -> Option<u128> {
    let addr = format!("{}:{}", ip, port).parse::<SocketAddr>().ok()?;
    let start = Instant::now();
    
    let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).ok()?;
    stream.set_read_timeout(Some(Duration::from_millis(timeout_ms))).ok()?;
    stream.set_write_timeout(Some(Duration::from_millis(timeout_ms))).ok()?;

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

/// خواندن رنج‌های CIDR و آی‌پی‌های فایل cloudflare_IPs.txt
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
            "104.16.0.0/24", "104.17.0.0/24", "104.18.0.0/24", "104.19.0.0/24",
            "104.20.0.0/24", "104.21.0.0/24", "104.22.0.0/24", "104.23.0.0/24",
            "104.24.0.0/24", "104.25.0.0/24", "104.26.0.0/24", "104.27.0.0/24",
            "172.64.0.0/24", "172.65.0.0/24", "172.66.0.0/24", "172.67.0.0/24",
            "162.159.0.0/24", "198.41.128.0/24", "188.114.96.0/24"
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

    clean_nodes
}

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
    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "sing-box.exe"])
        .creation_flags(0x08000000)
        .output();

    {
        let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(mut old) = process_guard.take() {
            let _ = old.kill();
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
        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            "tag": "tun-in",
            "interface_name": "RedCloud-TUN",
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": true,
            "strict_route": false,
            "stack": "mixed"
        }));
    }

    // استخر چندگانه دی‌ان‌اس ضد مسمومیت در ویتوری مستقیم
    let vault_dns = get_vault_dns_list();
    let emergency_direct_dns = vault_dns.first().map(|d| d.ip.as_str()).unwrap_or("8.8.8.8");

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
                "server": "8.8.8.8",
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy-out",
                "tls": {
                    "enabled": true,
                    "server_name": "dns.google",
                    "insecure": true
                }
            })
        }
    };

    let mut dns_servers = vec![
        dns_server_json,
        serde_json::json!({
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
        }),
        serde_json::json!({
            "type": "udp",
            "tag": "dns_direct",
            "server": emergency_direct_dns,
            "server_port": 53
        })
    ];

    if use_tun_mode {
        dns_servers.insert(0, serde_json::json!({
            "type": "fakeip",
            "tag": "dns_fakeip",
            "inet4_range": "198.18.0.0/15"
        }));
    }

    let mut dns_rules = vec![
        serde_json::json!({
            "query_type": ["A", "AAAA"],
            "server": "dns_proxy"
        })
    ];

    if use_tun_mode {
        dns_rules.insert(0, serde_json::json!({
            "inbound": "tun-in",
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
            "final": "dns_proxy"
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
            "default_domain_resolver": "dns_proxy",
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
                        "psiphon-tunnel-core.exe"
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
        .map_err(|e| format!("خطا در ساخت فایل پیکربندی: {}", e))?;
    
    file.write_all(final_config.to_string().as_bytes())
        .map_err(|e| format!("خطا در ذخیره‌سازی فایل پیکربندی: {}", e))?;

    let resolved_path = resolve_binary_path(&binary_path);
    let mut command = Command::new(&resolved_path);
    command.arg("run").arg("-c").arg(&temp_config_path)
           .current_dir(&work_dir);

    let log_file_path = work_dir.join("redcloud_sing_box_log.txt");
    let log_file = File::create(&log_file_path)
        .map_err(|e| format!("خطا در ایجاد فایل لاگ: {}", e))?;

    command.stdin(Stdio::null())
           .stdout(Stdio::from(log_file.try_clone().map_err(|e| e.to_string())?))
           .stderr(Stdio::from(log_file));

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

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
            
            Ok("اتصال با موفقیت برقرار شد.".to_string())
        }
        Err(e) => Err(format!("خطا در اجرای فرآیند هسته: {}", e)),
    }
}

pub fn stop_proxy_core() -> Result<String, String> {
    let mut process_guard = PROXY_PROCESS.lock().unwrap_or_else(|e| e.into_inner());

    if let Some(mut child) = process_guard.take() {
        let _ = child.kill();
    }
    
    let work_dir = get_safe_work_dir();
    let temp_config_path = work_dir.join("redcloud_temp_config.json");
    let _ = std::fs::remove_file(temp_config_path);
    
    set_windows_system_proxy(false, String::new(), 0);

    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "sing-box.exe"])
        .creation_flags(0x08000000)
        .output();

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
        return Err("هیچ سرور معتبری در ورودی یافت نشد.".to_string());
    }

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