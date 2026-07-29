#!/bin/bash -e

openvpn3 config-remove --config runai-isaac --force
openvpn3 configs-list --verbose
