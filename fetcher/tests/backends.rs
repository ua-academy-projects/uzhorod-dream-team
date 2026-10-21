//! Need live brokers: `TEST_AMQP_URL` / `TEST_PG_URL` (pgmq extension), run with `cargo test -- --ignored`.
use fetcher::mq::{self, Queue, pgmq::Pgmq, rabbit::Rabbit};
use lapin::{
    Connection, ConnectionProperties,
    options::{BasicGetOptions, QueuePurgeOptions},
};
use serde_json::{Value, json};

fn env(name: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set"))
}

#[tokio::test]
#[ignore]
async fn rabbit_publishes_to_dotted_queue() {
    let url = env("TEST_AMQP_URL");
    let q = Rabbit::connect(&url).await.unwrap();
    let ch = Connection::connect(&url, ConnectionProperties::default())
        .await
        .unwrap()
        .create_channel()
        .await
        .unwrap();
    ch.queue_purge(mq::FETCHED.into(), QueuePurgeOptions::default())
        .await
        .unwrap();

    q.publish(
        mq::FETCHED,
        json!({"hello": "rabbit"}).to_string().as_bytes(),
    )
    .await
    .unwrap();

    let msg = ch
        .basic_get(mq::FETCHED.into(), BasicGetOptions::default())
        .await
        .unwrap()
        .expect("message in queue");
    assert_eq!(
        serde_json::from_slice::<Value>(&msg.data).unwrap(),
        json!({"hello": "rabbit"})
    );
}

#[tokio::test]
#[ignore]
async fn pgmq_publishes_to_underscored_queue() {
    let url = env("TEST_PG_URL");
    let q = Pgmq::connect(&url).await.unwrap();
    let pool = sqlx::PgPool::connect(&url).await.unwrap();
    sqlx::query("select pgmq.purge_queue('poi_fetched')")
        .execute(&pool)
        .await
        .unwrap();

    q.publish(mq::FETCHED, json!({"hello": "pgmq"}).to_string().as_bytes())
        .await
        .unwrap();

    let (msg,): (String,) =
        sqlx::query_as("select message::text from pgmq.read('poi_fetched', 30, 1)")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&msg).unwrap(),
        json!({"hello": "pgmq"})
    );
}
