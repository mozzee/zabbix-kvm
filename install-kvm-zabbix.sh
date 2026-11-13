
#!/usr/bin/env bash
set -euo pipefail

echo "Installing KVM monitoring for Zabbix 7.4..."

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

# Install dependencies
dnf install -y python3-libvirt libvirt-client

id zabbix >/dev/null 2>&1 || {
    echo "Zabbix service account not found."
    exit 1
}

# Prepare collector directory
install -d -o root -g zabbix -m 0750 \
    /var/lib/zabbix/kvm
install -d -m 0755 /usr/local/libexec

# Create Python collector
cat > /usr/local/libexec/zabbix-kvm-collector.py <<'PY'
#!/usr/bin/python3
import grp
import json
import os
import re
import tempfile
import time
import libvirt

OUTPUT = "/var/lib/zabbix/kvm/metrics.json"

FLAGS = (
    libvirt.VIR_DOMAIN_STATS_STATE |
    libvirt.VIR_DOMAIN_STATS_CPU_TOTAL |
    libvirt.VIR_DOMAIN_STATS_BALLOON |
    libvirt.VIR_DOMAIN_STATS_VCPU |
    libvirt.VIR_DOMAIN_STATS_INTERFACE |
    libvirt.VIR_DOMAIN_STATS_BLOCK
)

def total(stats, pattern):
    return sum(
        int(v) for k, v in stats.items()
        if re.fullmatch(pattern, k)
    )

def collect():
    conn = libvirt.openReadOnly("qemu:///system")
    if conn is None:
        raise RuntimeError("libvirt connection failed")

    try:
        all_stats = {
            dom.UUIDString(): stats
            for dom, stats in conn.getAllDomainStats(
                FLAGS, 0
            )
        }

        vms = []

        for dom in conn.listAllDomains(0):
            info = dom.info()
            stats = all_stats.get(dom.UUIDString(), {})

            vm = {
                "uuid": dom.UUIDString(),
                "name": dom.name(),
                "state": int(
                    stats.get("state.state", info[0])
                ),
                "vcpus": int(
                    stats.get("vcpu.current", info[3])
                ),
                "cpu_time_ms": int(
                    stats.get("cpu.time", info[4])
                ) // 1000000,
                "mem_alloc_bytes": int(
                    stats.get("balloon.current", info[2])
                ) * 1024,
                "mem_rss_bytes": int(
                    stats.get("balloon.rss", 0)
                ) * 1024,
                "disk_read_bytes": total(
                    stats, r"block\.\d+\.rd\.bytes"
                ),
                "disk_write_bytes": total(
                    stats, r"block\.\d+\.wr\.bytes"
                ),
                "net_rx_bytes": total(
                    stats, r"net\.\d+\.rx\.bytes"
                ),
                "net_tx_bytes": total(
                    stats, r"net\.\d+\.tx\.bytes"
                )
            }

            available = stats.get("balloon.available")
            usable = stats.get("balloon.usable")

            if available and usable is not None:
                vm["guest_mem_util_pct"] = round(
                    100 * max(
                        0, 1 - usable / available
                    ), 2
                )

            vms.append(vm)

        return {
            "timestamp": int(time.time()),
            "vm_count": len(vms),
            "running_count": sum(
                v["state"] == 1 for v in vms
            ),
            "vms": sorted(
                vms, key=lambda x: x["name"]
            )
        }
    finally:
        conn.close()

def main():
    data = collect()
    directory = os.path.dirname(OUTPUT)

    fd, temp = tempfile.mkstemp(
        prefix=".kvm-", dir=directory
    )

    try:
        os.fchmod(fd, 0o640)
        os.fchown(
            fd, 0, grp.getgrnam("zabbix").gr_gid
        )

        with os.fdopen(fd, "w") as f:
            json.dump(data, f, separators=(",", ":"))
            f.write("\n")

        os.replace(temp, OUTPUT)

    finally:
        if os.path.exists(temp):
            os.unlink(temp)

if __name__ == "__main__":
    main()
PY

chmod 755 /usr/local/libexec/zabbix-kvm-collector.py

# Create systemd service
cat > /etc/systemd/system/zabbix-kvm-collector.service <<'EOF'
[Unit]
Description=KVM VM Metrics Collector
After=network.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 /usr/local/libexec/zabbix-kvm-collector.py
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
EOF

# Create systemd timer
cat > /etc/systemd/system/zabbix-kvm-collector.timer <<'EOF'
[Unit]
Description=Collect KVM VM Metrics Every Minute

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=1s
Unit=zabbix-kvm-collector.service

[Install]
WantedBy=timers.target
EOF

# Detect existing Zabbix agent
if systemctl is-active --quiet zabbix-agent2; then
    AGENT="zabbix-agent2"
    MAIN="/etc/zabbix/zabbix_agent2.conf"
    CONFDIR="/etc/zabbix/zabbix_agent2.d"
elif systemctl is-active --quiet zabbix-agent; then
    AGENT="zabbix-agent"
    MAIN="/etc/zabbix/zabbix_agentd.conf"
    CONFDIR="/etc/zabbix/zabbix_agentd.d"
else
    echo "No active Zabbix agent service detected."
    exit 1
fi

mkdir -p "$CONFDIR"

# Register custom item
cat > "$CONFDIR/kvm.conf" <<'EOF'
UserParameter=kvm.raw,/usr/bin/cat /var/lib/zabbix/kvm/metrics.json
EOF

# Ensure the configuration directory is included
if ! grep -Fq "Include=$CONFDIR/*.conf" "$MAIN"; then
    printf '\nInclude=%s/*.conf\n' "$CONFDIR" >> "$MAIN"
fi

# Restore SELinux file labels where applicable
if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF /var/lib/zabbix/kvm
    restorecon -RF "$CONFDIR"
fi

systemctl daemon-reload
systemctl enable --now zabbix-kvm-collector.timer

# Collect first snapshot immediately
systemctl start zabbix-kvm-collector.service

systemctl restart "$AGENT"

echo
echo "===================================="
echo "KVM Monitoring Installation Complete"
echo "===================================="
echo "Agent: $AGENT"
echo "Item key: kvm.raw"
echo "Interval: 60 seconds"
echo
echo "Detected VM summary:"
/usr/bin/python3 -c '
import json
d=json.load(open("/var/lib/zabbix/kvm/metrics.json"))
print("Total VMs:",d["vm_count"])
print("Running VMs:",d["running_count"])
for v in d["vms"]:
    print(v["name"], "state:",v["state"])
'
echo
echo "Test Zabbix item with:"
echo "$AGENT -t kvm.raw"
