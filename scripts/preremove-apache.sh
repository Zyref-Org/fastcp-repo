#!/bin/sh
set -e
systemctl stop fcp-apache.service || true
systemctl disable fcp-apache.service || true
