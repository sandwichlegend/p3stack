import json
import pathlib
import re
import sys

captures = pathlib.Path(__file__).with_name('real-cli')
name, actual_path, home, old = sys.argv[1:]
text = (captures / name).read_text().split('\n', 1)[1].rsplit('\nexit:', 1)[0].strip()
actual = pathlib.Path(actual_path).read_text().replace(home, '<HOME>').strip()
if name.startswith('codex') and name.endswith('json.txt'):
    assert json.loads(text) == json.loads(actual)
    sys.exit()
if name.startswith('claude'):
    if name.endswith('json.txt'):
        expected, found = json.loads(text), json.loads(actual)
        for rows in [expected, found]:
            for row in rows:
                row['version'] = '<COMMIT>'
                row['installPath'] = re.sub(r'/[0-9a-f]{12}$', '/<COMMIT>', row['installPath'])
                for key in ['installedAt', 'lastUpdated']:
                    row[key] = '<TIMESTAMP>'
        assert sorted(expected, key=lambda row: row['id']) == sorted(found, key=lambda row: row['id']), (expected, found)
        sys.exit()
    text = re.sub(r'Version: [0-9a-f]{12}', 'Version: <COMMIT>', text)
    actual = re.sub(r'Version: [0-9a-f]{12}', 'Version: <COMMIT>', actual)
if name.startswith('opencode'):
    text = re.sub(r'(p3stack  )[0-9a-f]{7}', r'\1<COMMIT>', text)
    actual = re.sub(r'(p3stack  )[0-9a-f]{7}', r'\1<COMMIT>', actual)
assert text == actual, f'{name}\nexpected:\n{text}\nactual:\n{actual}'
