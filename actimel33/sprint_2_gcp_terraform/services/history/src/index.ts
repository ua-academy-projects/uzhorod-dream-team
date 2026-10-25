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
app.listen(config.port, config.host, (err?: Error) => {
  // Express 5 reports a failed bind here; without this the process would keep
  // consuming the queue with no HTTP at all.
  if (err) throw err;
  console.log(`[history] listening on http://${config.host}:${config.port}`);
  const redisNote = config.backend === 'redis' ? `, redis: ${config.redisUrl}` : '';
  console.log(`[history] backend: ${config.backend}${redisNote}, cache TTL ${config.cacheTtlMs / 1000}s`);
});
