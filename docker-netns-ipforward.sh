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
