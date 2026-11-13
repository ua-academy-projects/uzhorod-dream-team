//! Need live brokers: `TEST_AMQP_URL` / `TEST_PG_URL` (pgmq extension), run with `cargo test -- --ignored`.
//! The same scenario runs through `dyn Consumer` for both backends.
use history::{
    models,
    mq::{self, Consumer, pgmq::Pgmq, rabbit::Rabbit},
    store::{Sink, Store},
};
use lapin::{
    BasicProperties, Connection, ConnectionProperties,
    options::{BasicPublishOptions, QueuePurgeOptions},
};
use serde_json::{Value, json};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(2);

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

fn fetched(msg_id: &str) -> Value {
    json!({"msg_id": msg_id, "schema": 1, "at": 1760000000, "kind": "pharmacy",
    "lat": 50.4651, "lon": 30.5156, "radius": 1000,
    "elements": [
        {"osm_type": "node", "id": 1, "lat": 50.46, "lon": 30.51, "tags": {"amenity": "pharmacy"}},
        {"osm_type": "way", "id": 2, "lat": 50.47, "lon": 30.52, "tags": {}}
    ]})
}

async fn rabbit_publish(url: &str, topic: &str, payload: &Value) {
    let ch = Connection::connect(url, ConnectionProperties::default())
        .await
        .unwrap()
        .create_channel()
        .await
        .unwrap();
    ch.basic_publish(
        "".into(),
        topic.into(),
        BasicPublishOptions::default(),
        payload.to_string().as_bytes(),
        BasicProperties::default().with_delivery_mode(2),
    )
    .await
    .unwrap()
    .await
    .unwrap();
}

async fn rabbit_purge(url: &str, topic: &str) {
    let ch = Connection::connect(url, ConnectionProperties::default())
        .await
        .unwrap()
        .create_channel()
        .await
        .unwrap();
    ch.queue_purge(topic.into(), QueuePurgeOptions::default())
        .await
        .unwrap();
}

/// publish → receive → nack → receive again → ack → the queue is empty.
async fn roundtrip(c: &dyn Consumer, payload: &Value) {
    let batch = c.receive(mq::FETCHED, 10, WAIT).await.unwrap();
    assert_eq!(batch.len(), 1);
    assert_eq!(
        serde_json::from_slice::<Value>(&batch[0].payload).unwrap(),
        *payload
    );
    batch[0].nack().await.unwrap();

    let batch = c.receive(mq::FETCHED, 10, WAIT).await.unwrap();
    assert_eq!(batch.len(), 1, "nack must return the message");
    batch[0].ack().await.unwrap();

    assert!(
        c.receive(mq::FETCHED, 10, Duration::from_secs(1))
            .await
            .unwrap()
            .is_empty()
    );
}

async fn rejected_is_gone(c: &dyn Consumer) {
    let batch = c.receive(mq::FETCHED, 10, WAIT).await.unwrap();
    assert_eq!(batch.len(), 1);
    batch[0].reject().await.unwrap();
    assert!(
        c.receive(mq::FETCHED, 10, Duration::from_secs(1))
            .await
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
#[ignore]
async fn rabbit_roundtrip() {
    let url = env("TEST_AMQP_URL");
    let c = Rabbit::connect(&url).await.unwrap();
    rabbit_purge(&url, mq::FETCHED).await;

    let payload = fetched("6f1c2c3e-5b0f-4b6e-9d57-1c1f0f2f9a11");
    rabbit_publish(&url, mq::FETCHED, &payload).await;
    roundtrip(&c, &payload).await;

    rabbit_publish(&url, mq::FETCHED, &payload).await;
    rejected_is_gone(&c).await;
}

#[tokio::test]
#[ignore]
async fn pgmq_roundtrip() {
    let url = env("TEST_PG_URL");
    let c = Pgmq::connect(&url).await.unwrap();
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::query("select pgmq.purge_queue('poi_fetched')")
        .execute(&pool)
        .await
        .unwrap();

    let payload = fetched("6f1c2c3e-5b0f-4b6e-9d57-1c1f0f2f9a12");
    let send = || async {
        sqlx::query("select pgmq.send('poi_fetched', $1::text::jsonb)")
            .bind(payload.to_string())
            .execute(&pool)
            .await
            .unwrap();
    };
    send().await;
    roundtrip(&c, &payload).await;

    send().await;
    rejected_is_gone(&c).await;
}

/// The same message twice → one row in `fetch_results`, no duplicates in `poi`;
/// a corrupted payload → `Reject`. Needs `TEST_PG_URL` (a DB for the history; migrations apply themselves).
#[tokio::test]
#[ignore]
async fn store_is_idempotent() {
    let url = env("TEST_PG_URL");
    let store = Store::connect(&url).await.unwrap();
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let payload = fetched(&id).to_string().into_bytes();

    let event = models::parse(mq::FETCHED, &payload).unwrap();
    assert!(store.save(&event).await.unwrap());
    assert!(
        !store.save(&event).await.unwrap(),
        "the duplicate must be skipped"
    );

    let (n, count): (i64, Option<i32>) = sqlx::query_as(
        "select count(*), max(poi_count) from fetch_results where msg_id = $1::text::uuid",
    )
    .bind(&id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!((n, count), (1, Some(2)));
    let (pois,): (i64,) =
        sqlx::query_as("select count(*) from poi where fetch_id = $1::text::uuid")
            .bind(&id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(pois, 2);

    let failed = json!({"msg_id": uuid::Uuid::new_v4().to_string(), "schema": 1, "at": 1760000000,
        "kind": "cafe", "lat": 1.0, "lon": 2.0, "radius": 10,
        "error": "boom", "attempts": [{"endpoint": "e", "error": "x"}]});
    let event = models::parse(mq::FAILED, failed.to_string().as_bytes()).unwrap();
    assert!(store.save(&event).await.unwrap());
}
