use serde::{Deserialize, Serialize};

/// استراتژی‌های خرد کردن پکت برای پنهان‌سازی هدر و SNI از چشم DPI
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub enum EvasionStrategy {
    /// بدون فرگمنت
    None,
    /// خرد کردن در لایه رکوردهای TLS (TLS Record Layer)
    TlsRecordSplit,
    /// خرد کردن در لایه سگمنت‌های TCP با ایجاد وقفه میکروثانیه‌ای
    TcpSegmentSplit,
}

/// نتیجه آزمایش دقیق فرگمنت روی سرور مقصد
#[derive(Debug, Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct FragmentTestResult {
    pub strategy: EvasionStrategy,
    pub is_successful: bool,
    /// آفست برش بایت (مثلاً بایت ۱ یا ۳ یا ۵)
    pub split_offset: usize,
    /// وقفه زمانی به میلی‌ثانیه بین ارسال تکه‌ها
    pub delay_ms: u64,
    /// تاخیر زمانی هندشیک واقعی لایه ۷
    pub handshake_time_ms: i32,
    /// آیا تلاش میدلباکس برای بستن پورت با RST فیک خنثی شد؟
    pub fake_rst_mitigated: bool,
}

/// وضعیت پایش و راستی‌آزمایی پورت‌های سرور
#[derive(Debug, Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct PortVerification {
    pub port: u16,
    pub is_reachable: bool,
    pub verified_tls_response: bool,
    pub latency_ms: i32,
}

/// شاخص‌های چندگانه برای ارزیابی جامع کیفیت اتصال
#[derive(Debug, Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct ConnectionQualityMetrics {
    pub latency_ms: f32,
    pub jitter_ms: f32,
    pub packet_loss_ratio: f32,
    pub handshake_time_ms: f32,
    pub stability_factor: f32,
    /// امتیاز کل محاسبه‌شده بر پایه وزن‌های هوشمند (از ۰ تا ۱۰۰)
    pub overall_score: f32,
}

/// خروجی استاندارد و کالیبره‌شده هسته اول برای تحویل به فلاتر و موتور Sing-box
#[derive(Debug, Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct CalibratedConnectionProfile {
    pub target_host: String,
    pub selected_port: u16,
    pub enable_tls_fragment: bool,
    pub enable_record_fragment: bool,
    pub optimal_delay_str: String,
    pub recommended_padding_bytes: usize,
    pub quality_metrics: ConnectionQualityMetrics,
    /// آیا از حافظه یادگیری سریع (Fast-Path بدون معطلی تست) استفاده شد؟
    pub is_fast_path_cached: bool,
    /// سقف واقعی ظرفیت پکت دکل مخابراتی کاربر (Path MTU)
    pub optimal_mtu: u16,
    /// کران پایین بازه مورد انتظار برای هسته دوم (L)
    pub expected_latency_lower: f64,
    /// کران بالای بازه مورد انتظار برای هسته دوم (U)
    pub expected_latency_upper: f64,
}

/// شدت انحراف رفتاری اتصال از خط استاندارد
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub enum DeviationSeverity {
    Normal,
    Warning,
    Critical,
}

/// گزارش تحلیلی هسته دوم بر اساس فرمول ریاضی: d(y, R)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[flutter_rust_bridge::frb(non_opaque)]
pub struct BehaviorAnalysisReport {
    pub sample_count: u64,
    pub moving_average: f64,
    pub standard_deviation: f64,
    pub expected_range_lower: f64,
    pub expected_range_upper: f64,
    pub actual_measured_value: f64,
    /// مقدار انحراف محاسبه‌شده دقیقاً طبق فرمول d(y, R)
    pub deviation_value: f64,
    pub severity: DeviationSeverity,
    pub is_degraded: bool,
    pub alert_message: String,
}