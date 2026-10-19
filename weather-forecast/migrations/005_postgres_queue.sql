-- Existing jobs belong to the RabbitMQ/Redis backend.
ALTER TABLE weather_jobs
    ADD COLUMN IF NOT EXISTS backend TEXT NOT NULL DEFAULT 'rabbitmq_redis'
        CHECK (backend IN ('rabbitmq_redis', 'postgres'));

-- Provisioning enables the extension before applying migrations.
SELECT pgmq.create('weather_requests');
SELECT pgmq.create('weather_responses');
