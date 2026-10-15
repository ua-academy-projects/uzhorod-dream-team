import express from 'express';
import cors from 'cors';
import { sequelize } from './db/index.js';
import { FetcherError } from './fetcherClient.js';
import historyRoutes from './routes.js';
import preferencesRoutes from './preferences.js';
import config from './config.js';
import { cache } from './cache/index.js';
import { isBrokerReady } from './broker/index.js';

const app = express();

app.use(cors());
app.use(express.json());

const backend = config.useRedisRabbitMQ ? 'redis-rabbitmq' : 'postgres';
const up = (ready) => (ready ? 'up' : 'down');

app.get('/api/health', async (req, res) => {
  const services = () => ({ cache: up(cache.isReady), broker: up(isBrokerReady()), backend });
  try {
    await sequelize.authenticate();
    res.json({ status: 'ok', database: 'up', ...services() });
  } catch {
    res.status(503).json({ status: 'degraded', database: 'down', ...services() });
  }
});

app.use('/api/weather', historyRoutes);
app.use('/api/preferences', preferencesRoutes);

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  if (err instanceof FetcherError) {
    console.error(err.message);
    return res.status(502).json({ error: 'Failed to fetch data from weather API' });
  }
  const status = err.status || (err instanceof RangeError ? 400 : 500);
  if (status >= 500) console.error(err);
  res.status(status).json({ error: status >= 500 ? 'Internal server error' : err.message });
});

export default app;
