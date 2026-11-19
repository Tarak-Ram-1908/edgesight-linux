#!/usr/bin/env bash
# Stock-distro baseline: Ubuntu Server 24.04 LTS cloud image, booted with EXACTLY the same
# QEMU machine as EdgeSight (q35, KVM, 2 vCPU, 1 GiB, OVMF, virtio), measured the same way.
#
#   baseline/ubuntu/run-baseline.sh            full run (first run downloads ~600 MB)
#
# Produces baseline/ubuntu/results/{ubuntu.json, ubuntu-kernel.config, *.txt, bench-*.jsonl}
set -euo pipefail
trap 'rc=$?; [ $rc -ne 0 ] && echo "run-baseline: failed rc=$rc at line $LINENO: $BASH_COMMAND" >&2' EXIT
. "$(dirname "$0")/../../scripts/lib.sh"
B="$WORK/baseline"; mkdir -p "$B"
R="$REPO/baseline/ubuntu/results"; mkdir -p "$R"
IMG_URL=https://cloud-images.ubuntu.com/releases/24.04/release
IMG=ubuntu-24.04-server-cloudimg-amd64.img
SSHP=2223; HTTPP=8081
U_SSH=(ssh "${SSH_OPTS[@]}" -p $SSHP ubuntu@127.0.0.1)

# ---- image (verified against Canonical's SHA256SUMS) ----
cd "$B"
if [ ! -f "$IMG" ]; then
    c_info "downloading $IMG"
    curl -fsSL -o SHA256SUMS "$IMG_URL/SHA256SUMS"
    curl -fL --progress-bar -o "$IMG" "$IMG_URL/$IMG"
    grep " \*\?$IMG\$" SHA256SUMS | sed 's/ \*/  /' | sha256sum -c -
fi
sha256sum "$IMG" | tee "$R/image.sha256"
stat -c %s "$IMG" > "$R/image-bytes.txt"

# ---- cloud-init seed: our test SSH key, nothing else ----
cat > user-data <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$SSH_KEY.pub")
package_update: false
package_upgrade: false
EOF
printf 'instance-id: edgesight-baseline\nlocal-hostname: ubuntu-baseline\n' > meta-data
rm -f seed.img && mkfs.vfat -n CIDATA -C seed.img 2048 >/dev/null && mcopy -i seed.img user-data meta-data ::

rm -f work.qcow2
qemu-img create -q -f qcow2 -F qcow2 -b "$B/$IMG" work.qcow2 10G
cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd

start_vm() {
    rm -f serial.log
    qemu-system-x86_64 -name ubuntu-baseline -machine q35,accel=kvm -cpu host -smp "${SMP:-2}" -m "${MEM:-1024}" \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,file="$B/vars.fd" \
        -drive file="$B/work.qcow2",format=qcow2,if=virtio,cache=writeback \
        -drive file="$B/seed.img",format=raw,if=virtio,readonly=on \
        -netdev "user,id=n0,hostfwd=tcp::$SSHP-:22,hostfwd=tcp::$HTTPP-:8080" -device virtio-net-pci,netdev=n0,romfile= \
        -device virtio-rng-pci -nodefaults -no-user-config -display none \
        -serial file:"$B/serial.log" -pidfile "$B/qemu.pid" -daemonize
}
wait_u_ssh() { local t=0; until "${U_SSH[@]}" true </dev/null 2>/dev/null; do sleep 0.5; t=$((t+1)); [ $t -gt 600 ] && return 1; done; return 0; }
stop_vm() { kill "$(cat "$B/qemu.pid")" 2>/dev/null || true; sleep 1; }

c_info "first boot (cloud-init provisioning)"
start_vm; wait_u_ssh; "${U_SSH[@]}" 'cloud-init status --wait >/dev/null 2>&1 || true'

c_info "installing the stock Python ML stack (python3-venv + pip onnxruntime numpy pillow)"
"${U_SSH[@]}" 'sudo apt-get -qq update >/dev/null && sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y python3-venv >/dev/null &&
               python3 -m venv ~/ml && ~/ml/bin/pip -q install onnxruntime==1.32.0 numpy pillow && du -sm ~/ml | cut -f1' > "$R/python-stack-mib.txt"
c_info "copying EdgeSight's own userland bundle (same binary + libs) for an apples-to-apples run"
T="$WORK/output-prod/target"
tar -C "$T" -czf "$B/es-bundle.tgz" usr/bin/edgesightd usr/lib lib usr/share/edgesight
cat "$B/es-bundle.tgz" | "${U_SSH[@]}" 'sudo mkdir -p /opt/edgesight && sudo tar -C /opt/edgesight -xzf - && echo 1.0.0-on-ubuntu | sudo tee /etc/edgesight-version >/dev/null'
scp "${SSH_OPTS[@]}" -P $SSHP "$REPO/bench/stock_pipeline.py" ubuntu@127.0.0.1:
ESRUN='/opt/edgesight/lib/ld-linux-x86-64.so.2 --library-path /opt/edgesight/lib:/opt/edgesight/usr/lib /opt/edgesight/usr/bin/edgesightd'
# systemd unit = the "stock" way to auto-start the same service
"${U_SSH[@]}" "sudo tee /etc/systemd/system/edgesight.service >/dev/null" <<EOF
[Unit]
Description=EdgeSight detector (baseline)
After=network-online.target
[Service]
ExecStart=$ESRUN --runtime ort --model /opt/edgesight/usr/share/edgesight/models/ssd_mobilenet_v1_fp32.onnx --threads 2 --source dir:/opt/edgesight/usr/share/edgesight/samples --fps 10 --http-port 8080 --selftest /opt/edgesight/usr/share/edgesight/samples/000000039769.jpg
Restart=always
[Install]
WantedBy=multi-user.target
EOF
"${U_SSH[@]}" 'sudo systemctl daemon-reload && sudo systemctl enable -q edgesight.service'
"${U_SSH[@]}" 'sudo poweroff' || true; sleep 5; stop_vm

# ---- steady-state boots (cloud-init already done) ----
: > "$R/boot.jsonl"
for run in 1 2 3; do
    c_info "measured boot $run/3"
    t0=$(date +%s.%N); start_vm
    until curl -sf -m 1 "http://127.0.0.1:$HTTPP/healthz" >/dev/null 2>&1; do sleep 0.1; done
    t_app=$(date +%s.%N)
    wait_u_ssh
    sa=$("${U_SSH[@]}" 'systemd-analyze time 2>/dev/null | head -1')
    up=$("${U_SSH[@]}" "journalctl -b -u edgesight -o cat | grep -m1 EDGESIGHT_READY | sed 's/.*uptime=\([0-9.]*\).*/\1/'")
    echo "{\"launch_to_app_ready_s\":$(echo "$t_app - $t0" | bc -l),\"kernel_to_app_ready_s\":${up:-null},\"systemd_analyze\":\"$sa\"}" | tee -a "$R/boot.jsonl"
    if [ $run -lt 3 ]; then "${U_SSH[@]}" 'sudo poweroff' || true; sleep 5; stop_vm; fi
done

c_info "footprint measurements (idle 60 s)"
sleep 60
"${U_SSH[@]}" 'bash -s' > "$R/ubuntu.json" <<'EOF'
mem_used=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%.1f",(t-a)/1024}' /proc/meminfo)
mem_total=$(awk '/MemTotal/{printf "%.1f",$2/1024}' /proc/meminfo)
pkgs=$(dpkg-query -f '${binary:Package}\n' -W | wc -l)
rootfs=$(df -B1 --output=used / | tail -1)
kver=$(uname -r)
ksize=$(stat -c %s /boot/vmlinuz-$kver)
initrd=$(stat -c %s /boot/initrd.img-$kver)
mods=$(find /lib/modules/$kver -name '*.ko*' | wc -l)
modsz=$(du -sb /lib/modules/$kver | cut -f1)
procs=$(ps -e --no-headers | wc -l)
units=$(systemctl list-units --type=service --state=running --no-legend | wc -l)
ports=$(ss -tulnH | wc -l)
suid=$(sudo find / -xdev -perm /6000 -type f 2>/dev/null | wc -l)
es_rss=$(ps -C ld-linux-x86-64.so.2 -o rss= 2>/dev/null | head -1)
cat <<J
{"distro":"$(. /etc/os-release; echo $PRETTY_NAME)","kernel":"$kver","sys_mem_used_mib":$mem_used,"sys_mem_total_mib":$mem_total,
 "packages":$pkgs,"rootfs_used_bytes":$rootfs,"kernel_bytes":$ksize,"initrd_bytes":$initrd,"modules":$mods,"modules_bytes":$modsz,
 "processes":$procs,"running_services":$units,"listening_sockets":$ports,"setuid_setgid_files":$suid,"edgesight_rss_kib":${es_rss:-0}}
J
EOF
cat "$R/ubuntu.json"
"${U_SSH[@]}" 'cat /boot/config-$(uname -r)' > "$R/ubuntu-kernel.config"
"${U_SSH[@]}" 'ss -tulnp 2>/dev/null; echo; systemctl list-units --type=service --state=running --no-legend' > "$R/ubuntu-services.txt"
"${U_SSH[@]}" 'systemd-analyze blame | head -25' > "$R/ubuntu-blame.txt"

c_info "inference benchmarks on Ubuntu (service stopped)"
"${U_SSH[@]}" 'sudo systemctl stop edgesight'
M=/opt/edgesight/usr/share/edgesight/models; S=/opt/edgesight/usr/share/edgesight/samples
: > "$R/bench-ubuntu.jsonl"
for t in 1 2; do
  for m in fp32 int8; do
    "${U_SSH[@]}" "$ESRUN --bench 300 --warmup 30 --runtime ort --model $M/ssd_mobilenet_v1_$m.onnx --threads $t --source dir:$S 2>/dev/null" \
        | jq -c --arg l "ubuntu edgesightd ort $m t$t" '. + {label:$l}' | tee -a "$R/bench-ubuntu.jsonl"
    "${U_SSH[@]}" "~/ml/bin/python stock_pipeline.py --model $M/ssd_mobilenet_v1_$m.onnx --samples $S --threads $t" \
        | jq -c --arg l "ubuntu python ort $m t$t" '. + {label:$l}' | tee -a "$R/bench-ubuntu.jsonl"
  done
done
"${U_SSH[@]}" 'sudo poweroff' || true; sleep 3; stop_vm
c_ok "baseline results in $R"
