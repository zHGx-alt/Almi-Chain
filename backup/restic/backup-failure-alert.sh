#!/usr/bin/env bash
# Alert when the nightly backup fails. Started by systemd (OnFailure= on backup-odoo.service).
#
#   1. Always: an error message in the journal (priority err) and the file
#      /var/lib/backup-odoo/LAST-FAILURE, which the technician checks in the weekly routine.
#   2. Always: a message to the sessions open on the server (wall).
#   3. If /etc/default/backup-odoo sets ALERT_EMAIL=... and the server has "mail" (a configured
#      MTA), an email with the last 40 lines of the log.
set -uo pipefail

STATE=/var/lib/backup-odoo
[[ -r /etc/default/backup-odoo ]] && source /etc/default/backup-odoo
LOG=$(journalctl -u backup-odoo.service -n 40 --no-pager -o cat 2>/dev/null)
REASON=$(grep -E 'ERROR|Fatal|error' <<<"$LOG" | tail -1)
TEXT="The Odoo backup FAILED on $(date '+%Y-%m-%d at %H:%M') on $(hostname). ${REASON:-See: journalctl -u backup-odoo}"

logger -t backup-odoo -p user.err "$TEXT"
install -d -m 700 "$STATE"
{ echo "$TEXT"; echo; echo "$LOG"; } > "$STATE/LAST-FAILURE"
wall "$TEXT" 2>/dev/null || true

if [[ -n ${ALERT_EMAIL:-} ]]; then
  if command -v mail >/dev/null; then
    { echo "$TEXT"; echo; echo "Last lines:"; echo "$LOG"; } | mail -s "Odoo backup FAILED ($(hostname))" "$ALERT_EMAIL" \
      && logger -t backup-odoo "Failure alert sent to $ALERT_EMAIL"
  else
    logger -t backup-odoo -p user.warning "ALERT_EMAIL is set but there is no 'mail' (no MTA): journal and $STATE/LAST-FAILURE only"
  fi
fi
exit 0
