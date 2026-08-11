# Custom Grafana (#65): the native VictoriaMetrics datasource plugins baked in
# at BUILD time. The offline rule bans fetching plugins at boot, so we install
# them here (CI / in-cluster BuildKit have internet during the build) and ship a
# self-contained image. Result: the full MetricsQL + LogsQL query editors in
# Grafana Explore instead of the Prometheus / Loki compatibility shims.
#
# Plugins go in /opt/grafana-plugins, NOT the default /var/lib/grafana/plugins —
# the Deployment mounts an emptyDir over /var/lib/grafana (for grafana.db), which
# would shadow anything baked into the default dir. The Deployment sets
# GF_PATHS_PLUGINS=/opt/grafana-plugins so Grafana loads them from here (read-only
# is fine — Grafana only reads plugins).
#
# NB: VictoriaTraces has no signed Grafana datasource plugin yet, so traces stay
# on the built-in Jaeger datasource (now with the per-trace Node Graph enabled).
FROM grafana/grafana:13.1.3@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43

USER root
# Signed plugins from the Grafana catalog (no unsigned-loading needed). Versions
# pinned to what resolved for Grafana 13.1.3 in the rehearsal (workshop rule:
# everything pinned, no floating "latest").
#
# Both are re-checked against Grafana's plugin catalog on every bump:
#   metrics 0.25.2 is the newest release, and its grafanaDependency's last term
#     (">=12.2.5", no upper bound) covers 13.x.
#   logs 0.29.0 is held deliberately — 0.30.1/0.31.0 exist, all declare
#     grafanaDependency ">=10.4.0", so any of them would install. Holding keeps
#     the Grafana major bump a one-variable change; both plugins verified
#     `signature: valid, angularDetected: false` on 13.1.3.
RUN grafana cli --pluginsDir /opt/grafana-plugins plugins install victoriametrics-metrics-datasource 0.25.2 \
 && grafana cli --pluginsDir /opt/grafana-plugins plugins install victoriametrics-logs-datasource 0.29.0 \
 && chown -R 472:0 /opt/grafana-plugins
USER 472
