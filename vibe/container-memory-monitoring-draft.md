# Container Memory Monitoring Draft (Low Attack Surface)

## Goal
Track host and per-container memory usage with minimal added attack surface.

## Principles
- Keep monitoring endpoints private by default.
- Avoid broad Docker socket exposure.
- Alert externally; avoid exposing dashboards publicly.
- Keep configuration simple and auditable.

## Recommended stack
- node_exporter: host memory + system metrics.
- cAdvisor: per-container memory and cgroup metrics.
- Prometheus: local scraper + rule evaluation.
- Alertmanager: outbound notifications only.
- Optional Grafana: private-only access (VPN or strict allowlist).

## Network and exposure model
- Bind monitoring UIs/ports to localhost only unless there is a strict private network boundary.
- Do not publish cAdvisor directly on public interfaces.
- Keep Prometheus and Alertmanager on internal Docker network.
- If Grafana is used, place behind auth and private ingress.

## Docker socket risk handling
- Preferred: avoid direct Docker socket mounts for monitoring where possible.
- If required by a component, keep socket mount internal-only and read-only.
- Never expose a service that can proxy Docker socket access publicly.

## Baseline alerts (memory)
- Host memory usage > 85% for 10 minutes.
- Any WordPress container RSS > 350 MB for 10 minutes.
- Redis used memory > 80% of maxmemory for 10 minutes.
- OOM kill event detected on host.
- Swap use above expected baseline.

## Suggested thresholds for this project
- Target deployment profile: 2 WordPress + Redis + Astro + Caddy + MariaDB.
- Expected normal footprint: ~0.8 GB to 1.2 GB.
- Practical host recommendation:
  - 2 GB works for current profile.
  - 4 GB preferred when adding control-plane tooling/dashboards.

## Compose overlay draft (hardened)
```yaml
# docker-compose.monitoring.yml
services:
  monitoring-node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: monitoring-node-exporter
    restart: unless-stopped
    command:
      - '--path.rootfs=/host'
    networks:
      - monitoring_net
    ports:
      - '127.0.0.1:9100:9100'
    read_only: true
    volumes:
      - '/:/host:ro,rslave'

  monitoring-cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: monitoring-cadvisor
    restart: unless-stopped
    privileged: true
    networks:
      - monitoring_net
    ports:
      - '127.0.0.1:8080:8080'
    volumes:
      - '/:/rootfs:ro'
      - '/var/run:/var/run:ro'
      - '/sys:/sys:ro'
      - '/var/lib/docker/:/var/lib/docker:ro'

  monitoring-prometheus:
    image: prom/prometheus:v2.54.1
    container_name: monitoring-prometheus
    restart: unless-stopped
    networks:
      - monitoring_net
    ports:
      - '127.0.0.1:9090:9090'
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
    volumes:
      - './ops/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro'
      - './ops/monitoring/alerts.yml:/etc/prometheus/alerts.yml:ro'
      - 'monitoring_prometheus_data:/prometheus'

  monitoring-alertmanager:
    image: prom/alertmanager:v0.27.0
    container_name: monitoring-alertmanager
    restart: unless-stopped
    networks:
      - monitoring_net
    ports:
      - '127.0.0.1:9093:9093'
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
    volumes:
      - './ops/monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro'

  # Optional and disabled by default. If enabled, keep private.
  # monitoring-grafana:
  #   image: grafana/grafana:11.2.2
  #   container_name: monitoring-grafana
  #   restart: unless-stopped
  #   networks:
  #     - monitoring_net
  #   ports:
  #     - '127.0.0.1:3000:3000'
  #   volumes:
  #     - 'monitoring_grafana_data:/var/lib/grafana'

networks:
  monitoring_net:
    driver: bridge

volumes:
  monitoring_prometheus_data:
  # monitoring_grafana_data:
```

## Prometheus scrape config draft
```yaml
# ops/monitoring/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alerts.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['monitoring-alertmanager:9093']

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ['monitoring-node-exporter:9100']

  - job_name: cadvisor
    static_configs:
      - targets: ['monitoring-cadvisor:8080']

  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
```

## Alert rules draft
```yaml
# ops/monitoring/alerts.yml
groups:
  - name: memory-and-oom
    rules:
      - alert: HostMemoryHigh
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) > 0.85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: Host memory usage above 85%
          description: Host memory pressure sustained for 10m.

      - alert: ContainerMemoryHighWordPress
        expr: |
          container_memory_working_set_bytes{container_label_com_docker_compose_service=~"frank|frank2"}
          > 350 * 1024 * 1024
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: WordPress container memory above 350MB
          description: Container {{ $labels.container_label_com_docker_compose_service }} is above threshold.

      - alert: RedisMemoryNearCap
        expr: |
          container_memory_working_set_bytes{container_label_com_docker_compose_service="redis"}
          > 0.80 * 64 * 1024 * 1024
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: Redis memory above 80% of configured 64MB cap
          description: Redis approaching maxmemory baseline.

      - alert: HostSwapInUse
        expr: node_memory_SwapUsed_bytes > 128 * 1024 * 1024
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: Host swap in use
          description: Swap usage sustained beyond expected baseline.

      - alert: ContainerOomEvents
        expr: increase(container_oom_events_total[10m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: OOM kill event detected
          description: At least one container OOM event occurred in last 10m.
```

## Alertmanager route draft
```yaml
# ops/monitoring/alertmanager.yml
route:
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 2h
  receiver: default

receivers:
  - name: default
    # Add email/slack/webhook config here.
```

## Operational playbook
- Weekly:
  - Review max host memory, swap activity, OOM events.
  - Review top container memory consumers.
- After deploys:
  - Compare memory deltas against prior baseline.
- During incidents:
  - Check host memory pressure first.
  - Check WordPress/PHP worker growth and Redis usage.
  - Confirm no recent container restart loops.

## Security checklist
- No monitoring endpoint exposed on 0.0.0.0 unless explicitly required.
- Access to dashboards restricted by VPN and auth.
- Secrets stored in env files or secret manager, not in compose file.
- Monitor images pinned to known versions.
- Keep monitoring services on internal network segment.

## Next implementation step
Create the three config files under `ops/monitoring/` and launch with:

```bash
docker compose -f compose.yml -f docker-compose.monitoring.yml up -d
```
