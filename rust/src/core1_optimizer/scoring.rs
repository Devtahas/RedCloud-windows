use crate::smart_core_types::ConnectionQualityMetrics;

/// ضرایب وزنی برای فرمول تصمیم‌گیری چندمعیاره (Multi-Criteria Scoring)
pub struct MetricWeights {
    pub latency_weight: f32,       // ضریب پینگ (مثلا 0.30)
    pub jitter_weight: f32,        // ضریب نوسان پینگ (مثلا 0.15)
    pub packet_loss_weight: f32,   // ضریب هدررفت پکت (مثلا 0.25)
    pub handshake_weight: f32,     // ضریب سرعت دست‌دهی لایه ۷ (مثلا 0.15)
    pub stability_weight: f32,     // ضریب پایداری هسته دوم (مثلا 0.15)
}

impl Default for MetricWeights {
    fn default() -> Self {
        Self {
            latency_weight: 0.30,
            jitter_weight: 0.15,
            packet_loss_weight: 0.25,
            handshake_weight: 0.15,
            stability_weight: 0.15,
        }
    }
}

pub struct Core1ScoringEngine;

impl Core1ScoringEngine {
    /// محاسبه امتیاز جامع و علمی بر پایه نرمال‌سازی متغیرهای شبکه
    pub fn evaluate_connection(
        latency_ms: f32,
        jitter_ms: f32,
        packet_loss_ratio: f32, // بین 0.0 تا 1.0
        handshake_time_ms: f32,
        stability_factor: f32,  // بین 0.0 تا 100.0 (از هسته دوم)
    ) -> ConnectionQualityMetrics {
        let weights = MetricWeights::default();

        // 1. امتیاز تاخیر زمانی (Latency Score): هرچه کمتر باشد به 100 نزدیک‌تر است
        let s_lat = (100.0 - (latency_ms / 4.0)).clamp(0.0, 100.0);

        // 2. امتیاز نوسان پینگ (Jitter Score)
        let s_jit = (100.0 - (jitter_ms * 2.0)).clamp(0.0, 100.0);

        // 3. امتیاز پکت‌لاس (Packet Loss Score): پکت‌لاس صفر = امتیاز 100
        let s_loss = ((1.0 - packet_loss_ratio) * 100.0).clamp(0.0, 100.0);

        // 4. امتیاز سرعت هندشیک لایه ۷
        let s_handshake = (100.0 - (handshake_time_ms / 6.0)).clamp(0.0, 100.0);

        // 5. ضریب پایداری
        let s_stab = stability_factor.clamp(0.0, 100.0);

        // محاسبه مجموع وزن‌دار
        let overall = (s_lat * weights.latency_weight)
            + (s_jit * weights.jitter_weight)
            + (s_loss * weights.packet_loss_weight)
            + (s_handshake * weights.handshake_weight)
            + (s_stab * weights.stability_weight);

        ConnectionQualityMetrics {
            latency_ms,
            jitter_ms,
            packet_loss_ratio,
            handshake_time_ms,
            stability_factor,
            overall_score: overall.clamp(0.0, 100.0),
        }
    }
}