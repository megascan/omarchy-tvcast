import json, os, re, signal, stat, sys, tempfile

KEY = re.compile(r'"(trigger\.cast(?:\.[a-z]+)?)"\s*:')
PARENT = "trigger.cast"
JS_SPACE = "\t\n\x0b\x0c\r \u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"
JS_CLASS = "[" + re.escape(JS_SPACE) + "]"
JS_COMMENT = re.compile("(?:\\A|(?<=[\n\r\u2028\u2029]))" + JS_CLASS + r"*//[^\n]*(?:\n|\Z)")
JS_COMMA = re.compile("," + "(" + JS_CLASS + r"*[}\]])")
HERE = os.path.dirname(os.path.abspath(__file__))


def view(text):
    return text.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def reject_constant(name):
    raise ValueError(name)


def omarchy_items(text):
    stripped = JS_COMMA.sub(r"\1", JS_COMMENT.sub("", view(text)))
    if not stripped.strip(JS_SPACE):
        return {}
    try:
        parsed = json.loads(stripped, parse_constant=reject_constant)
    except (ValueError, RecursionError):
        return None
    if not isinstance(parsed, dict):
        return None
    items = parsed.get("items")
    return items if isinstance(items, dict) else parsed


def target_open(text):
    """Index of the opening brace of the object Omarchy reads entries from."""
    depth = 0
    last_key = None
    expect_items = False
    root_open = items_open = None
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if expect_items and c not in JS_SPACE:
            expect_items = False
            if c == "{" and depth == 1:
                items_open = i
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            last_key = text[i + 1:j]
            i = j + 1
            continue
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == ":" and depth == 1 and last_key == "items":
            items_open = None
            expect_items = True
        elif c in "{[":
            if depth == 0 and c == "{" and root_open is None:
                root_open = i
            depth += 1
        elif c in "}]":
            depth -= 1
            if depth < 0:
                return None
        i += 1
    return root_open if items_open is None else items_open


def norm(line):
    return line[:-1] if line.endswith("\r") else line


def read_text_lines(path):
    with open(path, encoding="utf-8") as f:
        return {l for l in (norm(x) for x in f.read().split("\n")) if l.strip()}


def known_lines(snippet):
    lines = read_text_lines(snippet)
    legacy = os.path.join(os.path.dirname(os.path.abspath(snippet)), "legacy-lines.txt")
    if os.path.exists(legacy):
        lines |= read_text_lines(legacy)
    return lines


def menu_file(real):
    """(bytes, nlink) of a regular menu file; None if it does not exist."""
    try:
        fd = os.open(real, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"{real} is not a regular file")
        chunks = []
        while True:
            b = os.read(fd, 1 << 20)
            if not b:
                break
            chunks.append(b)
        return b"".join(chunks), st.st_nlink
    finally:
        os.close(fd)


def write_atomic(path, data, mode=None, follow=True):
    target = os.path.realpath(path) if follow else os.path.abspath(path)
    fd, tmp = tempfile.mkstemp(prefix=".tvcast.", dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        if mode is None and os.path.exists(target):
            mode = os.stat(target).st_mode & 0o7777
        os.chmod(tmp, 0o600 if mode is None else mode)
        os.replace(tmp, target)
    except BaseException:
        os.unlink(tmp)
        raise


def backup(real, where, data):
    fd, bak = tempfile.mkstemp(prefix=os.path.basename(real) + ".bak.", dir=where)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    except BaseException:
        os.unlink(bak)
        raise
    return bak


def load_owned(path):
    """Record: {"files": {real menu path: [exact lines tvcast added there]}}."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (ValueError, RecursionError):
        sys.exit(f"{path} is not valid JSON; fix or remove it, then run this again")
    if not isinstance(data, dict):
        return {}
    files = data.get("files")
    if not isinstance(files, dict) and isinstance(data.get("menu"), str):
        files = {data["menu"]: data.get("lines", [])}
    out = {}
    for menu, lines in (files or {}).items():
        if isinstance(menu, str) and isinstance(lines, list):
            out[menu] = [l for l in lines if isinstance(l, str)]
    return out


def save_owned(path, files):
    files = {k: v for k, v in files.items() if v}
    if files:
        write_atomic(path, (json.dumps({"files": files}, indent=1) + "\n").encode(), 0o600, follow=False)
    elif os.path.lexists(path):
        os.unlink(path)


def cast_keys(items):
    return sorted(k for k in items or {} if k == PARENT or k.startswith(PARENT + "."))


def install(menu, snippet, owned_path):
    real = os.path.realpath(menu)
    found = menu_file(real)
    if found is not None and found[1] > 1:
        print(f"{menu} is hard-linked ({found[1]} links); add the entries by hand from {snippet}. Menu left unchanged", file=sys.stderr)
        return 1
    data = found[0] if found else b""
    text = data.decode("utf-8", "surrogateescape")
    snip = [norm(l) for l in open(snippet, encoding="utf-8").read().split("\n") if l.strip()]
    record = load_owned(owned_path)
    owned = set(record.get(real, [])) | known_lines(snippet)
    lines = text.split("\n")
    kept = [l for l in lines if norm(l) not in owned]
    text = "\n".join(kept)
    before = omarchy_items(text)
    if before is None:
        print(f"{menu} is not a menu Omarchy can read; menu left unchanged", file=sys.stderr)
        return 1
    if PARENT in before:
        print(f'left the menu alone: "{PARENT}" already exists in {menu} and is not tvcast\'s', file=sys.stderr)
        return 1
    add = []
    skipped = []
    for l in snip:
        m = KEY.search(l)
        if m and m.group(1) in before:
            skipped.append(m.group(1))
        else:
            add.append(l)
    eol = "\r\n" if text.count("\r\n") * 2 > text.count("\n") else "\n"
    block = "".join(l + eol for l in add)
    start = target_open(text)
    if start is None:
        sep = eol if text and not text.endswith("\n") else ""
        out = text + sep + "{" + eol + block + "}" + eol
    else:
        pos = start + 1
        if text.startswith("\r\n", pos):
            pos += 2
        elif text.startswith("\n", pos):
            pos += 1
        else:
            block = eol + block
        out = text[:pos] + block + text[pos:]
    after = omarchy_items(out)
    want = {m.group(1) for l in add for m in KEY.finditer(l)}
    if after is None or not want <= after.keys() or any(after.get(k) != v for k, v in before.items()):
        print(f"could not add tvcast's entries where Omarchy reads them in {menu}; menu left unchanged", file=sys.stderr)
        return 1
    new = out.encode("utf-8", "surrogateescape")
    if new == data and found is not None:
        if record.get(real) != add:
            record[real] = add
            save_owned(owned_path, record)
        print(f"tvcast's menu entries are already in {menu}")
    else:
        bak = backup(real, os.path.dirname(os.path.abspath(menu)), data) if found else None
        try:
            record[real] = sorted(set(record.get(real, [])) | set(add))
            save_owned(owned_path, record)
            write_atomic(real, new)
        except BaseException:
            if bak:
                os.unlink(bak)
            raise
        record[real] = add
        save_owned(owned_path, record)
        print(f"added menu entries (Trigger > Cast to TV) to {menu}" + (f"; backup: {bak}" if bak else ""))
    for k in skipped:
        print(f'kept your own "{k}" entry; tvcast did not add its version', file=sys.stderr)
    return 0


def uninstall(owned_path, menu=None):
    record = load_owned(owned_path)
    extra = known_lines(os.path.join(HERE, "omarchy-menu.snippet.jsonc"))
    live = os.path.realpath(menu) if menu else None
    targets = sorted(record)
    if live and live not in record:
        targets.append(live)
    failed = False
    for real in targets:
        recorded = real in record
        owned = set(record.get(real, [])) | extra
        try:
            found = menu_file(real)
        except OSError as e:
            print(f"could not read {real}: {e}; run this again once it can be read", file=sys.stderr)
            failed = True
            continue
        if found is None:
            if recorded and not os.path.isdir(os.path.dirname(real)):
                print(f"{os.path.dirname(real)} is missing (unmounted?); kept the record of tvcast's lines in {real}. "
                      f"To forget them, remove {owned_path}", file=sys.stderr)
                failed = True
                continue
            if recorded:
                print(f"{real} no longer exists; nothing to remove there")
            record.pop(real, None)
            continue
        data, nlink = found
        text = data.decode("utf-8", "surrogateescape")
        lines = text.split("\n")
        kept = [l for l in lines if norm(l) not in owned]
        present = sorted({norm(l) for l in lines if norm(l) in owned})
        out = "\n".join(kept)
        after = omarchy_items(out)
        if present and not recorded:
            record[real] = present
        if present and omarchy_items(text) is None:
            print(f"{real} is not a menu Omarchy can read; left it and the record as they are", file=sys.stderr)
            failed = True
            continue
        if present:
            if nlink > 1:
                print(f"{real} is hard-linked ({nlink} links); remove tvcast's entries by hand. Kept the record", file=sys.stderr)
                failed = True
                continue
            if after is None:
                print(f"removing tvcast's entries would break {real}; left it and the record as they are", file=sys.stderr)
                failed = True
                continue
            where = os.path.dirname(os.path.abspath(menu)) if live == real else os.path.dirname(real)
            bak = None
            try:
                bak = backup(real, where, data)
                write_atomic(real, out.encode("utf-8", "surrogateescape"))
            except OSError as e:
                if bak:
                    os.unlink(bak)
                print(f"could not clean {real}: {e}; kept the record so a rerun can finish", file=sys.stderr)
                failed = True
                continue
            print(f"removed tvcast's menu entries from {real} (backup: {bak})")
        left = cast_keys(after) if recorded or present else []
        if left:
            print(f"left in {real}: {' '.join(left)} (tvcast did not write them as they are now; "
                  "remove them by hand if they are edited tvcast entries)", file=sys.stderr)
        record.pop(real, None)
    save_owned(owned_path, record)
    return 1 if failed else 0


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "install" and len(sys.argv) == 5:
        sys.exit(install(sys.argv[2], sys.argv[3], sys.argv[4]))
    if cmd == "uninstall" and len(sys.argv) in (3, 4):
        sys.exit(uninstall(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None))
    sys.exit("usage: menu-edit.py install MENU SNIPPET RECORD | uninstall RECORD [MENU]")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RecursionError) as e:
        sys.exit(f"menu edit failed: {e}")
