# Architecture

## Infra overview

```mermaid
flowchart LR
    P["Player"] --> D["DNS<br/>mc.hamishburke.dev"]
    D -->|"asleep"| W["Wake trigger<br/><i>us-east-1</i>"]
    W -->|"start"| S["Minecraft server<br/><i>Auckland</i>"]
    D -->|"awake"| S
    S -->|"idle 20 min"| Z["Stopped<br/><i>storage only</i>"]
    S --- B["Backups<br/><i>S3 + EBS snapshots</i>"]

    classDef box fill:#e9f7ee,stroke:#2e9e5b,color:#000
    classDef dim fill:#f2f2f2,stroke:#888,color:#000
    class D,W,S,B box
    class P,Z dim
```

## Wake and sleep sequence diagram

```mermaid
sequenceDiagram
    autonumber
    participant P as Player
    participant R as Route 53
    participant L as Wake Lambda
    participant E as EC2 instance

    P->>R: resolve mc.hamishburke.dev
    R-->>P: 192.0.2.1 (asleep)
    R->>L: query log → subscription filter (~15s)
    L->>E: StartInstances (~8s)
    E->>R: UPSERT A record → new public IP
    Note over E: Paper accepting connections (~27s)
    P->>E: retry join → connected

    loop every minute
        E->>E: count established TCP conns on 25565
    end
    Note over E: 20 minutes with zero players
    E->>E: save-off, archive world to S3, shutdown -h now
```

Measured end to end at ~50 seconds on 26 July 2026, against a 2-minute
requirement. Most of that is CloudWatch Logs delivery, which isn't tunable.
