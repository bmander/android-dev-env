#!/usr/bin/env bash
# Emit "CPU 12%  MEM 43%" for the tmux status line (see /etc/tmux.conf status-right).
# Each call samples its OWN ~0.3s window: read /proc/stat, sleep, read again. Don't diff
# against a shared snapshot between tmux calls — tmux fires status commands many times per
# redraw, so those windows are sub-second and just measure the sampler itself, pinning CPU
# near 100%. tmux runs status commands asynchronously, so the short sleep doesn't block the UI.
set -u

# Echo "<busy> <total>" jiffies from the aggregate (all-cores) /proc/stat cpu line:
#   cpu  user nice system idle iowait irq softirq steal guest guest_nice
cpu_sample() {
  local _ u n s i io irq sq st rest
  read -r _ u n s i io irq sq st rest < /proc/stat
  local idle=$((i + io))
  local total=$((u + n + s + i + io + irq + sq + st))
  echo "$((total - idle)) $total"
}

read -r b1 t1 < <(cpu_sample)
sleep 0.3
read -r b2 t2 < <(cpu_sample)
dt=$((t2 - t1)); db=$((b2 - b1))
cpu=0
(( dt > 0 )) && cpu=$(( (100 * db) / dt ))

# Memory: used% = (MemTotal - MemAvailable) / MemTotal, in one awk pass.
read -r mem < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t>0) printf "%d", (100*(t-a))/t }' /proc/meminfo)

printf 'CPU %s%%  MEM %s%%' "$cpu" "${mem:-?}"
