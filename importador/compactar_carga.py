"""Junta INSERTs consecutivos da carga num único INSERT multi-linha (para colar no SQL Editor do Supabase)."""
import re, sys
src = open(sys.argv[1], encoding='utf-8').read().split('\n')
out, cur, vals = [], None, []
pat = re.compile(r"^INSERT INTO (\S+ \([^)]*\)|\S+) VALUES (.*?)( ON CONFLICT.*)?;$")
def flush():
    global cur, vals
    if cur: out.append(f"INSERT INTO {cur} VALUES\n" + ",\n".join(vals) + ";")
    cur, vals = None, []
for line in src:
    m = pat.match(line)
    if m and not line.startswith("INSERT INTO pec.parametro"):
        if m.group(1) != cur: flush(); cur = m.group(1)
        vals.append(m.group(2))
    else:
        flush(); out.append(line)
flush()
open(sys.argv[2], 'w', encoding='utf-8').write("\n".join(out))
