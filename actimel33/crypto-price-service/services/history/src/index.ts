import { config } from './config.ts';
import { bootstrap } from './core/price-service.ts';
import { runMigrations } from './db/migrate.ts';
import { createApp } from './http/app.ts';
import { queue } from './queue/index.ts';

const applied = await runMigrations();
console.log(
  applied.length > 0
    ? `[history] migrations applied: ${applied.join(', ')}`
    : '[history] migrations: up to date',
);

await queue.startConsumer();
await bootstrap();

const app = await createApp();
app.listen(config.port, config.host, () => {
  console.log(`[history] listening on http://${config.host}:${config.port}`);
  console.log(`[history] queue: ${config.queueDriver}, redis: ${config.redisUrl}, cache TTL ${config.cacheTtlMs / 1000}s`);
});
