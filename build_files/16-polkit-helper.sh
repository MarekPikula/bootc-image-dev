#!/usr/bin/bash
# polkit's password helper is setuid root, runs PAM for whichever user its
# caller names, and says whether the password was right, so dev could guess
# admin's password through it. Only wheel may run it now. dev never needs it:
# polkit never asks dev for a password. See PLAN.md, Privilege.
set -euo pipefail

helper=/usr/lib/polkit-1/polkit-agent-helper-1
chgrp wheel "$helper"
chmod 4750 "$helper"
