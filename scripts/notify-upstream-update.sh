#!/usr/bin/env bash
# =============================================================================
# notify-upstream-update.sh
#
# Checks the upstream M365-Copilot2API repository for commits newer than the
# locally deployed HEAD and sends a Telegram notification (pretty HTML) when an
# update is available. Each upstream SHA is notified at most once, so repeated
# cron runs do not spam; a new upstream commit re-notifies with everything new.
#
# Usage:
#   ./scripts/notify-upstream-update.sh            # check + notify (cron mode)
#   ./scripts/notify-upstream-update.sh --check    # check only, print status
#   ./scripts/notify-upstream-update.sh --force    # send even if already notified
#
# Exit codes:
#   0  up to date (or nothing new to notify)
#   1  update available and Telegram notification sent
#   2  update available but Telegram send failed
#   3  could not fetch upstream (network/git error)
#
# Cron (every 30 min):
#   */30 * * * * /home/ubuntu/M365-Copilot2API/scripts/notify-upstream-update.sh \
#       >> /tmp/upstream-notify.log 2>&1
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
APP_DIR=${M365_APP_DIR:-$(dirname "$SCRIPT_DIR")}
UPSTREAM_REMOTE=${M365_UPSTREAM_REMOTE:-upstream}
UPSTREAM_BRANCH=${M365_UPSTREAM_BRANCH:-main}
UPSTREAM_REPO=${M365_UPSTREAM_REPO:-HEXUXIU/M365-Copilot2API}
STATE_FILE=${M365_NOTIFY_STATE_FILE:-"$APP_DIR/data/upstream-notified.sha"}

MODE=notify
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --force) FORCE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 64 ;;
  esac
done

# Load bot credentials (gitignored via .env.*). Only required for notify mode.
if [[ -r "$APP_DIR/.env.telegram" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$APP_DIR/.env.telegram"; set +a
fi
if [[ $MODE == notify ]]; then
  : "${M365_TG_BOT_TOKEN:?set M365_TG_BOT_TOKEN in .env.telegram (or use --check)}"
  : "${M365_TG_CHAT_ID:?set M365_TG_CHAT_ID in .env.telegram (or use --check)}"
fi

log()  { printf '[upstream-notify] %s\n' "$*"; }
fail() { printf '[upstream-notify] ERROR: %s\n' "$*" >&2; }

[[ -d "$APP_DIR/.git" ]] || fail "not a git repository: $APP_DIR"
cd "$APP_DIR"

# ---------------------------------------------------------------------------
# 1. Fetch upstream (read-only; touches only FETCH_HEAD / remote-tracking refs).
# ---------------------------------------------------------------------------
fetch_ok=0
for attempt in 1 2 3; do
  if git fetch --quiet --force "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>/dev/null; then
    fetch_ok=1
    break
  fi
  log "fetch attempt $attempt failed (remote: $UPSTREAM_REMOTE); retrying"
  sleep 10
done
if [[ $fetch_ok -ne 1 ]]; then
  fail "could not fetch $UPSTREAM_REMOTE/$UPSTREAM_BRANCH after 3 attempts"
  exit 3
fi
UPSTREAM_SHA=$(git rev-parse FETCH_HEAD)
LOCAL_SHA=$(git rev-parse HEAD)

# ---------------------------------------------------------------------------
# 2. Is upstream actually ahead of what we have deployed?
#    (HEAD is a local merge commit, so compare ancestry rather than SHAs.)
# ---------------------------------------------------------------------------
if git merge-base --is-ancestor FETCH_HEAD HEAD 2>/dev/null; then
  if [[ $MODE == check ]]; then
    log "up-to-date: local $LOCAL_SHA already contains upstream $UPSTREAM_SHA"
  fi
  exit 0
fi

TOTAL_COMMITS=$(git rev-list --count "$LOCAL_SHA..FETCH_HEAD" || echo 0)

# Suppress duplicate notifications for the same upstream SHA.
last_notified=''
if [[ -r "$STATE_FILE" ]]; then
  last_notified=$(<"$STATE_FILE")
fi
if [[ -n "$last_notified" && "$last_notified" == "$UPSTREAM_SHA" && $FORCE -ne 1 ]]; then
  log "upstream $UPSTREAM_SHA already notified; nothing new"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Build the pretty HTML message from real git data (times in WIB / UTC+7).
# ---------------------------------------------------------------------------
LOG_RAW=$(git log --format='%x1e%h%x1f%ct%x1f%an%x1f%s%x1f%b' "$LOCAL_SHA..FETCH_HEAD")
MESSAGE=$(LOG_RAW="$LOG_RAW" UPSTREAM_REPO="$UPSTREAM_REPO" UPSTREAM_BRANCH="$UPSTREAM_BRANCH" python3 - <<'PYEOF'
import html, os, datetime

EMOJI = {
    'fix!':  '\U0001F525',              # 🔥
    'fix':   '\U0001F6E0\uFE0F',        # 🛠️
    'feat':  '\u2728',                  # ✨
    'docs':  '\U0001F4DA',              # 📚
    'refactor': '\u267B\uFE0F',         # ♻️
    'chore': '\U0001F9F9',              # 🧹
    'perf':  '\u26A1',                  # ⚡
    'ci':    '\U0001F680',              # 🚀
}
COMMITS_LIMIT = 8
MAX_BODY = 280

def esc(s):
    return html.escape(s or '', quote=False)

rows = []
for chunk in os.environ['LOG_RAW'].split('\x1e'):
    f = chunk.split('\x1f')
    if len(f) < 5:
        continue
    sha, ts, author, subject, body = (x.strip() for x in f[:5])
    rows.append((sha, int(ts), author, subject, body))

rows.reverse()  # oldest -> newest

total = len(rows)
parts = []
for sha, ts, author, subject, body in rows[:COMMITS_LIMIT]:
    wib = datetime.datetime.fromtimestamp(
        ts, tz=datetime.timezone(datetime.timedelta(hours=7))
    ).strftime('%d %b %Y, %H:%M WIB')
    tag = subject.split(':', 1)[0].strip().lower() if ':' in subject else ''
    emoji = EMOJI.get(tag, '\U0001F500')  # 🔀
    parts.append(
        f'{emoji} <b>{esc(subject)}</b>\n'
        f'   <code>{sha[:7]}</code> \u00b7 by {esc(author)} \u00b7 {wib}'
    )
    body = ' '.join(body.split())[:MAX_BODY]
    if body:
        parts.append(f'   <i>{esc(body)}</i>')

if len(rows) == 0:
    sys.exit(0)

msg = (
    f'\U0001F680 <b>Upstream Update \u2014 M365-Copilot2API</b>\n\n'
    + '\n\n'.join(parts)
)
if total > COMMITS_LIMIT:
    msg += f'\n\n\u2026 and {total - COMMITS_LIMIT} more commit(s).'
msg += (
    f'\n\n\U0001F4C5 <b>{total}</b> new commit(s) on <code>{os.environ["UPSTREAM_BRANCH"]}</code>\n'
    f'\U0001F517 <a href="https://github.com/{os.environ["UPSTREAM_REPO"]}/commits/{os.environ["UPSTREAM_BRANCH"]}">view commits</a>'
    '\n\u2699\uFE0F Deploy: <code>scripts/m365-copilot2api-update.sh</code>'
)
print(msg)
PYEOF
)

if [[ $MODE == check ]]; then
  printf '%s\n' "$MESSAGE"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Send via Telegram (HTML parse mode) with retry.
# ---------------------------------------------------------------------------
send_ok=0
for attempt in 1 2 3; do
  if curl -fsS --max-time 20 \
      -X POST "https://api.telegram.org/bot$M365_TG_BOT_TOKEN/sendMessage" \
      -d chat_id="$M365_TG_CHAT_ID" \
      -d parse_mode=HTML \
      -d disable_web_page_preview=true \
      --data-urlencode "text=$MESSAGE" >/dev/null 2>&1; then
    send_ok=1
    break
  fi
  log "Telegram send attempt $attempt failed; retrying"
  sleep 5
done

if [[ $send_ok -ne 1 ]]; then
  fail "Telegram send failed for upstream $UPSTREAM_SHA"
  exit 2
fi

mkdir -p "$(dirname "$STATE_FILE")"
printf '%s\n' "$UPSTREAM_SHA" >"$STATE_FILE"
log "notified ${TOTAL_COMMITS} new commit(s), upstream now $UPSTREAM_SHA"
exit 1