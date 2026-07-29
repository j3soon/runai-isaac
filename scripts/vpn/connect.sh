#!/bin/bash -e

if openvpn3 sessions-list | grep -q runai-isaac; then
    echo "VPN session already connected."
    exit 1
fi
openvpn3 session-start --config runai-isaac
openvpn3 sessions-list
