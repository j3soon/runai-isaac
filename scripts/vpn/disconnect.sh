#!/bin/bash -e

openvpn3 session-manage --disconnect --config runai-isaac
openvpn3 sessions-list
