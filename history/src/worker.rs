use crate::{
    models,
    mq::{Consumer, Delivery},
    stats::Stats,
    store::Sink,
};
use std::{sync::Arc, sync::atomic::Ordering::Relaxed, time::Duration};
use tokio::sync::watch;

/// After this many deliveries a message that cannot be saved is dropped (pgmq only,
/// where `attempt` is known; in RabbitMQ it keeps cycling until the DB recovers).
pub const MAX_ATTEMPTS: u32 = 5;
const BATCH: usize = 10;
const POLL_WAIT: Duration = Duration::from_secs(5);
const MIN_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// saved → ack
    Saved,
    /// `msg_id` is already in the DB → ack
    Duplicate,
    /// transient error → nack
    Nack,
    /// poison/exhausted → reject
    Reject,
}

/// Saves the message and decides what to do with it in the queue. Ack only after the commit.
pub async fn process(sink: &dyn Sink, d: &Delivery) -> Outcome {
    let event = match models::parse(&d.topic, &d.payload) {
        Ok(event) => event,
        Err(e) => {
            // permanent error: redelivery won't help
            tracing::error!(topic = %d.topic, "bad message, rejecting: {e:#}");
            return Outcome::Reject;
        }
    };
    let msg_id = event.msg_id();
    match sink.save(&event).await {
        Ok(true) => {
            tracing::debug!(topic = %d.topic, %msg_id, "saved");
            Outcome::Saved
        }
        Ok(false) => {
            tracing::info!(topic = %d.topic, %msg_id, "duplicate, skipping");
            Outcome::Duplicate
        }
        Err(e) if d.attempt.is_some_and(|n| n > MAX_ATTEMPTS) => {
            tracing::error!(topic = %d.topic, %msg_id, attempt = ?d.attempt, "giving up: {e:#}");
            Outcome::Reject
        }
        Err(e) => {
            tracing::warn!(topic = %d.topic, %msg_id, attempt = ?d.attempt, "save failed, will retry: {e:#}");
            Outcome::Nack
        }
    }
}

/// Loop for one topic: `receive` → `process` → ack/nack/reject until the stop signal arrives.
/// Finishes the current batch.
pub async fn run(
    consumer: Arc<dyn Consumer>,
    sink: Arc<dyn Sink>,
    stats: Arc<Stats>,
    topic: &'static str,
    stop: watch::Receiver<bool>,
) {
    let counters = stats.topic(topic);
    let mut backoff = MIN_BACKOFF;
    while !*stop.borrow() {
        let batch = match consumer.receive(topic, BATCH, POLL_WAIT).await {
            Ok(batch) => {
                backoff = MIN_BACKOFF;
                batch
            }
            Err(e) => {
                counters.queue_errors.fetch_add(1, Relaxed);
                tracing::error!(topic, "receive failed: {e:#}");
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(MAX_BACKOFF);
                continue;
            }
        };
        let mut retry = false;
        for d in &batch {
            let outcome = process(sink.as_ref(), d).await;
            let (counter, res) = match outcome {
                Outcome::Saved => (&counters.saved, d.ack().await),
                Outcome::Duplicate => (&counters.duplicates, d.ack().await),
                Outcome::Nack => (&counters.nacked, d.nack().await),
                Outcome::Reject => (&counters.rejected, d.reject().await),
            };
            counter.fetch_add(1, Relaxed);
            if let Err(e) = res {
                // the message will come back by itself, the duplicate is absorbed by idempotency
                counters.queue_errors.fetch_add(1, Relaxed);
                tracing::error!(topic, ?outcome, "ack failed: {e:#}");
            }
            retry |= outcome == Outcome::Nack;
        }
        if retry {
            // do not spin a tight loop while the DB is unavailable
            tokio::time::sleep(MIN_BACKOFF).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        models::Event,
        mq::{Acker, FAILED, FETCHED},
    };
    use anyhow::{Result, anyhow};
    use serde_json::json;
    use std::{collections::VecDeque, sync::Mutex};

    type Log = Arc<Mutex<Vec<String>>>;

    /// Writes `"<action>:<id>"` to the journal.
    struct FakeAcker {
        id: &'static str,
        log: Log,
        fail: bool,
    }

    #[async_trait::async_trait]
    impl Acker for FakeAcker {
        async fn ack(&self) -> Result<()> {
            self.record("ack")
        }
        async fn nack(&self) -> Result<()> {
            self.record("nack")
        }
        async fn reject(&self) -> Result<()> {
            self.record("reject")
        }
    }

    impl FakeAcker {
        fn record(&self, what: &str) -> Result<()> {
            self.log.lock().unwrap().push(format!("{what}:{}", self.id));
            if self.fail {
                Err(anyhow!("broker gone"))
            } else {
                Ok(())
            }
        }
    }

    /// `save` answers are returned in order; once they run out — `Ok(true)`.
    struct FakeSink(Mutex<VecDeque<Result<bool>>>);

    impl FakeSink {
        fn new(replies: impl IntoIterator<Item = Result<bool>>) -> Arc<Self> {
            Arc::new(Self(Mutex::new(replies.into_iter().collect())))
        }
    }

    #[async_trait::async_trait]
    impl Sink for FakeSink {
        async fn save(&self, _: &Event) -> Result<bool> {
            self.0.lock().unwrap().pop_front().unwrap_or(Ok(true))
        }
        async fn ping(&self) -> Result<()> {
            Ok(())
        }
    }

    /// The first answer is the given batch (or an error), after that it sets stop and returns an empty `Vec`.
    struct FakeConsumer {
        first: Mutex<Option<Result<Vec<Delivery>>>>,
        stop: watch::Sender<bool>,
    }

    #[async_trait::async_trait]
    impl Consumer for FakeConsumer {
        async fn receive(&self, _: &str, _: usize, _: Duration) -> Result<Vec<Delivery>> {
            let first = self.first.lock().unwrap().take();
            match first {
                Some(res) => res,
                None => {
                    self.stop.send(true).unwrap();
                    Ok(vec![])
                }
            }
        }
    }

    fn payload(msg_id: &str) -> Vec<u8> {
        json!({"msg_id": msg_id, "schema": 1, "at": 1760000000, "kind": "cafe",
               "lat": 1.0, "lon": 2.0, "radius": 10, "elements": []})
        .to_string()
        .into_bytes()
    }

    const ID: &str = "6f1c2c3e-5b0f-4b6e-9d57-1c1f0f2f9a11";

    fn delivery(id: &'static str, payload: Vec<u8>, attempt: Option<u32>, log: &Log) -> Delivery {
        let acker = FakeAcker {
            id,
            log: log.clone(),
            fail: false,
        };
        Delivery::new(FETCHED, payload, attempt, acker)
    }

    async fn outcome(
        replies: Vec<Result<bool>>,
        payload: Vec<u8>,
        attempt: Option<u32>,
    ) -> Outcome {
        let log = Log::default();
        process(
            FakeSink::new(replies).as_ref(),
            &delivery("x", payload, attempt, &log),
        )
        .await
    }

    #[tokio::test]
    async fn new_message_is_saved() {
        assert_eq!(
            outcome(vec![Ok(true)], payload(ID), Some(1)).await,
            Outcome::Saved
        );
    }

    #[tokio::test]
    async fn duplicate_is_acked_not_reinserted() {
        assert_eq!(
            outcome(vec![Ok(false)], payload(ID), None).await,
            Outcome::Duplicate
        );
    }

    #[tokio::test]
    async fn garbage_and_unknown_schema_are_rejected_without_touching_the_sink() {
        let sink = FakeSink::new([Err(anyhow!("must not be called"))]);
        let log = Log::default();
        let mut wrong_schema: serde_json::Value = serde_json::from_slice(&payload(ID)).unwrap();
        wrong_schema["schema"] = json!(2);
        for bad in [b"not json".to_vec(), wrong_schema.to_string().into_bytes()] {
            let d = delivery("x", bad, Some(1), &log);
            assert_eq!(process(sink.as_ref(), &d).await, Outcome::Reject);
        }
        assert_eq!(sink.0.lock().unwrap().len(), 1, "sink must not be called");
    }

    #[tokio::test]
    async fn storage_error_is_retried() {
        let err = || vec![Err(anyhow!("db down"))];
        assert_eq!(outcome(err(), payload(ID), Some(1)).await, Outcome::Nack);
        assert_eq!(
            outcome(err(), payload(ID), Some(MAX_ATTEMPTS)).await,
            Outcome::Nack
        );
        // RabbitMQ does not know attempt — we never give up
        assert_eq!(outcome(err(), payload(ID), None).await, Outcome::Nack);
    }

    #[tokio::test]
    async fn storage_error_after_max_attempts_is_rejected() {
        let err = vec![Err(anyhow!("db down"))];
        assert_eq!(
            outcome(err, payload(ID), Some(MAX_ATTEMPTS + 1)).await,
            Outcome::Reject
        );
    }

    fn start(
        first: Result<Vec<Delivery>>,
        sink: Arc<FakeSink>,
    ) -> (impl Future<Output = ()>, Arc<Stats>) {
        let (stop_tx, stop_rx) = watch::channel(false);
        let consumer = Arc::new(FakeConsumer {
            first: Mutex::new(Some(first)),
            stop: stop_tx,
        });
        let stats = Arc::new(Stats::new(&[FETCHED, FAILED]));
        let fut = run(consumer, sink, stats.clone(), FETCHED, stop_rx);
        (fut, stats)
    }

    #[tokio::test(start_paused = true)]
    async fn run_acks_rejects_and_nacks_a_batch_then_stops() {
        let log = Log::default();
        let batch = vec![
            delivery("ok", payload(ID), Some(1), &log),
            delivery("bad", b"nope".to_vec(), Some(1), &log),
            delivery("err", payload(ID), Some(1), &log),
            delivery("dup", payload(ID), Some(1), &log),
        ];
        let sink = FakeSink::new([Ok(true), Err(anyhow!("db down")), Ok(false)]);
        let (fut, stats) = start(Ok(batch), sink);

        fut.await; // finishes by itself: the second `receive` sets stop

        assert_eq!(
            *log.lock().unwrap(),
            ["ack:ok", "reject:bad", "nack:err", "ack:dup"]
        );
        let s = stats.topic(FETCHED);
        assert_eq!(
            [
                &s.saved,
                &s.duplicates,
                &s.nacked,
                &s.rejected,
                &s.queue_errors
            ]
            .map(|c| c.load(Relaxed)),
            [1, 1, 1, 1, 0]
        );
        assert_eq!(
            stats.topic(FAILED).saved.load(Relaxed),
            0,
            "counters are per topic"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn run_survives_receive_errors() {
        let (fut, stats) = start(Err(anyhow!("broker gone")), FakeSink::new([]));
        fut.await;
        assert_eq!(stats.topic(FETCHED).queue_errors.load(Relaxed), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn failed_ack_is_counted_but_does_not_stop_the_worker() {
        let log = Log::default();
        let acker = FakeAcker {
            id: "a",
            log: log.clone(),
            fail: true,
        };
        let batch = vec![
            Delivery::new(FETCHED, payload(ID), Some(1), acker),
            delivery("b", payload(ID), Some(1), &log),
        ];
        let (fut, stats) = start(Ok(batch), FakeSink::new([]));
        fut.await;
        assert_eq!(*log.lock().unwrap(), ["ack:a", "ack:b"]);
        assert_eq!(stats.topic(FETCHED).queue_errors.load(Relaxed), 1);
    }
}
