use serde::Deserialize;
use std::collections::BTreeMap;
use std::time::{Duration, Instant};
#[derive(Debug, Deserialize)]
pub struct Art {
    pub palette: BTreeMap<char, String>,
    pub frames: BTreeMap<String, Vec<String>>,
}
impl Art {
    pub fn load() -> Self {
        serde_json::from_str(include_str!("../../../design/tui/pet/megumin.json"))
            .expect("bundled pet JSON validated")
    }
}
#[derive(Debug)]
pub struct Pet {
    pub enabled: bool,
    pub art: Art,
    pub action: u8,
    pub clicks: u32,
    pub started: Option<Instant>,
    pub quote_until: Option<Instant>,
    pub quote_kind: u8,
    pub visible: bool,
    pub blink_at: Option<Instant>,
    pub blink_seed: u64,
}
impl Default for Pet {
    fn default() -> Self {
        Self {
            enabled: true,
            art: Art::load(),
            action: 0,
            clicks: 0,
            started: None,
            quote_until: None,
            quote_kind: 0,
            visible: false,
            blink_at: None,
            blink_seed: 17,
        }
    }
}
impl Pet {
    pub fn click(&mut self, now: Instant, reduced: bool) {
        if !self.enabled {
            return;
        }
        if self.action == 1 || self.action == 2 {
            return;
        }
        self.started = Some(now);
        self.quote_until = Some(now + Duration::from_millis(2500));
        if self.action == 3 {
            self.action = 0;
            self.quote_kind = 4;
        } else {
            self.clicks += 1;
            self.action = if self.clicks % 2 == 1 {
                1
            } else if reduced {
                3
            } else {
                2
            };
            self.quote_kind = self.action;
        }
    }
    pub fn tick(&mut self, now: Instant, reduced: bool) {
        if !self.visible {
            return;
        }
        if let Some(start) = self.started {
            let elapsed = now.duration_since(start).as_millis();
            if self.action == 1 && elapsed >= 1600 {
                self.action = 0;
            }
            if self.action == 2 && elapsed >= 1970 {
                self.action = 3;
                self.quote_kind = 3;
                self.quote_until = Some(now + Duration::from_millis(2500));
            }
        }
        if reduced {
            return;
        }
        if self.blink_at.is_none() {
            self.blink_seed = self
                .blink_seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1);
            self.blink_at = Some(now + Duration::from_millis(3000 + self.blink_seed % 3001));
        } else if self
            .blink_at
            .is_some_and(|t| now >= t + Duration::from_millis(150))
        {
            self.blink_at = None;
        }
    }
    pub fn frame(&self, now: Instant) -> &str {
        match self.action {
            1 => "pose",
            2 => {
                let ms = self
                    .started
                    .map_or(0, |t| now.duration_since(t).as_millis());
                match ms {
                    0..800 => {
                        if (ms / 200).is_multiple_of(2) {
                            "chant1"
                        } else {
                            "chant2"
                        }
                    }
                    800..920 => "boom1",
                    920..1370 => "boom2",
                    1370..1970 => "boom3",
                    _ => "down",
                }
            }
            3 => "down",
            _ => {
                if self.blink_at.is_some_and(|t| now >= t) {
                    "blink"
                } else {
                    "idle"
                }
            }
        }
    }
    pub fn quote(&self, now: Instant) -> &str {
        if self.quote_until.is_none_or(|t| now >= t) {
            return "";
        }
        match self.quote_kind {
            1 => "「吾名惠惠！」",
            2 => {
                if self
                    .started
                    .is_some_and(|t| now.duration_since(t).as_millis() >= 800)
                {
                    "「Explosion！」"
                } else {
                    "「比黑更黑……」"
                }
            }
            3 => "「……动不了了。」",
            _ => "「明天还要再放一发。」",
        }
    }
}
