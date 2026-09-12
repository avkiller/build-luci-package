#!/usr/bin/env python3
import hashlib, json, os, subprocess, sys
from pathlib import Path

spec, feed_name, arch, pkg_type, sdk, root, out = sys.argv[1:8]
here = Path(__file__).resolve().parent
meta = os.environ.get("PKG_META", str(here / "pkg-meta.sh"))
out = Path(out); out.mkdir(parents=True, exist_ok=True)
root = Path(root)

def die(msg):
    print(f"collect: {msg}", file=sys.stderr); sys.exit(1)

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def names_for(mk):
    r = subprocess.run([str(here / "packageinfo-names.sh"), str(root / "tmp" / ".packageinfo"), mk],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die(r.stderr.strip() or f"no packages for {mk}")
    return [n for n in r.stdout.split("\n") if n]

def meta_of(path):
    r = subprocess.run([meta, str(path)], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"cannot read metadata of {path}")
    n, v, a = r.stdout.rstrip("\n").split("\t")
    return n, v, a

def outputs_for(name):
    base = root / "bin" / "packages" / arch
    found = []
    for p in base.rglob("*"):
        if not p.is_file():
            continue
        b = p.name
        if (b.startswith(name + "-") and b.endswith(".apk") and b[len(name) + 1:len(name) + 2].isdigit()) \
           or (b.startswith(name + "_") and b.endswith(".ipk")):
            found.append(p)
    return sorted(found)

packages = []
for e in json.load(open(spec)):
    pkg, kind, declared = e["pkg"], e["kind"], e.get("arch", "all")
    mk = f"package/feeds/{e['feed']}/{pkg}/Makefile" if kind == "feed" else f"package/feeds/{feed_name}/{pkg}/Makefile"
    files = []
    for name in names_for(mk):
        found = outputs_for(name)
        if not found:
            die(f"no output for {name} (from {pkg})")
        for f in found:
            n, v, a = meta_of(f)
            if n != name:
                die(f"{f} reports name {n}, expected {name}")
            if declared == "all":
                if a not in ("noarch", "all"):
                    die(f"{pkg} declares arch all but {f.name} is built for {a}")
            elif a != arch:
                die(f"{pkg} declares an arch-specific build but {f.name} is {a}, expected {arch}")
            dst = out / f.name
            dst.write_bytes(f.read_bytes())
            files.append({"file": f.name, "name": n, "version": v, "arch": a,
                          "size": f.stat().st_size, "sha256": sha256(f)})
    packages.append({"pkg": pkg, "kind": kind, "ref": e.get("ref", ""),
                     "declared_arch": declared, "files": files})

(out / "build-info.json").write_text(json.dumps(
    {"sdk": sdk, "arch": arch, "pkg_type": pkg_type, "packages": packages}, indent=1) + "\n")
