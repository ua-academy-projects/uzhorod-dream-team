Copy the four `.env` files into `../env/` before provisioning. Replace `OPENAQ_API_KEY` in `fetcher.env` and both password placeholders in `db.env`. Keep the filled files in the ignored `env/` directory.

Use independent random passwords containing only unquoted letters, digits, underscores or hyphens: at least 16 characters for PostgreSQL and 32 for Redis. `openssl rand -hex 32` produces a suitable value. Redis shares the PostgreSQL VM; DB and History provisioning use the same `db.env`.

The example addresses match the default Vagrant topology. Provisioning generates History's database URLs and overwrites service addresses with the configured VM addresses. Provision DB before History.

The UI VM runs Vite's development server. `VITE_API_URL` sets its upstream History URL; browser requests use `/api/v1` on the UI VM and are proxied to History. This allows session cookies while accessing `http://192.168.1.204:5173`. After changing UI source, run `vagrant rsync ui` and `vagrant provision ui --provision-with restart` from the multi-node deployment directory.

The proxy applies to Vite development serving. Static production builds retain direct requests to `VITE_API_URL`; static hosting needs its own same-origin proxy for session cookies with separate VM IPs.
