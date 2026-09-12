use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::time::{Duration, Instant};
use std::thread;
use socket2::{Socket, Domain, Type, Protocol};
use rand::Rng;
use crate::smart_core_types::{EvasionStrategy, FragmentTestResult, PortVerification};

pub struct FragmentProber;

impl FragmentProber {
    /// ساخت بسته خام و استاندارد TLS 1.2 / 1.3 ClientHello به همراه اکستنشن SNI
    pub fn build_client_hello_payload(sni_domain: &str) -> Vec<u8> {
        let mut rng = rand::thread_rng();
        let mut random_bytes = [0u8; 32];
        rng.fill(&mut random_bytes);

        let sni_bytes = sni_domain.as_bytes();
        let sni_len = sni_bytes.len() as u16;

        // ساخت اکستنشن Server Name Indication (SNI)
        let mut sni_ext = Vec::new();
        sni_ext.extend_from_slice(&[0x00, 0x00]); // Extension Type: server_name (0)
        sni_ext.extend_from_slice(&(sni_len + 5).to_be_bytes()); // Extension Length
        sni_ext.extend_from_slice(&(sni_len + 3).to_be_bytes()); // Server Name list length
        sni_ext.push(0x00); // Host Name Type: 0 (host_name)
        sni_ext.extend_from_slice(&sni_len.to_be_bytes());
        sni_ext.extend_from_slice(sni_bytes);

        // اکستنشن Supported Versions (TLS 1.3 و TLS 1.2)
        let supported_versions_ext = vec![
            0x00, 0x2b, // Extension Type: supported_versions (43)
            0x00, 0x03, // Length: 3
            0x02,       // Supported Versions Length: 2
            0x03, 0x04  // TLS 1.3
        ];

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&sni_ext);
        extensions.extend_from_slice(&supported_versions_ext);
        let ext_total_len = extensions.len() as u16;

        // بدنه ClientHello
        let mut client_hello = Vec::new();
        client_hello.extend_from_slice(&[0x03, 0x03]); // Client Version: TLS 1.2 (for compatibility)
        client_hello.extend_from_slice(&random_bytes);  // 32 Random bytes
        client_hello.push(0x00);                       // Session ID Length: 0
        
        // لیست سایفرهای استاندارد امن
        let cipher_suites: [u8; 8] = [
            0x13, 0x01, // TLS_AES_128_GCM_SHA256
            0x13, 0x02, // TLS_AES_256_GCM_SHA384
            0xc0, 0x2b, // ECDHE-ECDSA-AES128-GCM-SHA256
            0xc0, 0x2f  // ECDHE-RSA-AES128-GCM-SHA256
        ];
        client_hello.extend_from_slice(&(cipher_suites.len() as u16).to_be_bytes());
        client_hello.extend_from_slice(&cipher_suites);

        client_hello.extend_from_slice(&[0x01, 0x00]); // Compression methods: 1 (null)
        client_hello.extend_from_slice(&ext_total_len.to_be_bytes());
        client_hello.extend_from_slice(&extensions);

        // بسته بندی در رکورد Handshake
        let mut handshake_record = Vec::new();
        handshake_record.push(0x01); // Handshake Type: ClientHello (1)
        let hs_len = client_hello.len() as u32;
        handshake_record.push(((hs_len >> 16) & 0xff) as u8);
        handshake_record.push(((hs_len >> 8) & 0xff) as u8);
        handshake_record.push((hs_len & 0xff) as u8);
        handshake_record.extend_from_slice(&client_hello);

        // بسته بندی نهایی در رکورد لایه انتقال TLS Record
        let mut full_packet = Vec::new();
        full_packet.push(0x16); // Content Type: Handshake (22)
        full_packet.extend_from_slice(&[0x03, 0x01]); // Version: TLS 1.0 (Record standard)
        let record_len = handshake_record.len() as u16;
        full_packet.extend_from_slice(&record_len.to_be_bytes());
        full_packet.extend_from_slice(&handshake_record);

        full_packet
    }

    /// تست زنده یک روش فرگمنت روی آدرس و پورت سرور
    pub fn probe_single_fragment(
        target_addr: SocketAddr,
        sni_domain: &str,
        strategy: EvasionStrategy,
        split_offset: usize,
        delay_ms: u64,
        timeout: Duration,
    ) -> FragmentTestResult {
        let payload = Self::build_client_hello_payload(sni_domain);
        let start_time = Instant::now();

        // ایجاد سوکت سفارشی با socket2 برای اعمال تنظیمات TCP_NODELAY
        let socket = match Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)) {
            Ok(s) => s,
            Err(_) => {
                return FragmentTestResult {
                    strategy,
                    is_successful: false,
                    split_offset,
                    delay_ms,
                    handshake_time_ms: -1,
                    fake_rst_mitigated: false,
                };
            }
        };

        let _ = socket.set_nodelay(true);
        let _ = socket.set_read_timeout(Some(timeout));
        let _ = socket.set_write_timeout(Some(timeout));

        if socket.connect(&target_addr.into()).is_err() {
            return FragmentTestResult {
                strategy,
                is_successful: false,
                split_offset,
                delay_ms,
                handshake_time_ms: -1,
                fake_rst_mitigated: false,
            };
        }

        let mut stream: TcpStream = socket.into();

        // ارسال پکت طبق استراتژی انتخاب شده
        let send_result = match strategy {
            EvasionStrategy::None => {
                stream.write_all(&payload)
            }
            EvasionStrategy::TcpSegmentSplit => {
                let cut = split_offset.min(payload.len() - 1).max(1);
                let first_chunk = &payload[..cut];
                let second_chunk = &payload[cut..];

                if let Err(e) = stream.write_all(first_chunk) {
                    Err(e)
                } else {
                    let _ = stream.flush();
                    if delay_ms > 0 {
                        thread::sleep(Duration::from_millis(delay_ms));
                    }
                    stream.write_all(second_chunk)
                }
            }
            EvasionStrategy::TlsRecordSplit => {
                // تقسیم در قالب دو رکورد مجزای TLS
                let cut = split_offset.min(payload.len() - 6).max(5);
                let chunk1 = &payload[..cut];
                let chunk2 = &payload[cut..];

                if let Err(e) = stream.write_all(chunk1) {
                    Err(e)
                } else {
                    let _ = stream.flush();
                    if delay_ms > 0 {
                        thread::sleep(Duration::from_millis(delay_ms));
                    }
                    stream.write_all(chunk2)
                }
            }
        };

        if send_result.is_err() {
            return FragmentTestResult {
                strategy,
                is_successful: false,
                split_offset,
                delay_ms,
                handshake_time_ms: -1,
                fake_rst_mitigated: false,
            };
        }

        let _ = stream.flush();

        // خواندن پاسخ اولیه سرور: آیا پاسخ با 0x16 0x03 (ServerHello معتبر) شروع می‌شود؟
        let mut response_header = [0u8; 5];
        match stream.read_exact(&mut response_header) {
            Ok(_) => {
                let is_tls_handshake = response_header[0] == 0x16 && response_header[1] == 0x03;
                let elapsed = start_time.elapsed().as_millis() as i32;

                FragmentTestResult {
                    strategy,
                    is_successful: is_tls_handshake,
                    split_offset,
                    delay_ms,
                    handshake_time_ms: if is_tls_handshake { elapsed } else { -1 },
                    fake_rst_mitigated: is_tls_handshake && (strategy != EvasionStrategy::None),
                }
            }
            Err(_) => {
                // اگر اتصال ریست شد یا دراپ شد، تست ناموفق است
                FragmentTestResult {
                    strategy,
                    is_successful: false,
                    split_offset,
                    delay_ms,
                    handshake_time_ms: -1,
                    fake_rst_mitigated: false,
                }
            }
        }
    }

    /// غربالگری هوشمند و بدون معطلی برای کشف بهترین فرگمنت ممکن
    pub fn sweep_best_fragment(
        host: &str,
        port: u16,
        sni: &str,
    ) -> FragmentTestResult {
        let addr_str = format!("{}:{}", host, port);
        let socket_addr: SocketAddr = match addr_str.to_socket_addrs().ok().and_then(|mut a| a.next()) {
            Some(a) => a,
            None => {
                return FragmentTestResult {
                    strategy: EvasionStrategy::None,
                    is_successful: false,
                    split_offset: 0,
                    delay_ms: 0,
                    handshake_time_ms: -1,
                    fake_rst_mitigated: false,
                };
            }
        };

        // الگوهای طلایی فیلترشکن‌ها برای تست اولویت‌دار و سریع (زیر ۳ ثانیه)
        let candidates = [
            (EvasionStrategy::None, 0, 0),                       // تست مستقیم (شاید اصلاً فیلتر نباشد!)
            (EvasionStrategy::TcpSegmentSplit, 3, 15),          // تقسیم بایت ۳ با وقفه ۱۵ میلی‌ثانیه
            (EvasionStrategy::TcpSegmentSplit, 1, 20),          // تقسیم بایت ۱
            (EvasionStrategy::TlsRecordSplit, 5, 25),           // تقسیم در لایه رکورد
            (EvasionStrategy::TcpSegmentSplit, 5, 30),          // تقسیم بایت ۵ با وقفه ۳۰ میلی‌ثانیه
        ];

        let mut best_result = FragmentTestResult {
            strategy: EvasionStrategy::None,
            is_successful: false,
            split_offset: 0,
            delay_ms: 0,
            handshake_time_ms: 99999,
            fake_rst_mitigated: false,
        };

        for (strat, offset, delay) in candidates {
            let res = Self::probe_single_fragment(
                socket_addr,
                sni,
                strat,
                offset,
                delay,
                Duration::from_millis(1500),
            );

            if res.is_successful {
                // اگر تست مستقیم جواب داد، فورا همان را انتخاب کن تا تاخیر اضافی تحمیل نشود
                if strat == EvasionStrategy::None {
                    return res;
                }

                if res.handshake_time_ms < best_result.handshake_time_ms {
                    best_result = res;
                    break; // اولین فرگمنت سالم با موفقیت پیدا شد!
                }
            }
        }

        best_result
    }

    /// ارزیابی پورت‌های باز روی سرور با بررسی پاسخ واقعی لایه ۷
    pub fn verify_candidate_ports(host: &str, candidate_ports: &[u16], sni: &str) -> Vec<PortVerification> {
        let mut results = Vec::new();

        for &p in candidate_ports {
            let addr_str = format!("{}:{}", host, p);
            if let Ok(mut addrs) = addr_str.to_socket_addrs() {
                if let Some(sock_addr) = addrs.next() {
                    let probe = Self::probe_single_fragment(
                        sock_addr,
                        sni,
                        EvasionStrategy::None,
                        0,
                        0,
                        Duration::from_millis(1200),
                    );

                    results.push(PortVerification {
                        port: p,
                        is_reachable: probe.handshake_time_ms > 0,
                        verified_tls_response: probe.is_successful,
                        latency_ms: probe.handshake_time_ms,
                    });
                }
            }
        }

        results
    }
}