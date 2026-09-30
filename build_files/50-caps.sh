#!/usr/bin/bash
# Drops file capabilities that would let dev undo its network containment. Runs
# last, after everything else is installed.
#
# gst-ptp-helper (GStreamer's PTP clock, unused here) runs with cap_net_admin
# for whoever starts it, dev included. cap_net_admin is enough to delete the
# nftables rule, so a bug in the helper would be a way out.
set -euo pipefail

setcap -r /usr/libexec/gstreamer-1.0/gst-ptp-helper
