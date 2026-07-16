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
FROM grafana/grafana:12.4.5@sha256:26b8f35a9e4e4431995cf64c3f396505a4faf17bcfc19f9ed84943ec6bfd5ecd

USER root
# Signed plugins from the Grafana catalog (no unsigned-loading needed). Versions
# pinned to what resolved for Grafana 12.4.5 in the rehearsal (workshop rule:
# everything pinned, no floating "latest").
RUN grafana cli --pluginsDir /opt/grafana-plugins plugins install victoriametrics-metrics-datasource 0.25.2 \
 && grafana cli --pluginsDir /opt/grafana-plugins plugins install victoriametrics-logs-datasource 0.29.0 \
 && chown -R 472:0 /opt/grafana-plugins
USER 472
