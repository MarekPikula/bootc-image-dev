#!/usr/bin/bash
# Only wheel may use su. requisite (not Fedora's commented-out "required")
# stops before the password prompt, so dev can't even try another account's
# password. Fail the build if Fedora's line changes.
set -euo pipefail

sed -i -E 's/^#auth\s+required\s+(pam_wheel\.so use_uid)$/auth\t\trequisite\t\1/' /etc/pam.d/su
grep -qE '^auth\s+requisite\s+pam_wheel\.so use_uid$' /etc/pam.d/su
