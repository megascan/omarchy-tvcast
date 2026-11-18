import json, os, re, sys, tempfile

KEY = re.compile(r'"(trigger\.cast(?:\.[a-z]+)?)"\s*:')
PARENT = "trigger.cast"


def strip_jsonc(raw):
    raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
    return re.sub(r",(\s*[}\]])", r"\1", raw)


def omarchy_items(text):
    stripped = strip_jsonc(text)
    if not stripped.strip():
        return {}
    try:
        parsed = json.loads(stripped)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    items = parsed.get("items")
    return items if isinstance(items, dict) else parsed


def target_close(text):
    """Index of the closing brace of the object Omarchy reads entries from."""
    stack = []
    pending_key = None
    last_key = None
    i, n = 0, len(text)
    root_close = None
    while i < n:
        c = text[i]
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
        if c == ":":
            pending_key = last_key if len(stack) == 1 else None
        elif c in "{[":
            stack.append(c == "{" and len(stack) == 1 and pending_key == "items")
            pending_key = None
        elif c in "}]":
            if not stack:
                return None
            if stack.pop():
                return i
            if not stack:
                root_close = i
        elif c == ",":
            pending_key = None
        i += 1
    return root_close


def read_lines(path):
    try:
        with open(path) as f:
            return f.read().split("\n")
    except FileNotFoundError:
        return None


def write_atomic(path, text, mode=None):
    real = os.path.realpath(path)
    fd, tmp = tempfile.mkstemp(prefix=".tvcast.", dir=os.path.dirname(real))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        if mode is None and os.path.exists(real):
            mode = os.stat(real).st_mode & 0o7777
        os.chmod(tmp, 0o600 if mode is None else mode)
        os.replace(tmp, real)
    except BaseException:
        os.unlink(tmp)
        raise


def load_owned(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return set(x for x in data.get("lines", []) if isinstance(x, str))
    except (FileNotFoundError, ValueError, AttributeError):
        return set()


def install(menu, snippet, owned_path):
    lines = read_lines(menu)
    snip = [l for l in open(snippet).read().split("\n") if l.strip()]
    owned = load_owned(owned_path) | set(snip)
    kept = [l for l in lines if l not in owned]
    text = "\n".join(kept)
    before = omarchy_items(text)
    end = target_close(text)
    if before is None or end is None:
        print(f"{menu} is not a menu Omarchy can read; menu left unchanged", file=sys.stderr)
        return 1
    taken = set(before)
    if PARENT in taken:
        print(f'left the menu alone: "{PARENT}" already exists in {menu} and is not tvcast\'s', file=sys.stderr)
        return 1
    add = []
    skipped = []
    for l in snip:
        m = KEY.search(l)
        if m and m.group(1) in taken:
            skipped.append(m.group(1))
        else:
            add.append(l)
    head = text[:end].rstrip()
    if head and not head.endswith(("{", ",")):
        head += ","
    out = head + "\n" + "\n".join(add) + "\n" + text[end:].lstrip(" \t")
    after = omarchy_items(out)
    want = {m.group(1) for l in add for m in KEY.finditer(l)}
    if after is None or not want <= after.keys() or any(after.get(k) != v for k, v in before.items()):
        print(f"could not add tvcast's entries where Omarchy reads them in {menu}; menu left unchanged", file=sys.stderr)
        return 1
    write_atomic(owned_path, json.dumps({"menu": os.path.realpath(menu), "lines": sorted(load_owned(owned_path) | set(add))}, indent=1) + "\n", 0o600)
    write_atomic(menu, out)
    write_atomic(owned_path, json.dumps({"menu": os.path.realpath(menu), "lines": add}, indent=1) + "\n", 0o600)
    for k in skipped:
        print(f'kept your own "{k}" entry; tvcast did not add its version', file=sys.stderr)
    return 0


def uninstall(menu, owned_path):
    owned = load_owned(owned_path)
    lines = read_lines(menu)
    if not owned or lines is None:
        return 0
    kept = [l for l in lines if l not in owned]
    if len(kept) != len(lines):
        out = "\n".join(kept)
        if omarchy_items("\n".join(lines)) is not None and omarchy_items(out) is None:
            print(f"removing tvcast's entries would break {menu}; left it and the ownership record as they are", file=sys.stderr)
            return 1
        write_atomic(menu, out)
        print("removed tvcast's menu entries (backup saved)")
    os.unlink(owned_path)
    return 0


def main():
    cmd = sys.argv[1]
    if cmd == "install":
        sys.exit(install(sys.argv[2], sys.argv[3], sys.argv[4]))
    if cmd == "uninstall":
        sys.exit(uninstall(sys.argv[2], sys.argv[3]))
    sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        sys.exit(f"menu edit failed: {e}")
