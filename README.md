# Docker Swarm Overlay Networks in LXC: IP Forwarding Fix

## Problem

When running Docker Swarm inside Proxmox LXC containers, overlay network communication fails because Docker's network namespaces do not have IP forwarding enabled.

According to Docker documentation, docker should automatically enable IP forwarding in network namespaces. However, when using Docker Swarm Mode with a Proxmox LXC, these namespaces fail to inherit the IP forwarding setting from the host container, causing overlay networks to malfunction.

## Symptoms

- Services on overlay networks cannot communicate across swarm nodes - meaning containers cannot communicate with one another.
- Ingress routing fails - you will get time out errors when trying to access services.
- Network namespaces show `net.ipv4.ip_forward = 0` despite the LXC container having it enabled.

## Diagnosis

You can confirm that IP forwarding is source of your problems by running these commands:

```
# This checks just the default ingress network:
sudo nsenter --net=/run/docker/netns/ingress_sbox cat /proc/sys/net/ipv4/ip_forward

# to check all docker networks
sudo bash -c 'for netns in /run/docker/netns/*; do echo "$(basename $netns): $(nsenter --net="$netns" cat /proc/sys/net/ipv4/ip_forward)"; done'
```

## Solution

The solution (and previous diagnosis step) was found thanks in part by a comment on [this thread](https://discuss.linuxcontainers.org/t/docker-swarm-in-lxd-container/937/2). However, that only fixes the ingress network. Using container logs and Network Details in Portainer, it was clear that this solution was needed for ALL overlay networks, not just the default ingress. Looking in the /run/docker/net directory lists all of the networks present.

This solution uses a monitoring script that automatically enables IP forwarding in Docker network namespaces as they are created. The script runs continuously and watches for new namespaces, applying the setting immediately.

### Prerequisites

- Proxmox VE with LXC containers
- Docker Swarm running inside LXC
- `inotify-tools` package

## Installation

You can copy and past everything below, or use the files in this repository.

### 1. Configure the LXC container

On your Proxmox host, edit the LXC configuration file at `/etc/pve/lxc/<VMID>.conf` and add:

```
lxc.sysctl.net.ipv4.ip_forward = 1
features: nesting=1
```

Restart the LXC container after making this change.

### 2. Install required packages

Inside the LXC container:

```bash
apt-get update && apt-get install -y inotify-tools
```

### 3. Create the monitoring script

```bash
cat > /usr/local/bin/docker-netns-ipforward.sh << 'EOF'
#!/bin/bash

apply_ipforward() {
    for netns in /run/docker/netns/*; do
        if [ -e "$netns" ]; then
            nsname=$(basename "$netns")
            nsenter --net="$netns" sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward" 2>/dev/null && \
                echo "Applied ip_forward to $nsname" || \
                echo "Failed to apply to $nsname"
        fi
    done
}

# Apply on startup
echo "Applying ip_forward to existing namespaces..."
apply_ipforward

# Watch for new network namespaces
echo "Monitoring for new namespaces..."
while inotifywait -e create -e moved_to /run/docker/netns/ 2>/dev/null; do
    sleep 2
    apply_ipforward
done
EOF

chmod +x /usr/local/bin/docker-netns-ipforward.sh
```

### 4. Create the systemd service

```bash
cat > /etc/systemd/system/docker-netns-ipforward.service << 'EOF'
[Unit]
Description=Enable IP forwarding in all Docker network namespaces
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/docker-netns-ipforward.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

### 5. Enable and start the service

```bash
systemctl daemon-reload
systemctl enable docker-netns-ipforward.service
systemctl start docker-netns-ipforward.service
```

## Verification

Check that the service is running:

```bash
systemctl status docker-netns-ipforward.service
```

Verify IP forwarding is enabled in all Docker network namespaces:

```bash
for netns in /run/docker/netns/*; do
    echo "$(basename $netns): $(nsenter --net="$netns" cat /proc/sys/net/ipv4/ip_forward)"
done
```

All namespaces should show `1`.

Monitor the service logs to see it applying settings to new namespaces:

```bash
journalctl -u docker-netns-ipforward.service -f
```

## How it works

The script performs two functions:

1. On startup, it applies the IP forwarding setting to all existing Docker network namespaces
2. It then monitors `/run/docker/netns/` for new namespaces and applies the setting automatically when Swarm creates new overlay networks

This approach handles both persistent configuration across reboots and dynamic network creation during normal Swarm operations.

## Multi-node swarms

For Docker Swarm clusters with multiple nodes, install this solution on all manager and worker nodes.

## Technical background

Docker Swarm creates isolated network namespaces for overlay networks (ingress, service networks, load balancer namespaces). Each namespace has its own network stack with independent sysctl settings. By default, new network namespaces have `ip_forward=0`.

With the legacy iptables backend, Docker automatically enables IP forwarding in these namespaces. However, the nftables backend is experimental and does not handle this automatically. In LXC containers, the namespaces also do not inherit the setting from the container itself, requiring explicit configuration.

## Alternatives considered

- Switching to iptables-legacy: This did not resolve the issue in testing
- Using `sysctl` command directly: Not available in minimal namespace environments
- Docker daemon configuration: No options exist for network namespace sysctls
- Compose file configuration: Container sysctls do not apply to network namespaces

## License

MIT
