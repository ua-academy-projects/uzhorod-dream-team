Copy the four `.env` files into `../env/` and replace `OPENAQ_API_KEY` in `fetcher.env` before provisioning. Keep the filled files in the ignored `env/` directory.

These examples assume browser access through the forwarded localhost ports. PostgreSQL and Redis passwords and History connection URLs are generated on the guest. If using a different browser hostname, update `VITE_API_URL` and `ALLOWED_ORIGINS` accordingly.
