import pg from 'pg';
import { Sequelize } from 'sequelize';
import { requireDatabaseUrl } from '../config.js';

const databaseUrl = requireDatabaseUrl();

export const sequelize = new Sequelize(databaseUrl, {
  dialect: 'postgres',
  logging: false,
});

/**
 * The PostgreSQL container is shared with other projects, so the app database
 * may not exist yet (POSTGRES_DB only applies on the container's first start).
 * Connect to the default "postgres" database and create ours if missing.
 */
export async function ensureDatabase() {
  const url = new URL(databaseUrl);
  const dbName = decodeURIComponent(url.pathname.slice(1));
  url.pathname = '/postgres';

  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  try {
    const { rowCount } = await client.query('SELECT 1 FROM pg_database WHERE datname = $1', [dbName]);
    if (rowCount === 0) {
      await client.query(`CREATE DATABASE "${dbName.replace(/"/g, '""')}"`);
      console.log(`Created database "${dbName}"`);
    }
  } finally {
    await client.end();
  }
}
