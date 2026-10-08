import config from './config.js';
import { sequelize, ensureDatabase } from './db/index.js';
import app from './app.js';
import './model.js';
import * as history from './service.js';
import { withRetries } from './catchUp.js';
import { connectCache } from './cache.js';
import { connectBroker } from './broker.js';

async function start() {
  // Both connect in the background and keep retrying; the read-only API works without them
  connectCache();
  connectBroker();
  await ensureDatabase();
  await sequelize.authenticate();
  // Demo simplicity: create the table if missing (no migration tooling)
  await sequelize.sync();

  app.listen(config.port, () => {
    console.log(`History service listening on http://localhost:${config.port}`);
    console.log(`Tracking location: ${config.location.name} (${config.location.latitude}, ${config.location.longitude})`);
  });

  // In the background: the API must start even if the broker or the Fetcher isn't up yet
  if (config.catchUpOnStart) {
    withRetries(async () => {
      const result = await history.catchUp();
      console.log(`Startup catch-up: ${result.days} day(s) requested, ${result.fetched} fetched, ${result.inserted} new`);
    });
  }
}

start().catch((err) => {
  console.error('Failed to start History service:', err.message);
  process.exit(1);
});
