## Sync Open WebUI's stored LLM connection to its environment
# Runs inside the container: docker exec -i openwebui python3 - < this file.
# With ENABLE_PERSISTENT_CONFIG, Open WebUI seeds these keys from the
# environment on first launch and then reads them from the database, so later
# changes to the URL, key or default model in Ansible would be ignored.
# Prints "updated <keys>" when it wrote anything, "in sync" otherwise.
# Never prints values: openai.api_keys holds the backend credential.

import json
import os
import sqlite3

## Wanted values, from the env file the container was started with
# Open WebUI separates multiple connections with ';'.
want = {
    'openai.api_base_urls': os.environ['OPENAI_API_BASE_URLS'].split(';'),
    'openai.api_keys': os.environ['OPENAI_API_KEYS'].split(';'),
}
if os.environ.get('DEFAULT_MODELS'):
    want['ui.default_models'] = os.environ['DEFAULT_MODELS']

## Compare and write
# The config table holds one JSON-encoded value per key.
db = sqlite3.connect('/app/backend/data/webui.db')
changed = []
for key, value in want.items():
    row = db.execute('SELECT value FROM config WHERE key = ?', (key,)).fetchone()
    stored = json.loads(row[0]) if row and isinstance(row[0], str) else None
    if stored != value:
        db.execute(
            "INSERT INTO config (key, value, updated_at) "
            "VALUES (?, ?, CAST(strftime('%s', 'now') AS INTEGER)) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value, "
            "updated_at = excluded.updated_at",
            (key, json.dumps(value)),
        )
        changed.append(key)
db.commit()

print('updated ' + ' '.join(changed) if changed else 'in sync')
