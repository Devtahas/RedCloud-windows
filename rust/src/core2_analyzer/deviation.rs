use std::sync::Mutex;
use crate::smart_core_types::{BehaviorAnalysisReport, DeviationSeverity};

/// ساختار الگوریتم آنلاین Welford برای محاسبه میانگین و واریانس در لحظه
#[derive(Debug, Clone, Default)]
pub struct WelfordOnlineStats {
    count: u64,
    mean: f64,
    m2: f64,
}

impl WelfordOnlineStats {
    pub fn new() -> Self {
        Self {
            count: 0,
            mean: 0.0,
            m2: 0.0,
        }
    }

    /// اضافه کردن نمونه جدید با هزینه محاسباتی O(1) و مصرف رم صفر
    pub fn update(&mut self, sample: f64) {
        self.count += 1;
        let delta = sample - self.mean;
        self.mean += delta / self.count as f64;
        let delta2 = sample - self.mean;
        self.m2 += delta * delta2;
    }

    pub fn count(&self) -> u64 {
        self.count
    }

    pub fn mean(&self) -> f64 {
        self.mean
    }

    pub fn variance(&self) -> f64 {
        if self.count < 2 {
            0.0
        } else {
            self.m2 / (self.count - 1) as f64
        }
    }

    pub fn std_dev(&self) -> f64 {
        self.variance().sqrt()
    }
}

/// موتور تحلیل رفتار اتصال و پایش انحرافات (Core 2 Engine)
pub struct Core2BehaviorAnalyzer {
    stats: Mutex<WelfordOnlineStats>,
    k_factor: f64,                   // ضریب گستره بازه (معمولاً 2.0 برای سطح اطمینان 95%)
    min_samples_to_evaluate: u64,    // حداقل نمونه‌های مورد نیاز برای شروع قضاوت (مثلاً 5 نمونه)
    consecutive_anomalies: Mutex<u32>,
}

impl Core2BehaviorAnalyzer {
    pub fn new(k_factor: f64) -> Self {
        Self {
            stats: Mutex::new(WelfordOnlineStats::new()),
            k_factor: if k_factor <= 0.0 { 2.0 } else { k_factor },
            min_samples_to_evaluate: 5,
            consecutive_anomalies: Mutex::new(0),
        }
    }

    /// ریست کردن وضعیت تحلیل‌گر (مثلاً هنگام تعویض کانفیگ یا سوییچ شبکه)
    pub fn reset(&self) {
        let mut stats = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        *stats = WelfordOnlineStats::new();

        let mut anomalies = self.consecutive_anomalies.lock().unwrap_or_else(|e| e.into_inner());
        *anomalies = 0;
    }

    /// محاسبه انحراف دقیقاً بر اساس فرمول ریاضی: d(y, R)
    /// R = [L, U]
    /// d(y, R) = L - y (if y < L)
    /// d(y, R) = 0     (if L <= y <= U)
    /// d(y, R) = y - U (if y > U)
    pub fn calculate_deviation_math(actual_y: f64, lower_l: f64, upper_u: f64) -> f64 {
        if actual_y < lower_l {
            lower_l - actual_y
        } else if actual_y > upper_u {
            actual_y - upper_u
        } else {
            0.0
        }
    }

    /// ثبت نمونه جدید، به‌روزرسانی مدل آماری و ارزیابی انحراف
    pub fn record_and_analyze(&self, actual_value: f64) -> BehaviorAnalysisReport {
        let mut stats = self.stats.lock().unwrap_or_else(|e| e.into_inner());
        let mut anomalies = self.consecutive_anomalies.lock().unwrap_or_else(|e| e.into_inner());

        let current_count = stats.count();
        let current_mean = stats.mean();
        let current_std = stats.std_dev();

        // 1. تعیین بازه مورد انتظار R = [L, U]
        let (lower_l, upper_u) = if current_count < self.min_samples_to_evaluate {
            // در شروع، بازه بر اساس تلورانس اولیه نمونه تعیین می‌شود
            let initial_margin = (actual_value * 0.35).max(15.0);
            ((actual_value - initial_margin).max(0.0), actual_value + initial_margin)
        } else {
            let margin = self.k_factor * current_std.max(5.0);
            ((current_mean - margin).max(0.0), current_mean + margin)
        };

        // 2. محاسبه مقدار انحراف با تابع ریاضی
        let deviation = Self::calculate_deviation_math(actual_value, lower_l, upper_u);

        // 3. ثبت نمونه در مدل آنلاین Welford
        stats.update(actual_value);

        // 4. تشخیص سطح بحرانی بودن افت کیفیت
        let (severity, is_degraded, alert_msg) = if deviation > 0.0 && actual_value > upper_u {
            *anomalies += 1;
            
            // اگر مقدار بیش از ۳ برابر انحراف معیار فراتر رفته باشد، بحرانی است
            if deviation > (3.0 * current_std.max(5.0)) || *anomalies >= 3 {
                (
                    DeviationSeverity::Critical,
                    true,
                    format!("افت شدید کیفیت اتصال: تاخیر {:.1}ms با انحراف {:.1}ms از سقف بازه!", actual_value, deviation),
                )
            } else {
                (
                    DeviationSeverity::Warning,
                    false,
                    format!("نوسان کیفیت: تاخیر {:.1}ms خارج از بازه استاندارد [{:.1}, {:.1}]", actual_value, lower_l, upper_u),
                )
            }
        } else {
            if *anomalies > 0 {
                *anomalies -= 1;
            }
            (
                DeviationSeverity::Normal,
                false,
                "رفتار اتصال در محدوده استاندارد و پایدار است.".to_string(),
            )
        };

        BehaviorAnalysisReport {
            sample_count: stats.count(),
            moving_average: stats.mean(),
            standard_deviation: stats.std_dev(),
            expected_range_lower: lower_l,
            expected_range_upper: upper_u,
            actual_measured_value: actual_value,
            deviation_value: deviation,
            severity,
            is_degraded,
            alert_message: alert_msg,
        }
    }
}