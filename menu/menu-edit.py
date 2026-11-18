import json, os, re, sys, tempfile

KEY = re.compile(r'"(trigger\.cast(?:\.[a-z]+)?)"\s*:')
PARENT = "trigger.cast"


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
    taken = {m.group(1) for l in kept for m in KEY.finditer(l)}
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
    text = "\n".join(kept)
    end = text.rstrip().rfind("}")
    if end < 0:
        print(f"{menu} has no closing brace; menu left unchanged", file=sys.stderr)
        return 1
    head = text[:end].rstrip()
    if head and not head.endswith(("{", ",")):
        head += ","
    write_atomic(menu, head + "\n" + "\n".join(add) + "\n" + text[end:])
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
        write_atomic(menu, "\n".join(kept))
        print("removed tvcast's menu entries (backup saved)")
    os.unlink(owned_path)
    return 0


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "install":
        sys.exit(install(sys.argv[2], sys.argv[3], sys.argv[4]))
    if cmd == "uninstall":
        sys.exit(uninstall(sys.argv[2], sys.argv[3]))
    sys.exit(f"unknown command {cmd}")
