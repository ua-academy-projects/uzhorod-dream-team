# GCP bastion HTTPS

Before provisioning the bastion, set these values in `/etc/kyiv-air/deployment.env`:

```bash
CERTBOT_EMAIL=you@example.com
CERTBOT_DOMAIN=khokhotva.pp.ua
```

`CERTBOT_DOMAIN` defaults to the hostname in `UI_ORIGIN` when omitted.

Create `/etc/kyiv-air/cloudflare.ini`, owned by root with mode `0600`:

```ini
dns_cloudflare_api_token = YOUR_CLOUDFLARE_DNS_API_TOKEN
```

Use a Cloudflare API token with `Zone:DNS:Edit`, restricted to this domain's zone. This is a separate credential from `CLOUDFLARE_TUNNEL_TOKEN` in `cloudflare.env`.

Upload `scripts/renew-certificates.sh` alongside `bastion.sh`, `common.sh`, and `images.env`, and upload the updated `nginx/bastion.conf.template` to `/opt/kyiv-air/nginx/`. Then run:

```bash
sudo bash /opt/kyiv-air/scripts/bastion.sh
```

Provisioning obtains the certificate using the official `certbot/dns-cloudflare` image. Certbot state persists under `/etc/letsencrypt` and `/var/lib/letsencrypt`, with logs under `/var/log/letsencrypt`. The unprivileged NGINX container receives read-only certificate access through a dedicated supplementary group. HTTP on port 80 redirects to `https://CERTBOT_DOMAIN`, preserving the request path and query string. HTTPS is published on port 443 and served inside the container on 8443. The redirect uses status 308 to preserve HTTP methods and request bodies.

The root cron job in `/etc/cron.d/kyiv-air-certbot` runs at 03:17 and 15:17 in the VM's timezone. It starts a temporary Certbot container, restores certificate group permissions, checks NGINX configuration, and reloads NGINX after a successful renewal check. A lock prevents overlapping Certbot runs. No Docker socket is mounted into Certbot.

Test renewal after provisioning:

```bash
sudo /opt/kyiv-air/bin/renew-certificates renew --dry-run
```

Inspect `/var/log/letsencrypt/renewal-cron.log` and `/var/log/letsencrypt/letsencrypt.log` for errors.

In the Cloudflare Tunnel dashboard, change the published application's service URL to `https://kyiv-air-bastion:8443`, set **Origin Server Name** to `khokhotva.pp.ua`, and keep certificate verification enabled. The connector and NGINX share the Docker network, so the route uses the container name and container port. The provisioner does not modify remotely managed tunnel routes.

DNS validation requires outbound HTTPS access to Cloudflare and Let's Encrypt, without inbound validation ports. You do not need to open public ports 80 or 443 for the Tunnel. If other VMs need direct HTTPS access, allow the appropriate sources on TCP 443 in the GCP firewall.
