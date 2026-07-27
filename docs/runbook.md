# Runbook

Day-2 operations. Assumes `make` from the repo root and an authenticated AWS CLI.

## Adding or removing a player (US-07)

The whitelist is seeded at first boot from the stack parameter; after that the
live file is the source of truth. No restart needed:

```bash
make console
sudo mc-rcon "whitelist add SomeFriend"
sudo mc-rcon "whitelist list"
sudo mc-rcon "whitelist remove SomeoneElse"
```

Or from inside the game as an operator: `/whitelist add <name>`.

Website requests appear in `make tui` under **Whitelist requests**. Press `p`
to review one, then approve or reject it. Approval only closes the request after
RCON confirms the player was added (or was already whitelisted); if the server
is asleep, start it first and retry so the request remains pending.

To make it survive a rebuild, also update `WhitelistUsernames` in
`infra/params/server.json`.

## Restoring the world (US-04)

Two paths depending on what went wrong.

### Rollback a few hours — EBS snapshot

```bash
aws ec2 describe-snapshots --region ap-southeast-6 --owner-ids self \
  --query 'sort_by(Snapshots,&StartTime)[-14:].{Id:SnapshotId,When:StartTime}' \
  --output table
```

Then, with the instance stopped: create a volume from the chosen snapshot in the
same AZ, detach `/dev/xvda` from the instance, attach the new volume as
`/dev/xvda`, and start. Snapshots are 12-hourly with 14 retained, so the window
is roughly 7 days at 12-hour granularity.

### Recover just the world — S3 archive

```bash
make list-backups
aws s3 cp s3://<bucket>/worlds/world-<stamp>.tar.gz .
```

Then on the instance: stop `minecraft`, move the existing `world*` directories
aside, extract the archive into `/opt/minecraft/server`, `chown -R minecraft:minecraft`,
start `minecraft`.

**Test this at least once before you need it.** US-04 explicitly requires the
restore path be exercised rather than assumed.

## The server won't wake

Work through in order:

1. `make status` — if it says `running`, the wake worked and the problem is
   elsewhere (check `make logs`).
2. `make wake-logs` — did the Lambda fire at all?
3. If nothing fired, the Minecraft DNS query never reached Route 53. Usually
   resolver caching. Confirm with
   `dig SRV _minecraft._tcp.mc.hamishburke.dev` and
   `dig play.mc.hamishburke.dev` — if both answer without the Lambda logging
   anything, they came from a cache.
4. Check the query log group directly:
   `aws logs tail /aws/route53/<hostname> --region us-east-1 --since 10m`
5. Fall back to `make start`.

## The server won't stay asleep

Check the watchdog:

```bash
make console
sudo systemctl status mc-idle-watchdog.timer
sudo journalctl -t mc-idle --since "2 hours ago"
cat /run/mc-idle-count
ss -Htn state established '( sport = :25565 )'
```

A lingering established connection resets the idle counter every minute. If a
stale connection is holding it awake, restarting `minecraft` clears it.

## Upgrading Minecraft (open decision 4)

1. `make backup-now` and confirm the archive landed.
2. Set `MinecraftVersion` in `infra/params/server.json`.
3. `make deploy-server`.

Changing UserData does **not** re-run the bootstrap on an existing instance —
CloudFormation only replaces the instance if a replacement-triggering property
changes. To force it, either terminate the instance and let the stack recreate
it, or upgrade in place: stop `minecraft`, download the new Paper jar over
`paper.jar`, start it again.

Note `server.properties` is only written on first boot, so in-game config
changes survive. Deliberate.

## Changing plugins (US-18)

Plugins are fetched at first boot from `QolPlugins`, so editing that parameter
alone won't touch a running instance. Either add the jar by hand:

```bash
make console
sudo -u minecraft curl -sfLo /opt/minecraft/server/plugins/Thing.jar <modrinth-url>
sudo systemctl restart minecraft
```

...or update `QolPlugins` in `infra/params/server.json` so a future rebuild picks
it up too. Do both if you want it permanent.

To remove one: delete the jar from `/opt/minecraft/server/plugins/`, restart, and
drop the slug from the parameter.

Only Modrinth slugs work with the automatic path. Check a plugin actually
supports your Minecraft version before adding it:

```bash
curl -s 'https://api.modrinth.com/v2/project/<slug>/version?loaders=%5B%22paper%22%5D' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["game_versions"])'
```

## Gamerules

Applied on every boot by `mc-configure.service`, which waits for RCON then sets
`playersSleepingPercentage`. Change it via the stack parameter, or ad hoc:

```bash
sudo mc-rcon "gamerule playersSleepingPercentage 1"
```

Ad hoc changes persist in `level.dat` but are re-applied from the parameter each
boot, so the parameter wins for that one rule.

## Hibernating for months (US-17)

When the group loses interest:

```bash
make backup-now
make list-backups          # confirm the archive exists
make destroy               # deletes EC2 + EBS; the S3 bucket is retained
```

The `BackupBucket` has `DeletionPolicy: Retain`, so worlds survive stack
deletion. Ongoing cost drops to S3 storage only — cents per month, and lifecycle
rules move archives to Glacier IR after 90 days.

Coming back later: redeploy both stacks, then restore a world archive from S3
before anyone joins. Budget an hour.

## Cost has spiked

1. Cost Explorer, grouped by service, for the current month.
2. Most likely cause is the instance not stopping — check the watchdog as above.
3. `make stop` immediately, then investigate.

There is no automatic kill switch by design (soft limits accepted). Budget alerts
fire at 80% actual and 100% forecast.
