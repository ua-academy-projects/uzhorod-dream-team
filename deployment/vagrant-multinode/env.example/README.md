Copy the four `.env` files into `../env/` before provisioning. Replace `OPENAQ_API_KEY` in `fetcher.env` and both password placeholders in `db.env`. Keep the filled files in the ignored `env/` directory.

Use independent random passwords containing only unquoted letters, digits, underscores or hyphens: at least 16 characters for PostgreSQL and 32 for Redis. `openssl rand -hex 32` produces a suitable value. Redis shares the PostgreSQL VM; DB and History provisioning use the same `db.env`.

The example addresses match the default Vagrant topology. Provisioning generates History's database URLs and overwrites service addresses with the configured VM addresses. Provision DB before History.
