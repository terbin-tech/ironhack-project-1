#!/usr/bin/env bash
# Sends two gauges to the CloudWatch agent's StatsD listener (UDP 127.0.0.1:8125):
#   containers_down     containers not running, or running but unhealthy
#   container_restarts  restarts since the previous run
# A systemd timer runs it every minute; the alarms treat a missing minute as a
# dead host, agent or timer.
set -euo pipefail

state=/run/container-metrics.restarts
declare -A previous=()
baseline=false

# RestartCount counts from the container's creation or the daemon's start, so
# the first run after a boot only records counts and reports no restarts.
if [[ -r "${state}" ]]; then
  while read -r id count; do
    previous["${id}"]=${count}
  done <"${state}"
else
  baseline=true
fi

down=0
restarts=0
current=""
while read -r id running health count; do
  if [[ "${running}" != "true" || "${health}" == "unhealthy" ]]; then
    down=$((down + 1))
  fi
  before=${previous["${id}"]:-0}
  # A lower count than last time means Docker restarted: count from zero.
  if ((count < before)); then
    before=0
  fi
  restarts=$((restarts + count - before))
  current+="${id} ${count}"$'\n'
done < <(docker ps --all --quiet | xargs --no-run-if-empty docker inspect --format \
  '{{.Id}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}')

printf '%s' "${current}" >"${state}"
if [[ "${baseline}" == "true" ]]; then
  restarts=0
fi

# Bash sends each write to /dev/udp as one datagram; StatsD gauges are name:value|g.
printf 'containers_down:%d|g\n' "${down}" >/dev/udp/127.0.0.1/8125
printf 'container_restarts:%d|g\n' "${restarts}" >/dev/udp/127.0.0.1/8125
