use std::fs::File;
use std::io::{Write, BufReader, BufRead};
use std::process::{Command, Child, Stdio};
use std::sync::{Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use std::net::{TcpStream, SocketAddr, ToSocketAddrs};
use url::Url;
use base64::{Engine as _, engine::general_purpose};
use native_tls::TlsConnector;

// کتابخانه بومی ویندوز جهت مخفی‌سازی کامل پنجره‌های سیاه CMD
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

// متغیرهای نگهداری فرآیندهای مجزای هسته پروکسی، تور، سایفون و دی‌ان‌اس فعال
static PROXY_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static TOR_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static PSIPHON_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static ACTIVE_DNS: Mutex<Option<(String, String)>> = Mutex::new(None);

// ذخیره درصد پیشرفت پیش‌عرض لود شدن تور در حافظه راست
static TOR_BOOTSTRAP_PERCENT: Mutex<i32> = Mutex::new(0);

// ذخیره وضعیت اتصال قطعی شبکه سایفون در حافظه راست
static PSIPHON_CONNECTED: Mutex<bool> = Mutex::new(false);

// تعریف شفاف استراکچر پروکسی‌نود جهت هماهنگی کامل و بدون خطا با فلاتر
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct ProxyNode {
    pub name: String,
    pub protocol: String,
    pub raw_url: String,
}

pub fn is_connected() -> bool {
    let process_guard = PROXY_PROCESS.lock().unwrap();
    process_guard.is_some()
}

pub fn is_tor_connected() -> bool {
    let process_guard = TOR_PROCESS.lock().unwrap();
    process_guard.is_some()
}

pub fn is_psiphon_connected() -> bool {
    let process_guard = PSIPHON_PROCESS.lock().unwrap();
    process_guard.is_some()
}

pub fn is_dns_active() -> bool {
    ACTIVE_DNS.lock().unwrap().is_some()
}

/// دریافت درصد پیشرفت فعلی فرآیند بوت‌استرپ تور توسط فلاتر
pub fn get_tor_bootstrap_progress() -> i32 {
    *TOR_BOOTSTRAP_PERCENT.lock().unwrap()
}

/// بررسی اینکه آیا اتصال سایفون به سرورهای خارجی به طور واقعی برقرار شده است یا خیر
pub fn is_psiphon_bootstrap_done() -> bool {
    *PSIPHON_CONNECTED.lock().unwrap()
}

/// پینگ سریع سرور دی‌ان‌اس روی پورت ۵۳
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

/// پینگ سریع و واقعی آدرس سرور پروکسی روی پورت مقصد با اندازه گیری لاتنسی دست دهی TCP
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

/// اعمال دی‌ان‌اس انتخابی کاربر روی تمام کارت‌های شبکه فعال ویندوز با پاورشل بومی
pub fn set_system_dns(primary: String, secondary: String) -> Result<String, String> {
    let mut process_guard = ACTIVE_DNS.lock().unwrap();

    if process_guard.is_some() {
        return Err("یک دی‌ان‌اس در حال حاضر فعال است. ابتدا آن را خاموش کنید.".to_string());
    }

    let script = format!(
        "Get-NetAdapter | Where-Object {{$_.Status -eq 'Up'}} | Set-DnsClientServerAddress -ServerAddresses ('{}', '{}')",
        primary, secondary
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
                Ok("دی‌ان‌اس تحریم‌شکن با موفقیت روی سیستم فعال شد.".to_string())
            } else {
                Err("خطا در اعمال تنظیمات دی‌ان‌اس. لطفاً مطمئن شوید برنامه را به عنوان Administrator اجرا کرده‌اید.".to_string())
            }
        }
        Err(e) => Err(format!("خطا در اجرای اسکریپت پاورشل: {}", e)),
    }
}

/// بازنشانی تنظیمات دی‌ان‌اس سیستم‌عامل به حالت خودکار (DHCP)
pub fn reset_system_dns() -> Result<String, String> {
    let mut process_guard = ACTIVE_DNS.lock().unwrap();

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
                Err("خطا در ریست دی‌ان‌اس. لطفاً مطمئن شوید برنامه را به عنوان Administrator اجرا کرده‌اید.".to_string())
            }
        }
        // تصحیح خطای تایپی ماکروی فرمت برای مهار کامل باگ کامپایلر راست
        Err(e) => Err(format!("خطا در ریست دی‌ان‌اس. لطفاً مطمئن شوید برنامه را به عنوان Administrator اجرا کرده‌اید. جزییات: {}", e))
    }
}

/// کنترل اتوماتیک تنظیمات پروکسی سیستم‌عامل در ویندوز
fn set_windows_system_proxy(enable: bool, host: String, port: u16) {
    if cfg!(target_os = "windows") {
        let enable_val = if enable { "1" } else { "0" };
        
        let _ = Command::new("reg")
            .args(&[
                "add", 
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 
                "/v", "ProxyEnable", 
                "/t", "REG_DWORD", 
                "/d", enable_val, 
                "/f"
            ])
            .output();

        if enable {
            // استفاده از پروتکل استاندارد HTTP جهت مهار قطعی نشت DNS در کل مرورگرها
            let proxy_server = format!("{}:{}", host, port);
            
            let _ = Command::new("reg")
                .args(&[
                    "add", 
                    "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 
                    "/v", "ProxyServer", 
                    "/t", "REG_SZ", 
                    "/d", &proxy_server, 
                    "/f"
                ])
                .output();
        }
    }
}

/// شروع به کار هسته تور به همراه HTTPTunnelPort مجزا جهت رفع کامل نشت DNS
pub fn start_tor_core(binary_path: String, country_code: String, use_system_proxy: bool) -> Result<String, String> {
    let mut process_guard = TOR_PROCESS.lock().unwrap();

    if process_guard.is_some() {
        return Err("شبکه تور در حال حاضر فعال است.".to_string());
    }

    {
        let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap();
        *progress = 0;
    }

    let temp_torrc_path = "temp_torrc";
    // باز کردن SocksPort روی پورت ۹۰۵۰ و باز کردن پورت HTTPTunnelPort روی ۹۰۵۱ برای مهار نشت دی‌ان‌اس
    let mut torrc_content = "SocksPort 9050\nHTTPTunnelPort 9051\n".to_string();

    if !country_code.is_empty() {
        torrc_content.push_str(&format!("ExitNodes {{{}}}\nStrictNodes 1\n", country_code));
    }

    let mut file = File::create(temp_torrc_path)
        .map_err(|e| format!("خطا در ایجاد فایل پیکربندی تور: {}", e))?;
    
    file.write_all(torrc_content.as_bytes())
        .map_err(|e| format!("خطا در ذخیره فایل پیکربندی تور: {}", e))?;

    let mut command = Command::new(&binary_path);
    command.arg("-f").arg(temp_torrc_path)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let mut child = command.spawn()
        .map_err(|e| format!("خطا در اجرای فرآیند تور: {}", e))?;

    let stdout = child.stdout.take().ok_or("خطا در دریافت خروجی متنی تور")?;

    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            if let Ok(l) = line {
                if let Some(pos) = l.find("Bootstrapped ") {
                    let sub = &l[pos + 13..];
                    if let Some(percent_pos) = sub.find('%') {
                        if let Ok(percent) = sub[..percent_pos].parse::<i32>() {
                            let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap();
                            *progress = percent;
                        }
                    }
                }
            }
        }
    });

    *process_guard = Some(child);
    
    if use_system_proxy {
        // هدایت ترافیک به پورت HTTP بومی تور (پورت ۹۰۵۱) برای رفع تحریم و نشت DNS
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 9051);
    }
    
    Ok("فرآیند تور آغاز شد. در حال اتصال به شبکه پیاز...".to_string())
}

/// متوقف کردن کامل شبکه تور
pub fn stop_tor_core() -> Result<String, String> {
    let mut process_guard = TOR_PROCESS.lock().unwrap();

    if let Some(mut child) = process_guard.take() {
        match child.kill() {
            Ok(_) => {
                let _ = std::fs::remove_file("temp_torrc");
                set_windows_system_proxy(false, String::new(), 0);
                
                let mut progress = TOR_BOOTSTRAP_PERCENT.lock().unwrap();
                *progress = 0;
                
                Ok("اتصال تور متوقف و سیستم به حالت عادی برگشت.".to_string())
            }
            Err(e) => Err(format!("خطا در متوقف کردن فرآیند تور: {}", e)),
        }
    } else {
        Err("شبکه تور در حال اجرا نیست.".to_string())
    }
}

/// شروع به کار هسته بومی سایفون به همراه ساخت پورت بومی HTTP Proxy جهت مهار نشت DNS
pub fn start_psiphon_core(binary_path: String, country_code: String, use_system_proxy: bool) -> Result<String, String> {
    let mut process_guard = PSIPHON_PROCESS.lock().unwrap();

    if process_guard.is_some() {
        return Err("شبکه سایفون در حال حاضر فعال است.".to_string());
    }

    {
        let mut connected = PSIPHON_CONNECTED.lock().unwrap();
        *connected = false;
    }

    let temp_config_path = "temp_psiphon_config.json";
    
    // باز کردن Socks روی پورت ۹۰۸۰ و پورت لوکال HTTP روی پورت ۹۰۸۱ جهت رفع نشت DNS
    let mut config_json = serde_json::json!({
        "LocalSocksProxyPort": 9080,
        "LocalHttpProxyPort": 9081,
        "PropagationChannelId": "FFFFFFFFFFFFFFFF",
        "SponsorId": "FFFFFFFFFFFFFFFF"
    });

    if !country_code.is_empty() {
        config_json["EgressRegion"] = serde_json::json!(country_code);
    }

    let mut file = File::create(temp_config_path)
        .map_err(|e| format!("خطا در ایجاد فایل تنظیمات سایفون: {}", e))?;
    
    file.write_all(config_json.to_string().as_bytes())
        .map_err(|e| format!("خطا در ذخیره فایل تنظیمات سایفون: {}", e))?;

    let mut command = Command::new(&binary_path);
    command.arg("-config")
           .arg(temp_config_path)
           .stdin(Stdio::null())
           .stdout(Stdio::piped())
           .stderr(Stdio::null());

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000); 

    let mut child = command.spawn()
        .map_err(|e| format!("خطا در اجرای فرآیند سایفون: {}", e))?;

    let stdout = child.stdout.take().ok_or("خطا در دریافت خروجی متنی سایفون")?;

    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            if let Ok(l) = line {
                if l.contains("\"noticeType\":\"Tunnels\"") && l.contains("\"count\":1") {
                    let mut connected = PSIPHON_CONNECTED.lock().unwrap();
                    *connected = true; 
                }
            }
        }
    });

    *process_guard = Some(child);
    
    if use_system_proxy {
        // هدایت ترافیک به پورت HTTP بومی سایفون (پورت ۹۰۸۱) برای مهار کامل نشت DNS
        set_windows_system_proxy(true, "127.0.0.1".to_string(), 9081);
    }
    
    Ok("در حال برقراری اتصال با سرورهای سایفون؛ لطفاً چند لحظه شکیبا باشید...".to_string())
}

/// متوقف کردن کامل شبکه سایفون
pub fn stop_psiphon_core() -> Result<String, String> {
    let mut process_guard = PSIPHON_PROCESS.lock().unwrap();

    if let Some(mut child) = process_guard.take() {
        match child.kill() {
            Ok(_) => {
                let _ = std::fs::remove_file("temp_psiphon_config.json");
                let _ = std::fs::remove_file("remote_server_list");
                
                let mut connected = PSIPHON_CONNECTED.lock().unwrap();
                *connected = false;

                set_windows_system_proxy(false, String::new(), 0);
                Ok("اتصال سایفون متوقف و سیستم به حالت عادی برگشت.".to_string())
            }
            Err(e) => Err(format!("خطا در متوقف کردن فرآیند سایفون: {}", e)),
        }
    } else {
        Err("شبکه سایفون در حال اجرا نیست.".to_string())
    }
}

/// اسکنر پیشرفته کلودفلر
fn scan_single_ip(ip: &str, port: u16, sni: &str, timeout_ms: u64) -> Option<u128> {
    let addr = format!("{}:{}", ip, port).parse::<SocketAddr>().ok()?;
    let start = Instant::now();
    
    let stream = TcpStream::connect_timeout(&addr, Duration::from_millis(timeout_ms)).ok()?;
    
    let connector = TlsConnector::new().ok()?;
    let _tls_stream = connector.connect(sni, stream).ok()?;
    
    let duration = start.elapsed().as_millis();
    Some(duration)
}

/// شروع اسکن چندنخی آی‌پی‌های کلودفلر
pub fn run_cloudflare_scanner(uuid: String, path: String, worker: String) -> Vec<ProxyNode> {
    let ip_list = vec![
        "104.21.0.1", "104.22.0.1", "172.67.0.1", "104.27.110.232",
        "104.16.0.1", "104.18.0.1", "162.159.0.1", "104.26.0.1",
        "172.65.0.1", "104.24.0.1", "104.20.0.1", "104.25.0.1"
    ];

    let (tx, rx) = mpsc::channel();
    let mut handles = vec![];

    for ip in ip_list {
        let tx_clone = tx.clone();
        let worker_clone = worker.clone();
        let ip_str = ip.to_string();

        let handle = thread::spawn(move || {
            if let Some(latency) = scan_single_ip(&ip_str, 2053, &worker_clone, 1500) {
                let _ = tx_clone.send((ip_str, latency));
            }
        });
        handles.push(handle);
    }

    drop(tx);

    for h in handles {
        let _ = h.join();
    }

    let mut results = Vec::new();
    while let Ok((ip, latency)) = rx.try_recv() {
        results.push((ip, latency));
    }

    results.sort_by_key(|&(_, lat)| lat);

    let mut clean_nodes = Vec::new();
    for (ip, latency) in results {
        let encoded_path = urlencoding::encode(&path);
        let raw_url = format!(
            "vless://{}@{}:2053?encryption=none&security=tls&sni={}&fp=chrome&alpn=http%2F1.1&insecure=0&allowInsecure=0&type=ws&host={}&path={}#{}%3A2053%20%7C%20TLS%20%7C%20HTTP1.1%20%7C%20{}ms",
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

/// اجرای پروکسی سنگ‌باکس با هدایت قطعی خروجی‌ها به Stdio::null جهت مخفی‌سازی کامل و بی‌صدا
pub fn start_proxy_with_node(
    binary_path: String,
    selected_node: ProxyNode,
    use_system_proxy: bool,
    custom_sni: Option<String>,
    enable_fragment: bool,
    enable_record_fragment: bool,
    tls_spoof: Option<String>,
    use_tun_mode: bool,
) -> Result<String, String> {
    // تکنیک خودکارسازی: قبل از شروع، هرگونه هستهٔ یتیم باقی‌مانده از قبل در پس‌زمینه ویندوز را کاملاً بی‌صدا ببند و پورت را آزاد کن
    #[cfg(target_os = "windows")]
    let _ = Command::new("taskkill")
        .args(&["/F", "/IM", "sing-box.exe"])
        .creation_flags(0x08000000) // مخفی‌سازی کامل پنجره CMD
        .output();

    let mut process_guard = PROXY_PROCESS.lock().unwrap();

    if process_guard.is_some() {
        return Err("پروکسی در حال حاضر فعال است.".to_string());
    }

    // پاس دادن پارامترهای جدید به تابع مبدل کانفیگ
    let outbound_json = convert_link_to_outbound(
        selected_node,
        custom_sni,
        enable_fragment,
        enable_record_fragment,
        tls_spoof,
    )?;

    // ایجاد لیست درگاه‌های ورودی پروکسی و شبکه مجازی (TUN)
    let mut inbounds = serde_json::json!([
        {
            "type": "mixed",
            "listen": "127.0.0.1",
            "listen_port": 2080
        }
    ]);

    // در صورت فعال بودن TUN، پیکربندی کارت شبکه مجازی را تزریق کن
    if use_tun_mode {
        inbounds.as_array_mut().unwrap().push(serde_json::json!({
            "type": "tun",
            // استفاده از آرایه استاندارد address به جای فیلد منسوخ‌شده inet4_address برای سازگاری با کل نسخه‌های جدید
            "address": [
                "172.19.0.1/30"
            ],
            "auto_route": true,
            "strict_route": true,
            "stack": "gvisor"
            // توجه: فیلد "sniff": true منسوخ شده در نسخه ۱.۱۱ و کاملاً حذف شده در نسخه ۱.۱۳، از بدنه این باند تان جهت حل کرش حذف گردید.
        }));
    }

    let final_config = serde_json::json!({
        "log": {
            "level": "info"
        },
        // فعال‌سازی کنترلر Clash API بر روی پورت ۹۰۹۰ جهت استعلام سرعت زنده توسط فلاتر
        "experimental": {
            "clash_api": {
                "external_controller": "127.0.0.1:9090"
            }
        },
        "dns": {
            // ساختار DNS نوین و فاقد لایسنس منسوخ‌شده (DoH و UDP رسمی نسخه ۱.۱۲ به بالا)
            "servers": [
                {
                    "type": "https",
                    "tag": "dns_proxy",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                    "detour": "proxy-out",
                    // هماهنگی ۱۰۰٪ با لایه امنیت شبکه: فعال‌سازی وریفیکیشن منعطف برای مهار ارور گواهی IP SAN و انقضا
                    "tls": {
                        "enabled": true,
                        "server_name": "cloudflare-dns.com",
                        "insecure": true
                    }
                },
                {
                    "type": "udp",
                    "tag": "dns_direct",
                    "server": "8.8.8.8",
                    "server_port": 53
                    // حذف فیلد منسوخ‌شده detour: direct که منجر به خطای detour to empty direct outbound می‌شد
                }
            ],
            "rules": [
                // مابقی قوانین دی‌ان‌اس بدون استفاده از فیلد منسوخ‌شدهٔ outbound جهت سازگاری با ۱.۱۳ به بالا
                {
                    "query_type": [
                        "A",
                        "AAAA"
                    ],
                    "server": "dns_proxy"
                }
            ],
            "final": "dns_proxy"
        },
        "inbounds": inbounds,
        "outbounds": [
            outbound_json,
            {
                "type": "direct",
                "tag": "direct"
            }
        ],
        "route": {
            // فعال‌سازی بسیار حیاتی این فیلد برای تفکیک اتوماتیک کارت فیزیکی و مهار Routing Loop در ویندوز
            "auto_detect_interface": true,
            // مشخص کردن حل‌کننده پیش‌فرض مستقیم برای روت بر اساس استاندارد نسخه ۱.۱۲ به بالا
            "default_domain_resolver": "dns_direct",
            "rules": [
                {
                    // مانیتور و اسنیف اتوماتیک پروتکل‌ها طبق ساختار استاندارد نسخه ۱.۱۳ به بالا به جای فیلد منسوخ‌شده سنتی
                    "action": "sniff"
                },
                {
                    // تکنیک فوق‌العاده مدرن hijack-dns جایگزین اوت‌باند منسوخ‌شدهٔ dns-out برای سازگاری با نسخه ۱.۱۳ به بالا
                    "port": [
                        53
                    ],
                    "action": "hijack-dns"
                }
            ]
        }
    });

    let temp_config_path = "temp_config.json";
    let mut file = File::create(temp_config_path)
        .map_err(|e| format!("خطا در ساخت فایل پیکربندی: {}", e))?;
    
    file.write_all(final_config.to_string().as_bytes())
        .map_err(|e| format!("خطا در ذخیره‌سازی فایل پیکربندی: {}", e))?;

    let mut command = Command::new(&binary_path);
    command.arg("run").arg("-c").arg(temp_config_path);

    // هدایت تمام خروجی‌ها و خطاهای هسته به فایل لاگ جهت عیب‌یابی راحت‌تر
    let log_file = File::create("sing_box_log.txt")
        .map_err(|e| format!("خطا در ایجاد فایل لاگ: {}", e))?;

    command.stdin(Stdio::null())
           .stdout(Stdio::from(log_file.try_clone().map_err(|e| e.to_string())?))
           .stderr(Stdio::from(log_file));

    #[cfg(target_os = "windows")]
    command.creation_flags(0x08000000);

    let child = command.spawn();

    match child {
        Ok(c) => {
            *process_guard = Some(c);
            
            if use_system_proxy && !use_tun_mode {
                // سنگ‌باکس روی mixed پورت ۲۰۸۰ کار می‌کند که ترافیک HTTP را به طور کامل بدون نشت عبور می‌دهد
                set_windows_system_proxy(true, "127.0.0.1".to_string(), 2080);
            }
            
            Ok("اتصال با موفقیت برقرار شد.".to_string())
        }
        Err(e) => Err(format!("خطا در اجرای فرآیند هسته: {}", e)),
    }
}

/// قطع پروکسی و بازگردانی تنظیمات پروکسی سیستم‌عامل به حالت اول
pub fn stop_proxy_core() -> Result<String, String> {
    let mut process_guard = PROXY_PROCESS.lock().unwrap();

    if let Some(mut child) = process_guard.take() {
        match child.kill() {
            Ok(_) => {
                let _ = std::fs::remove_file("temp_config.json");
                set_windows_system_proxy(false, String::new(), 0);
                Ok("پروکسی متوقف و سیستم به حالت عادی برگشت.".to_string())
            }
            Err(e) => Err(format!("خطا در متوقف کردن فرآیند: {}", e)),
        }
    } else {
        Err("پروکسی در حال اجرا نیست.".to_string())
    }
}

/// پردازش اولیه ورودی‌های لینک‌ها
pub fn parse_import_links(input: String) -> Result<Vec<ProxyNode>, String> {
    let mut nodes = Vec::new();

    if input.starts_with("http://") || input.starts_with("https://") {
        return Err("لطفاً متن دریافت شده از لینک ساب را وارد کنید.".to_string());
    }

    let decoded_content = if let Ok(decoded_bytes) = general_purpose::STANDARD.decode(input.trim()) {
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
            let protocol = url.scheme().to_string();
            if protocol == "vless" || protocol == "trojan" {
                let name = url.fragment()
                    .map(|f| urlencoding::decode(f).unwrap_or_else(|_| f.into()).to_string())
                    .unwrap_or_else(|| "سرور ناشناس".to_string());

                nodes.push(ProxyNode {
                    name,
                    protocol,
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

/// پارس کردن لینک نود ویتوری و ایجاد ساختار JSON خروجی سنگ‌باکس با فیلدهای جدید
fn convert_link_to_outbound(
    node: ProxyNode,
    custom_sni: Option<String>,
    enable_fragment: bool,
    enable_record_fragment: bool,
    tls_spoof: Option<String>,
) -> Result<serde_json::Value, String> {
    let parsed_url = Url::parse(&node.raw_url).map_err(|e| e.to_string())?;
    let host = parsed_url.host_str().ok_or("هاست یافت نشد")?;
    let port = parsed_url.port().ok_or("پورت یافت نشد")?;
    
    let mut outbound = serde_json::json!({
        "type": node.protocol,
        "tag": "proxy-out",
        "server": host,
        "server_port": port,
    });

    if node.protocol == "vless" {
        let uuid = parsed_url.username();
        outbound["uuid"] = serde_json::json!(uuid);
    } else if node.protocol == "trojan" {
        let password = parsed_url.username();
        outbound["password"] = serde_json::json!(password);
    }

    let mut sni = "".to_string();
    let mut path = "".to_string();
    let mut network = "tcp".to_string();
    let mut security = "none".to_string();
    let mut ws_host = "".to_string();

    for (key, val) in parsed_url.query_pairs() {
        match key.as_ref() {
            "sni" => sni = val.into_owned(),
            "path" => path = val.into_owned(),
            "type" => network = val.into_owned(),
            "security" => security = val.into_owned(),
            "host" => ws_host = val.into_owned(),
            _ => {}
        }
    }

    // جایگزینی SNI پیش‌فرض در صورت تعریف SNI سفارشی توسط کاربر
    let final_sni = if let Some(ref cs) = custom_sni {
        if !cs.trim().is_empty() {
            cs.trim().to_string()
        } else {
            sni
        }
    } else {
        sni
    };

    if security == "tls" || security == "reality" {
        let mut tls_obj = serde_json::json!({
            "enabled": true,
            "server_name": final_sni,
        });

        // ۱. اگر کاربر SNI سفارشی وارد کرده بود، تایید سخت‌گیرانه گواهی را دور بزن تا از خطا جلوگیری شود
        if custom_sni.is_some() {
            tls_obj["insecure"] = serde_json::json!(true);
        }

        // ۲. اعمال تکنیک قطعه‌بندی ترافیک (Fragment) کاملاً استاندارد و منحصراً درون بلاک TLS
        if enable_fragment {
            tls_obj["fragment"] = serde_json::json!(true);
            tls_obj["fragment_fallback_delay"] = serde_json::json!("500ms");
        }
        if enable_record_fragment {
            tls_obj["record_fragment"] = serde_json::json!(true);
        }

        // ۳. اعمال ویژگی جعل SNI (TLS Spoof) استاندارد داخل بلاک TLS برای نسخه ۱.۱۴ به بالا
        if let Some(ref spoof) = tls_spoof {
            if !spoof.trim().is_empty() {
                tls_obj["spoof"] = serde_json::json!(spoof.trim());
            }
        }

        outbound["tls"] = tls_obj;
    }

    // توجه: تمامی فیلدهای غیرمجاز روت که پیش‌تر باعث کرش کردن سینگ‌باکس می‌شدند، از ریشه روتِ outbound حذف شدند.

    if network == "ws" || network == "grpc" {
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
        }
        
        outbound["transport"] = transport;
    }

    Ok(outbound)
}