# Operating the instance

Everything below assumes a shell on the box:

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo -i
cd /opt/tracecat
```

No SSH key needed — the instance has an IAM role for SSM Session Manager.

---

## Where things are

| Path | What |
|---|---|
| `/opt/tracecat/` | Compose stack: `docker-compose.yml`, `.env`, `Caddyfile`, `env.sh` |
| `/opt/tracecat/.env` | **All the secrets.** Back this up. |
| `/etc/tracecat/deploy.env` | What Terraform passed in at boot |
| `/etc/tracecat/READY` | Written only on a successful install |
| `/var/log/tracecat-bootstrap.log` | The whole install, start to finish |
| `/var/log/cloud-init-output.log` | cloud-init's own view, if the bootstrap never started |

## Day to day

```bash
docker compose ps                    # what is running
docker compose logs -f api           # follow one service
docker compose logs --tail=200       # everything, recent
docker compose restart api           # bounce a service
docker compose down                  # stop the stack (volumes survive)
docker compose up -d                 # start it again
```

Check resources when things feel slow — this stack is memory-hungry:

```bash
free -h
docker stats --no-stream
```

If you see containers being OOM-killed, move to a larger `instance_type` and
`terraform apply`. Note that changing the instance type replaces nothing and preserves
the volume, but *any* change to `user_data` replaces the instance entirely and you lose
the database.

## Backups

Two separate things, and the first one matters more.

### The secrets

```bash
sudo cat /opt/tracecat/.env
```

`TRACECAT__SERVICE_KEY`, `TRACECAT__SIGNING_SECRET`, `TRACECAT__DB_ENCRYPTION_KEY` and
`USER_AUTH_SECRET` were generated on this instance and exist nowhere else. They are not
in Terraform state and not in this repository. Without them the database is unreadable
and every webhook breaks. Copy the file into a password manager or a secrets store today.

### The database

```bash
docker compose exec -T postgres_db pg_dump -U postgres postgres | gzip > ~/tracecat-$(date +%F).sql.gz
```

Then get it off the instance:

```bash
aws s3 cp ~/tracecat-$(date +%F).sql.gz s3://your-bucket/tracecat/
```

There is no automated backup here. If the database matters, schedule this.

## Changing the superadmin email after deployment

The address is written into `.env` at first boot, and cloud-init runs only once — so
changing the Terraform variable afterwards replaces the instance and destroys the
database. Edit it in place instead:

```bash
cd /opt/tracecat
sudo sed -i 's|^TRACECAT__AUTH_SUPERADMIN_EMAIL=.*|TRACECAT__AUTH_SUPERADMIN_EMAIL=new@example.com|' .env
sudo docker compose up -d
```

Then update `superadmin_email` in `terraform.tfvars` so a future rebuild matches what you
are actually running — but do **not** apply that change expecting it to take effect in
place. See the warning about `user_data_replace_on_change` under
[Upgrading](#upgrading-tracecat).

An account that has already been created keeps whatever privileges it has; this changes
which address is treated as superadmin on subsequent sign-ups.

## Upgrading Tracecat

Upstream ships a migration script that preserves your existing `.env`:

```bash
cd /opt/tracecat
docker compose down

VERSION=1.0.1     # the tag you are moving to
curl -o env-migration.sh https://raw.githubusercontent.com/TracecatHQ/tracecat/${VERSION}/env-migration.sh
curl -o .env.example  https://raw.githubusercontent.com/TracecatHQ/tracecat/${VERSION}/.env.example
chmod +x env-migration.sh && ./env-migration.sh

curl -o docker-compose.yml https://raw.githubusercontent.com/TracecatHQ/tracecat/${VERSION}/docker-compose.yml
curl -o Caddyfile          https://raw.githubusercontent.com/TracecatHQ/tracecat/${VERSION}/Caddyfile

docker compose up -d
```

Back up `.env` and the database first.

Then update `tracecat_version` in `terraform.tfvars` so a future rebuild matches what you
are actually running. **Do not `terraform apply` expecting an in-place upgrade** —
changing `tracecat_version` changes `user_data`, and `user_data_replace_on_change = true`
means Terraform destroys and recreates the instance, taking the database with it. That
setting is correct (cloud-init only runs on first boot, so an in-place change would do
nothing at all), but it makes the plan output worth reading.

## Going to production

This deployment is fine for evaluating Tracecat in your own account. Before it handles
anything real:

1. **Put TLS in front of it.** Get a domain, point it at the Elastic IP, set
   `app_hostname`, and configure Caddy for automatic HTTPS. Modern browsers restrict
   features on plain HTTP, and Tracecat's docs warn against HTTP-only on a public domain.
2. **Replace the default auth with SSO.** Email and password is a starting point;
   Tracecat supports OIDC and SAML.
3. **Move PostgreSQL off the instance.** The compose stack runs its own database on the
   same box as everything else. RDS gives you managed backups and point-in-time recovery.
4. **Narrow `allowed_cidrs` further**, or put the instance behind a load balancer or VPN
   rather than exposing it directly.
5. **Set up real backups and monitoring.** Neither exists here.

## Stopping to save money

```bash
aws ec2 stop-instances --instance-ids $(terraform output -raw instance_id)
aws ec2 start-instances --instance-ids $(terraform output -raw instance_id)
```

The Elastic IP keeps the address stable across a stop/start, which is exactly why it is
allocated — Tracecat's `.env` has the address baked in. The containers come back on their
own: Docker's service is enabled at boot, and upstream sets `restart: unless-stopped` on
every long-running service in the compose file (the one-shot `migrations` service is
correctly `restart: "no"`).

A stopped instance still incurs a small charge for the attached Elastic IP and for the
EBS volume.

## Teardown

```bash
terraform destroy
```

Everything goes, including the database. Back up first if that matters.
