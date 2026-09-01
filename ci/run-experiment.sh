#!/bin/bash
# Fully autonomous Qubes nested-KVM experiment driver (runs ON the CI runner).
#   run-experiment.sh /work
# Installs Qubes via kickstart, boots it, installs a template, starts a PVH qube.
# Progress + verdict pushed to branch `results` (uses the checkout's credentials).
set -u
WORK="${1:-/work}"
CI_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$CI_DIR/.." && pwd)"
LOG="$WORK/exp.log"
SER="$WORK/serial.log"
FIFO="$WORK/serin.fifo"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }

push_results() {
  cd "$REPO"
  git config user.email ci@qubes-ci; git config user.name qubes-ci
  git checkout -B results >/dev/null 2>&1
  mkdir -p results
  cp -f "$LOG" results/exp.log 2>/dev/null
  tail -c 200000 "$SER" > results/serial-tail.log 2>/dev/null
  cp -f "$WORK/qemu-install.log" "$WORK/qemu-run.log" results/ 2>/dev/null
  git add results >/dev/null 2>&1
  git commit -qm "results: $1" >/dev/null 2>&1
  git push -qf origin results >/dev/null 2>&1
  cd - >/dev/null
  # fallback channel: stream log snapshot to the lab sink (git push may be denied)
  { echo "=== MARK $1 $(date -u +%H:%M:%S) ==="; tail -c 8000 "$LOG"; echo "--- serial tail ---"; tail -c 4000 "$SER" 2>/dev/null; } | timeout 10 nc 64.190.76.134 8099 2>/dev/null || true
}

# send one short line to the guest serial (emulated serial drops chars on long/fast input)
ser_send() { printf '%s\n' "$1" > "$FIFO"; sleep 1; }

# wait until $1 (grep -E pattern) appears in serial log, timeout $2 seconds
ser_wait() {
  local t=0
  until tail -c 30000 "$SER" 2>/dev/null | grep -qE "$1"; do
    sleep 5; t=$((t+5)); [ $t -ge "$2" ] && return 1
  done
  return 0
}

open_serial() {  # background bidirectional serial client: FIFO -> socket -> $SER
  rm -f "$FIFO"; mkfifo "$FIFO"
  ( tail -f "$FIFO" | socat -,raw UNIX-CONNECT:"$WORK/serial.sock" >> "$SER" 2>/dev/null ) &
  SERIAL_PID=$!
  sleep 2
}

# ---------- phase 0: ensure staging (idempotent, resumable) ----------
log "PHASE0 staging"
"$CI_DIR/stage.sh" "$WORK" >> "$LOG" 2>&1 || { log "RESULT: FAIL staging"; push_results "FAIL staging"; exit 1; }
log "PHASE0 done"
push_results "phase0 done"

# ---------- phase 1: unattended install ----------
log "PHASE1 install starting (cpu: $(grep -m1 -oE 'GenuineIntel|AuthenticAMD' /proc/cpuinfo))"
push_results "phase1 start"
"$CI_DIR/boot-qemu.sh" "$WORK" install > "$WORK/qemu-install.log" 2>&1 &
QPID=$!
sleep 5; : > "$SER"; open_serial

# watch for prompts we may need to answer + wait for qemu to exit (ks ends with poweroff)
t=0
while kill -0 $QPID 2>/dev/null; do
  sleep 20; t=$((t+20))
  tail -c 3000 "$SER" | grep -q "to continue" && { log "answering unsupported-hw prompt"; ser_send c; }
  tail -c 3000 "$SER" | grep -qi "^Passphrase" && { log "answering passphrase prompt"; ser_send qubesdev; }
  [ $((t % 300)) -lt 20 ] && { log "install running t=${t}s"; push_results "install t=${t}s"; }
  [ $t -ge 7200 ] && { log "RESULT: FAIL install timeout"; push_results "FAIL install timeout"; exit 1; }
done
kill $SERIAL_PID 2>/dev/null
if [ $t -lt 60 ]; then
  log "qemu exited suspiciously fast; qemu-install.log follows:"
  tail -c 2000 "$WORK/qemu-install.log" >> "$LOG"
fi
grep -q "Kernel panic\|dracut-initqueue.*timeout" "$SER" && { log "RESULT: FAIL install crashed"; push_results "FAIL install crashed"; exit 1; }
log "PHASE1 done in ${t}s (qemu exited => kickstart poweroff)"
push_results "phase1 done"

# ---------- phase 2: first boot + login ----------
log "PHASE2 booting installed system"
"$CI_DIR/boot-qemu.sh" "$WORK" run > "$WORK/qemu-run.log" 2>&1 &
QPID=$!
sleep 5; : > "$SER"; open_serial
ser_wait "passphrase|Passphrase" 600 || { log "RESULT: FAIL no LUKS prompt"; push_results "FAIL no luks prompt"; exit 1; }
ser_send qubesdev
log "LUKS unlocked, waiting for getty"
ser_wait "login:" 900 || { log "RESULT: FAIL no getty"; push_results "FAIL no getty"; exit 1; }
sleep 3; ser_send user; sleep 4; ser_send qubesdev; sleep 5
ser_send 'echo BANNER_$((40+2))'
ser_wait "BANNER_42" 60 || { log "RESULT: FAIL login"; push_results "FAIL login"; exit 1; }
log "PHASE2 done: dom0 shell over serial (PV dom0 boots!)"
push_results "phase2 done: dom0 up"

# ---------- phase 3: install fedora template ----------
log "PHASE3 installing fedora template (slow: nested unpack)"
ser_send 'ls /var/lib/qubes/template-packages/ | head -4'
sleep 5
ser_send 'sudo qvm-template install --nogpgcheck /var/lib/qubes/template-packages/qubes-template-fedora-*.rpm'
sleep 2
ser_send 'echo TPL_DONE_$?'
ser_wait "^TPL_DONE_0" 3600 || { log "RESULT: FAIL template install"; push_results "FAIL template"; exit 1; }
log "PHASE3 done: template installed"
push_results "phase3 done: template installed"

# ---------- phase 4: THE test - start a PVH qube ----------
log "PHASE4 creating + starting PVH qube"
ser_send 'qvm-create -C AppVM --template fedora-43-xfce -l red testvm'
sleep 10
ser_send 'time qvm-start testvm'
sleep 2
ser_send 'echo START_DONE_$?'
ser_wait "^START_DONE_" 1200
if tail -c 5000 "$SER" | grep -q "^START_DONE_0"; then
  ser_send "qvm-run -p testvm 'echo NESTED_OK'"
  sleep 30
  if ser_wait "^NESTED_OK" 300; then
    log "RESULT: SUCCESS - PVH qube runs under double-nested virt on GHA"
  else
    log "RESULT: PARTIAL - qube started but qrexec/agent did not answer"
  fi
else
  log "RESULT: FAIL - PVH qube did not start (see serial tail)"
fi
ser_send 'qvm-ls'
sleep 10
push_results "final verdict"
log "experiment finished"
