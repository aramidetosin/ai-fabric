#!/bin/bash
# host/uninstall.sh: remove the boot-time start again. The running lab is NOT touched (the unit is disabled without stopping it:
# `systemctl stop` would power the guests off).
systemctl disable ai-fabric-lab.service 2>/dev/null; rm -f /etc/systemd/system/ai-fabric-lab.service; systemctl daemon-reload
systemctl reset-failed ai-fabric-lab.service 2>/dev/null; echo "ai-fabric-lab.service removed (lab left as it is)"
