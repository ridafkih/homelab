# 0016. SigNoz is the only observability backend

## Context

Two stacks ran side by side: Grafana with Loki, Tempo and Prometheus, and SigNoz with ClickHouse. The collector exported every signal to both. Loki kept 14 days of Keeper.sh logs and SigNoz 15. Tempo had no traces. Prometheus scraped only the collector's own metrics. Grafana held four Keeper.sh dashboards and no alerts. Only one token was still in use, Worm's, which is read-only.

## Decision

- The collector exports logs, traces and metrics only to SigNoz. It scrapes its own `:8888` metrics with a `prometheus` receiver, the one job Prometheus used to scrape. The SigNoz exporter keeps the queue and retry limits.
- Grafana, Loki, Tempo and Prometheus are removed from Compose, along with their config files, the `grafana.rida.sh` route and `PROMETHEUS_RETENTION`. The funnel service is now called `otel-funnel`. It keeps the `grafana-funnel` volume, which holds its Tailscale identity.
- Their volumes (`homelab_loki`, `homelab_tempo`, `homelab_prometheus`, `homelab_grafana`) stay on disk, with nothing attached to them, until they are deleted by hand. `homelab_grafana` and `grafana_grafana-data` are still backed up.
- SigNoz retention is 30 days for logs, 30 days for traces and 90 days for metrics. The dashboards are kept as JSON in `apps/observability/signoz/dashboards/`. `apps/observability/signoz/import.sh` applies the retention and creates or updates each dashboard by title. It runs by hand, with an admin API key.

## Consequences

- One backend to query, and one copy of every signal in ClickHouse on the NVMe.
- Retention and dashboards live in SigNoz's own stores (ClickHouse TTLs and its sqlite), not in Compose, so they are applied through the API. The import script is idempotent.
- The Grafana admin credentials are gone from sops, the key table and `grafana.env`.
