use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicU64, Ordering::Relaxed},
};

/// Counters of a single topic; they live as long as the process.
#[derive(Default)]
pub struct TopicStats {
    /// a new message was saved and acknowledged
    pub saved: AtomicU64,
    /// redelivery of an already saved `msg_id`
    pub duplicates: AtomicU64,
    /// transient error, the message was returned to the queue
    pub nacked: AtomicU64,
    /// corrupted or exhausted message, dropped
    pub rejected: AtomicU64,
    /// could neither read the queue nor acknowledge the message
    pub queue_errors: AtomicU64,
}

pub struct Stats(BTreeMap<&'static str, TopicStats>);

impl Stats {
    pub fn new(topics: &[&'static str]) -> Self {
        Self(topics.iter().map(|t| (*t, TopicStats::default())).collect())
    }

    /// Counters of a topic; panics for an unknown topic (topics are fixed at startup).
    pub fn topic(&self, topic: &str) -> &TopicStats {
        self.0
            .get(topic)
            .unwrap_or_else(|| panic!("no stats for topic {topic}"))
    }

    pub fn snapshot(&self) -> Value {
        let topics: BTreeMap<_, _> = self
            .0
            .iter()
            .map(|(topic, s)| {
                (
                    *topic,
                    json!({
                        "saved": s.saved.load(Relaxed),
                        "duplicates": s.duplicates.load(Relaxed),
                        "nacked": s.nacked.load(Relaxed),
                        "rejected": s.rejected.load(Relaxed),
                        "queue_errors": s.queue_errors.load(Relaxed),
                    }),
                )
            })
            .collect();
        json!(topics)
    }
}
