use std::process::Command;
use std::net::IpAddr;

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

pub struct PmtuProber;

impl PmtuProber {
    /// اندازه‌گیری سقف ظرفیت پکت دکل مخابراتی (Path MTU) با فلگ Don't Fragment
    pub fn probe_carrier_path_mtu(target_host: &str) -> u16 {
        // تعیین آدرس هدف برای تست دکل
        let probe_ip = if target_host.parse::<IpAddr>().is_ok() {
            target_host.to_string()
        } else {
            // در صورت دامنه بودن، از Anycast استاندارد برای سنجش هاپ اول دکل استفاده می‌شود
            "1.1.1.1".to_string()
        };

        // تست باینری سریع: اول 1500 استاندارد را می‌سنجد، اگر دراپ شد سقف‌های دکل را ارزیابی می‌کند
        if Self::test_packet_size(&probe_ip, 1472) {
            // پکت 1472 بایت دیتا + 28 بایت هدر = 1500 بایت استاندارد
            return 1500;
        }

        if Self::test_packet_size(&probe_ip, 1392) {
            // 1420 بایت MTU مناسب خطوط 4G با کپسول‌سازی GTP سبک
            return 1420;
        }

        if Self::test_packet_size(&probe_ip, 1352) {
            // 1380 بایت طلایی‌ترین سقف دکل‌های همراه اول و ایرانسل
            return 1380;
        }

        if Self::test_packet_size(&probe_ip, 1312) {
            return 1340;
        }

        // سقف نهایی امن در شرایط اختلال شدید
        1280
    }

    #[cfg(target_os = "windows")]
    fn test_packet_size(target_ip: &str, payload_bytes: usize) -> bool {
        let payload_str = payload_bytes.to_string();
        let mut cmd = Command::new("ping");
        cmd.args(&["-n", "1", "-w", "1500", "-l", &payload_str, "-f", target_ip])
           .creation_flags(0x08000000); // اجرای کاملاً مخفی در پس‌زمینه

        if let Ok(output) = cmd.output() {
            let stdout_str = String::from_utf8_lossy(&output.stdout);
            // اگر دکل بسته را رد کند و اجازه خرد شدن ندهد، این خطا در ویندوز صادر می‌شود
            if stdout_str.contains("needs to be fragmented") 
               || stdout_str.contains("Packet needs to be fragmented") 
               || stdout_str.contains("100% loss") {
                return false;
            }
            if stdout_str.contains("Reply from") || stdout_str.contains("TTL=") {
                return true;
            }
        }

        false
    }

    #[cfg(not(target_os = "windows"))]
    fn test_packet_size(_target_ip: &str, _payload_bytes: usize) -> bool {
        true
    }
}