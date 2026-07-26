# MCServer

Paper Minecraft server for a small group of friends, hosted in AWS Auckland
(`ap-southeast-6`). The instance sleeps when nobody is playing and wakes itself
when someone tries to join — no Discord bot, no admin, no external tool.

Requirements this implements live in `Daily/Minecraft Server.md` in the Alphero
Notes vault. Solution decision: **Option A1**, recorded there under *Chosen Solution*.

## How it works

```
Player opens Minecraft
   → client resolves mc.hamishburke.dev
      → Route 53 answers, logs the query to CloudWatch Logs (us-east-1)
         (query logging is a property of the hosted zone — there is no
          standalone AWS::Route53::QueryLoggingConfig resource type)
         → subscription filter fires the wake Lambda
            → Lambda calls StartInstances in ap-southeast-6
               → instance boots, publishes its new public IP to Route 53
                  → player refreshes the server list and joins (~60s)

...20 minutes with nobody connected...
   → idle watchdog backs the world up to S3 and runs `shutdown -h now`
      → instance stops, billing drops to storage only
```

Route 53 query logging for a public hosted zone can only write to CloudWatch Logs
in **us-east-1**, which is why the wake machinery is a separate stack in a
separate region from the server itself.

See [docs/architecture.md](docs/architecture.md) for the full resource diagram.

## Prerequisites

1. **An AWS account.** At signup choose the **Paid plan, not the Free plan** —
   the Free plan auto-closes the account after 6 months or when credits run out,
   which would take your world with it. Both plans start with $100 in credits
   (rising to $200 after some onboarding tasks).
2. **`hamishburke.dev`**, which stays on Cloudflare. Only the `mc` subdomain is
   delegated to Route 53 — the existing site is untouched and there is no extra
   domain cost. See step 1 below.
3. **AWS CLI v2**, authenticated against that account. Every `make` target uses
   the `personal` profile by default; override with `make AWS_PROFILE=other ...`.
4. **The Auckland region enabled.** `ap-southeast-6` is an opt-in region and is
   off by default on new accounts:

   ```bash
   aws account enable-region --region-name ap-southeast-6 --profile personal
   aws ec2 describe-regions --all-regions --region us-east-1 --profile personal \
     --query "Regions[?RegionName=='ap-southeast-6'].OptInStatus" --output text
   ```

   Wait for `ENABLED`. This can take a few minutes to several hours, and nothing
   in Auckland can deploy until it does.

## Deploy

### Step 1 — delegate the subdomain (once)

The wake trigger reads Route 53 query logs, which only exist for zones Route 53
is authoritative for. So `mc.hamishburke.dev` becomes its own hosted zone,
delegated from Cloudflare by NS records. The apex and everything else stays on
Cloudflare exactly as it is.

```bash
make deploy-zone            # creates the zone, prints its nameservers
```

In the Cloudflare dashboard for `hamishburke.dev`, add each printed nameserver
as a record:

| Field | Value |
| ----- | ----- |
| Type | `NS` |
| Name | `mc` |
| Nameserver | one of the four `ns-*.awsdns-*` values |
| Proxy status | **DNS only** (grey cloud) |

Four records, one per nameserver. Then:

```bash
make check-delegation       # should return the AWS nameservers
```

Propagation is usually minutes. Don't continue until this returns AWS
nameservers rather than Cloudflare's or nothing.

> **Proxying must stay off.** Minecraft is raw TCP on port 25565, which
> Cloudflare's proxy doesn't carry on any plan below Spectrum. Delegation keeps
> Cloudflare out of the path entirely, which is what we want — but if you ever
> add an `mc` A record directly in Cloudflare instead, orange-cloud it and
> nothing will connect.

### Step 2 — deploy the stacks

```bash
cp infra/params/server.example.json infra/params/server.json
cp infra/params/wake.example.json   infra/params/wake.json
```

From the step 1 output, paste `HostedZoneId` into `server.json` and
`QueryLogGroupName` into `wake.json`, then fill in your email and Minecraft
usernames.

```bash
make deploy-server          # Auckland: VPC, EC2, backups, alerting
make outputs                # copy InstanceId into infra/params/wake.json
make deploy-wake            # us-east-1: wake Lambda, subscription, budget
```

Then confirm the SNS subscription email so alerts actually reach you.

First boot takes a few minutes — it installs Java, resolves the newest Paper
build, and resolves your whitelist usernames against Mojang's API. Watch it with
`make console` then `sudo tail -f /var/log/mc-bootstrap.log`.

## Day-to-day

Easiest way in is the dashboard — one screen, single-key actions, no flags to
remember:

```bash
make tui        # or ./mcctl
```

```
  MINECRAFT SERVER  mc.hamishburke.dev

  Infrastructure
    Zone stack       CREATE_COMPLETE
    Server stack     CREATE_COMPLETE
    Wake stack       CREATE_COMPLETE
    Delegation       ok (4 AWS nameservers)

  Server
    State            running
    Public IP        13.x.x.x
    DNS A record     13.x.x.x

  Cost this month
    Amazon EC2                     USD    1.42
    Amazon S3                      USD    0.11
    total                          USD    1.53   ≈ NZD 3.04 incl GST
```

Keys: `s`/`x` start and stop, `w` add someone to the whitelist, `l` list it,
`b` back up now, `k` list archives, `t` tail the server log, `e` shell in,
`c` load costs, `d` deploy or update stacks, `r` refresh.

It's Python stdlib only — nothing to install — and it shells out to the AWS CLI,
so it inherits the same `personal` profile. It also flags when parameter files
still have placeholders in them.

Cost figures come from Cost Explorer, which charges **$0.01 per query**, so they
load only when you press `c` rather than on every refresh. The NZD figure is
converted at a rate hardcoded near the top of `mcctl` — update it if it drifts.

Everything is also available as plain make targets:

| Command | What it does |
| ------- | ------------ |
| `make status` | Is it awake? What's its current IP? |
| `make start` / `make stop` | Wake or sleep it by hand |
| `make console` | Root shell via Session Manager — no SSH key, no open port 22 |
| `make logs` | Tail the Paper server log |
| `make wake-logs` | Watch the wake Lambda fire while testing |
| `make backup-now` | Force a world archive to S3 |
| `make list-backups` | List world archives |

## Quality-of-life features (US-18)

Installed automatically at boot, all server-side — **vanilla clients need nothing**.

| Feature | Provided by |
| ------- | ----------- |
| `/home`, `/sethome`, `/tpa`, `/back`, `/spawn` | EssentialsX |
| Graves that hold your items where you died | GravesX |
| One player sleeping skips the night | `playersSleepingPercentage` gamerule |

Plugins come from Modrinth, resolved against whatever Minecraft version the
server ends up on, and every download is checksum-verified (sha256 for Paper,
sha512 for plugins).

**Turning things off.** Set `QolPlugins` to an empty string for no plugins at
all, or drop a slug from the list. Set `PlayersSleepingPercentage` to `100` for
vanilla sleep behaviour. Both take effect on the next instance rebuild.

**Permissions.** EssentialsX's player commands default to available-for-everyone
via its `plugin.yml`, so `/home` and `/tpa` work for your friends without a
permissions plugin. `OperatorUsername` gets level-4 op. If you ever need
finer-grained control, that's when to add LuckPerms — not before.

**Minecraft version note.** As of July 2026 Minecraft uses calendar versioning
(`26.1.2`, `26.2`). `MinecraftVersion: latest` resolves to the newest version
with a **STABLE** Paper build, deliberately skipping BETA and ALPHA channels —
so it currently picks `26.1.2`, not `26.2`.

## Server console (RCON)

The server has RCON enabled on `127.0.0.1:25575` with a random password
generated at first boot and stored in `/opt/minecraft/rcon.pass` (mode 600).
Port 25575 is not in the security group, so it's reachable only on the box.

```bash
make console
sudo mc-rcon list
sudo mc-rcon "whitelist add SomeFriend"
sudo mc-rcon "gamerule keepInventory true"
```

This is also what makes backups consistent — `mc-backup.sh` issues `save-off` and
`save-all flush` before archiving, then `save-on`, so you never tar a
half-written region file.

## Cost

Estimated at ~40 hrs/month of play. USD ex GST; AWS NZ adds 15% GST for
individual customers, and NZD/USD was 0.578 in July 2026.

| Component | USD/month |
| --------- | --------- |
| `t4g.medium` compute (~40 hrs) | ~$1.80 |
| EBS gp3 20GB — billed while stopped | ~$2.20 |
| Route 53 hosted zone | $0.50 |
| EBS snapshots (14 × 12-hourly) | ~$0.60 |
| S3 world archives + CloudWatch + Lambda | ~$0.30 |
| **Subtotal** | **~$5.40** |
| **+15% GST → ~NZD** | **~$10.75** |

No domain cost — `hamishburke.dev` is already owned, and only the `mc` subdomain
is delegated. The $0.50 hosted zone charge above covers the delegated zone.

**Storage dominates.** Compute is about a third of the bill; the rest accrues
whether or not anyone plays. Playing twice as much costs about $1.80 more, so
don't optimise play hours — optimise `VolumeSizeGb` if you need this cheaper.

## Design notes

**Why the public IP changes.** No Elastic IP: AWS bills every public IPv4 address
at $0.005/hr *including while attached to a stopped instance*, which would add
~$3.65/month for an address we only need while running. Instead the instance
UPSERTs its own A record on each boot, and the record's TTL is 60s.

**Why the record points at 192.0.2.1 while asleep.** That's TEST-NET-1,
guaranteed unroutable, so the join attempt fails fast rather than hanging. The
failed attempt is what triggers the wake.

**Why Paper and not Vanilla.** US-18 wants `/home`, `/tpa` and graves, which need
plugins. Accepted consequence: some mob-spawning, hopper and redstone behaviour
differs from vanilla, so farm designs from YouTube may not work as filmed.

**Why `shutdown -h now` and not an API call.** `InstanceInitiatedShutdownBehavior`
is `stop`, so the instance halting itself is a clean stop with no IAM permissions
needed for self-termination.

**Two backup mechanisms, deliberately.** EBS snapshots (12-hourly, 14 retained
≈ 7 days) give whole-system rollback per US-04. S3 world archives give a portable
`.tar.gz` you can download and take elsewhere, which is what US-17 actually needs
when the group loses interest.

## Measured behaviour

Verified on the live deployment, 26 July 2026:

| Step | Time |
| ---- | ---- |
| DNS query → wake Lambda fires | ~15s (CloudWatch Logs delivery) |
| Lambda → instance `running` | ~8s |
| Instance running → Minecraft accepting connections | ~27s |
| **Total: lookup → joinable** | **~50s** |

Comfortably inside the 2-minute requirement. Most of the delay is CloudWatch
Logs delivery, which isn't tunable.

## Known gaps

- **No hard spend cap.** Budget alerts only, at 80% actual and 100% forecast.
  Accepted as a soft limit — AWS has no true hard cap without a kill-switch Lambda.
- **DNS caching can delay a wake.** If a player's resolver still has the record
  cached, no query reaches Route 53 and nothing fires. The 60s TTL keeps this
  window small, but a first join can occasionally need a second attempt.
- **Player detection is connection-based.** The watchdog counts established TCP
  connections on 25565 rather than asking the server. Simple and dependency-free,
  but a hung connection could hold the server awake.
- **A stale A record survives stack deletion.** The instance owns the record, not
  CloudFormation, so deleting the server stack leaves the last IP behind in the
  zone. Harmless, but delete it by hand if you want the zone tidy.

## Gotchas found the hard way

Recorded so they aren't rediscovered on the next rebuild:

- **Minecraft 26.1+ requires Java 25.** Corretto 21 fails instantly with a clear
  message. The unit calls the JVM by absolute path to avoid `alternatives`
  ambiguity.
- **Gamerules are snake_case from 26.x.** `playersSleepingPercentage` is silently
  rejected; the correct name is `players_sleeping_percentage`.
- **RCON returns exit 0 even when the server rejects a command.** The only real
  confirmation is the response text, which is why `mc-configure.sh` pattern-matches
  on `"is now set to"` rather than trusting the exit code.
- **PaperMC's v2 API is sunset** (HTTP 410). Use `fill.papermc.io/v3`.
- **DLM policy descriptions only accept `[0-9A-Za-z _-]`** — no commas or parens.
- **Changing UserData does not replace a running EC2 instance.** To re-run the
  bootstrap you must delete and recreate the stack, or patch the box by hand.
- **`AWS::Route53::QueryLoggingConfig` does not exist.** Query logging is a
  property of `AWS::Route53::HostedZone`.
