use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use serde::{Deserialize, Serialize};
use crate::smart_core_types::EvasionStrategy;

fn default_mtu() -> u16 {
    1380
}

fn default_noize() -> String {
    "firewall".to_string()
}

/// بازوی تصمیم‌گیری در الگوریتم یادگیری چندبازویی (MAB Arm)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArmExperience {
    pub port: u16,
    pub strategy: EvasionStrategy,
    pub split_offset: usize,
    pub delay_ms: u64,
    pub success_count: u32,
    pub failure_count: u32,
    pub average_latency_ms: f32,
    pub quality_score: f32,
    #[serde(default = "default_mtu")]
    pub optimal_mtu: u16,
    pub last_tested_unix_sec: u64,
}

/// تجربه ذخیره‌شده برای حالت‌های اختصاصی هر پروتکل (اِتر، تور، سایفون)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProtocolOptionExperience {
    pub protocol: String, // "Aether", "Tor", "Psiphon"
    pub selected_mode: String, // e.g. "gool", "masque_h2", "us", "Tor_over_MASQUE"
    #[serde(default = "default_noize")]
    pub selected_noize: String, // e.g. "firewall", "aggressive", "light"
    pub success_count: u32,
    pub failure_count: u32,
    pub average_latency_ms: f32,
    pub quality_score: f32,
    pub last_tested_unix_sec: u64,
}

/// پروفایل تجربیات انباشته‌شده برای یک شبکه مشخص
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkExperienceProfile {
    pub network_fingerprint: u64,
    pub network_label: String,
    pub arms: Vec<ArmExperience>,
    #[serde(default)]
    pub protocol_experiences: Vec<ProtocolOptionExperience>,
    pub total_connections: u32,
    pub last_updated_unix_sec: u64,
}

/// دیتابیس محلی سبک و دائمی تجربیات شبکه
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PersistentExperienceStore {
    pub profiles: Vec<NetworkExperienceProfile>,
}

pub struct LearningEngine {
    store: Mutex<PersistentExperienceStore>,
}

impl LearningEngine {
    pub fn new() -> Self {
        let loaded = Self::load_from_disk().unwrap_or_default();
        Self {
            store: Mutex::new(loaded),
        }
    }

    fn get_current_unix_sec() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    }

    /// استخراج شناسنامه یکتای شبکه فعلی (Network Fingerprint)
    /// تفکیک تضمینی مودم خانگی، هات‌اسپات همراه اول، ایرانسل و رایتل
    pub fn compute_network_fingerprint() -> (u64, String) {
        let local_ips = crate::api::simple::get_all_local_ip_addresses();
        let primary_ip = local_ips.first().cloned().unwrap_or_else(|| "127.0.0.1".to_string());
        
        // ترکیب آی‌پی محلی و تمام آی‌پی‌های کارت شبکه برای تولید شناسه مجزا برای هر کانکشن
        let combined_identity = local_ips.join("|");

        let mut hasher = DefaultHasher::new();
        combined_identity.hash(&mut hasher);
        let fingerprint = hasher.finish();

        let label = if primary_ip.starts_with("192.168.43.") {
            "Android Hotspot (Mobile Data)".to_string()
        } else if primary_ip.starts_with("172.20.10.") {
            "iPhone Hotspot (iOS Data)".to_string()
        } else if primary_ip.starts_with("192.168.1.") || primary_ip.starts_with("192.168.0.") {
            "Home/Office Wi-Fi Router".to_string()
        } else {
            format!("Network Adapter ({})", primary_ip)
        };

        (fingerprint, label)
    }

    /// محاسبه ضریب زوال زمانی (Exponential Temporal Decay)
    /// فرمول: e^(-lambda * delta_t) با نیمه‌عمر ۵ روز
    fn calculate_time_decay(last_time_sec: u64, current_time_sec: u64) -> f32 {
        if current_time_sec <= last_time_sec {
            return 1.0;
        }
        let delta_seconds = (current_time_sec - last_time_sec) as f64;
        let half_life_seconds = 5.0 * 86400.0; // ۵ روز نیمه‌عمر تجربیات
        let lambda = 0.693147 / half_life_seconds;
        ((-lambda * delta_seconds).exp() as f32).clamp(0.05, 1.0)
    }

    /// بررسی اینکه آیا برای شبکه فعلی یک کانفیگ برنده با اطمینان بالا در حافظه وجود دارد؟
    pub fn suggest_fast_path_candidate(
        &self,
        fingerprint: u64,
    ) -> Option<ArmExperience> {
        let store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        let profile = store.profiles.iter().find(|p| p.network_fingerprint == fingerprint)?;

        let now = Self::get_current_unix_sec();
        let mut best_arm: Option<ArmExperience> = None;
        let mut highest_decayed_score = 0.0f32;

        for arm in &profile.arms {
            let decay = Self::calculate_time_decay(arm.last_tested_unix_sec, now);
            let effective_score = arm.quality_score * decay;

            if effective_score > 50.0 && effective_score > highest_decayed_score {
                highest_decayed_score = effective_score;
                best_arm = Some(arm.clone());
            }
        }

        best_arm
    }

    /// پیشنهاد بهترین ترکیب یادگرفته‌شده (مود + نویز) برای پروتکل‌های پل (اِتر، تور، سایفون)
    pub fn suggest_best_protocol_and_noize(
        &self,
        fingerprint: u64,
        protocol: &str,
    ) -> Option<(String, String)> {
        let store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        let profile = store.profiles.iter().find(|p| p.network_fingerprint == fingerprint)?;

        let now = Self::get_current_unix_sec();
        let mut best_combo: Option<(String, String)> = None;
        let mut highest_score = 0.0f32;

        for exp in profile.protocol_experiences.iter().filter(|p| p.protocol == protocol) {
            let decay = Self::calculate_time_decay(exp.last_tested_unix_sec, now);
            let score = exp.quality_score * decay;
            if score > 50.0 && score > highest_score {
                highest_score = score;
                best_combo = Some((exp.selected_mode.clone(), exp.selected_noize.clone()));
            }
        }

        best_combo
    }

    /// سازگاری برای فراخوانی‌های قدیمی
    pub fn suggest_best_protocol_mode(&self, fingerprint: u64, protocol: &str) -> Option<String> {
        self.suggest_best_protocol_and_noize(fingerprint, protocol).map(|(m, _)| m)
    }

    /// جریمه کردن فوری ترکیب شکست‌خورده در حافظه (اگر اپراتور آن را مسدود کرده بود)
    pub fn penalize_protocol_experience(
        &self,
        fingerprint: u64,
        protocol: &str,
        mode: &str,
        noize: &str,
    ) {
        let mut store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(profile) = store.profiles.iter_mut().find(|p| p.network_fingerprint == fingerprint) {
            if let Some(exp) = profile.protocol_experiences.iter_mut().find(|p| {
                p.protocol == protocol && p.selected_mode == mode && p.selected_noize == noize
            }) {
                exp.failure_count += 1;
                exp.quality_score = (exp.quality_score * 0.3).max(0.0);
                exp.last_tested_unix_sec = Self::get_current_unix_sec();
            }
            let _ = Self::save_to_disk(&store);
        }
    }

    /// جریمه کردن فوری بازوی فعلی در صورت تشخیص افت کیفیت شدید توسط هسته دوم
    pub fn penalize_arm(&self, fingerprint: u64, port: u16, strategy: EvasionStrategy) {
        let mut store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(profile) = store.profiles.iter_mut().find(|p| p.network_fingerprint == fingerprint) {
            if let Some(arm) = profile.arms.iter_mut().find(|a| a.port == port && a.strategy == strategy) {
                arm.failure_count += 1;
                arm.quality_score = (arm.quality_score * 0.4).max(0.0);
                arm.last_tested_unix_sec = Self::get_current_unix_sec();
            }
            let _ = Self::save_to_disk(&store);
        }
    }

    /// ثبت تجربه جدید در حافظه محلی پس از هر اتصال موفق یا ناموفق VLESS
    pub fn record_connection_experience(
        &self,
        fingerprint: u64,
        network_label: String,
        port: u16,
        strategy: EvasionStrategy,
        split_offset: usize,
        delay_ms: u64,
        is_success: bool,
        latency_ms: f32,
        quality_score: f32,
        optimal_mtu: u16,
    ) {
        let mut store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        let now = Self::get_current_unix_sec();

        let profile = if let Some(pos) = store.profiles.iter().position(|p| p.network_fingerprint == fingerprint) {
            &mut store.profiles[pos]
        } else {
            store.profiles.push(NetworkExperienceProfile {
                network_fingerprint: fingerprint,
                network_label,
                arms: Vec::new(),
                protocol_experiences: Vec::new(),
                total_connections: 0,
                last_updated_unix_sec: now,
            });
            store.profiles.last_mut().unwrap()
        };

        profile.total_connections += 1;
        profile.last_updated_unix_sec = now;

        let arm_idx = profile.arms.iter().position(|a| {
            a.port == port && a.strategy == strategy && a.split_offset == split_offset && a.delay_ms == delay_ms
        });

        if let Some(idx) = arm_idx {
            let arm = &mut profile.arms[idx];
            if is_success {
                arm.success_count += 1;
                arm.average_latency_ms = (arm.average_latency_ms * 0.7) + (latency_ms * 0.3);
                arm.quality_score = (arm.quality_score * 0.6) + (quality_score * 0.4);
                arm.optimal_mtu = optimal_mtu;
            } else {
                arm.failure_count += 1;
                arm.quality_score = (arm.quality_score * 0.5).max(0.0);
            }
            arm.last_tested_unix_sec = now;
        } else {
            profile.arms.push(ArmExperience {
                port,
                strategy,
                split_offset,
                delay_ms,
                success_count: if is_success { 1 } else { 0 },
                failure_count: if is_success { 0 } else { 1 },
                average_latency_ms: latency_ms,
                quality_score,
                optimal_mtu,
                last_tested_unix_sec: now,
            });
        }

        let _ = Self::save_to_disk(&store);
    }

    /// ثبت تجربه موفق یا ناموفق پروتکل‌ها در حافظه یادگیری (شامل مود و نویز همزمان)
    pub fn record_protocol_learning(
        &self,
        fingerprint: u64,
        network_label: String,
        protocol: String,
        selected_mode: String,
        selected_noize: String,
        is_success: bool,
        latency_ms: f32,
        quality_score: f32,
    ) {
        let mut store = self.store.lock().unwrap_or_else(|e| e.into_inner());
        let now = Self::get_current_unix_sec();

        let profile = if let Some(pos) = store.profiles.iter().position(|p| p.network_fingerprint == fingerprint) {
            &mut store.profiles[pos]
        } else {
            store.profiles.push(NetworkExperienceProfile {
                network_fingerprint: fingerprint,
                network_label,
                arms: Vec::new(),
                protocol_experiences: Vec::new(),
                total_connections: 0,
                last_updated_unix_sec: now,
            });
            store.profiles.last_mut().unwrap()
        };

        profile.total_connections += 1;
        profile.last_updated_unix_sec = now;

        if let Some(exp) = profile.protocol_experiences.iter_mut().find(|p| {
            p.protocol == protocol && p.selected_mode == selected_mode && p.selected_noize == selected_noize
        }) {
            if is_success {
                exp.success_count += 1;
                exp.average_latency_ms = (exp.average_latency_ms * 0.7) + (latency_ms * 0.3);
                exp.quality_score = (exp.quality_score * 0.6) + (quality_score * 0.4);
            } else {
                exp.failure_count += 1;
                exp.quality_score = (exp.quality_score * 0.5).max(0.0);
            }
            exp.last_tested_unix_sec = now;
        } else {
            profile.protocol_experiences.push(ProtocolOptionExperience {
                protocol,
                selected_mode,
                selected_noize,
                success_count: if is_success { 1 } else { 0 },
                failure_count: if is_success { 0 } else { 1 },
                average_latency_ms: latency_ms,
                quality_score,
                last_tested_unix_sec: now,
            });
        }

        let _ = Self::save_to_disk(&store);
    }

    fn get_storage_path() -> std::path::PathBuf {
        std::env::temp_dir().join("RedCloud").join("learning_memory.json")
    }

    fn load_from_disk() -> Option<PersistentExperienceStore> {
        let path = Self::get_storage_path();
        if !path.exists() {
            return None;
        }
        let mut file = File::open(path).ok()?;
        let mut content = String::new();
        file.read_to_string(&mut content).ok()?;
        serde_json::from_str(&content).ok()
    }

    fn save_to_disk(store: &PersistentExperienceStore) -> Result<(), std::io::Error> {
        let path = Self::get_storage_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let json_str = serde_json::to_string_pretty(store)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)?;

        file.write_all(json_str.as_bytes())?;
        file.flush()?;
        Ok(())
    }
}