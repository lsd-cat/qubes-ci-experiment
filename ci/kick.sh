#!/bin/bash
# One-shot (re)launcher, designed to be triggered over an unreliable tty with:
#   curl -sL https://raw.githubusercontent.com/lsd-cat/qubes-ci-experiment/main/ci/kick.sh | bash
set -u
pkill -f run-experiment.sh 2>/dev/null
pkill -f qemu-system 2>/dev/null
sleep 2
cd "$HOME"/work/*/*/repo
git fetch -q origin
git checkout -q main 2>/dev/null || true
git reset -q --hard origin/main
rm -f /work/exp.log /work/serial.log
setsid nohup ci/run-experiment.sh /work > /work/exp-nohup.log 2>&1 < /dev/null &
sleep 3
echo "KICK: $(git log --oneline -1)"
pgrep -af run-experiment.sh
