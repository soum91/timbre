"""One-off: add build numbers to IPA asset names and changelogs to existing releases.

Run by .github/workflows/backfill-releases.yml (Actions tab -> Run workflow).
Safe to run more than once: it rewrites names and notes to the same values.
"""
import json, os, re, subprocess

REPO = os.environ["GITHUB_REPOSITORY"]
APP = os.environ["APP"]
INSTALL = os.environ["INSTALL"]
FINDMY_STYLE = os.environ.get("TITLE_STYLE") == "v1.0"
# Optional rolling "latest" release to convert into a numbered one: "<build>:<previous build's commit>"
ROLLING = os.environ.get("ROLLING", "")


def sh(*a):
    return subprocess.run(a, check=True, capture_output=True, text=True).stdout.strip()


def api(path, method="GET", data=None):
    cmd = ["gh", "api", "-X", method, path]
    if data is not None:
        cmd += ["--input", "-"]
    out = subprocess.run(cmd, input=json.dumps(data) if data is not None else None, capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(f"{method} {path}: {out.stderr} {out.stdout}")
    return json.loads(out.stdout) if out.stdout.strip() else None


def version_at(sha):
    y = sh("git", "show", f"{sha}:project.yml")
    m = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)', y) or re.search(r'CFBundleShortVersionString:\s*"?([0-9.]+)', y)
    return m.group(1)


def notes(ver, build, sha, prev_sha, prev_label):
    out = [f"## {APP} {ver} (build {build})", ""]
    if prev_sha:
        out += [f"### Changes since {prev_label}", ""]
        log = sh("git", "log", f"{prev_sha}..{sha}", "--no-merges", "--pretty=- %s (%h)")
        out.append(log or f"- No code changes since {prev_label} (rebuild)")
    else:
        out += ["### Changes", ""]
        out.append(sh("git", "log", sha, "--no-merges", "--pretty=- %s (%h)"))
    out += ["", "---", f"Built from `{sh('git', 'rev-parse', '--short', sha)}`. {INSTALL}"]
    return "\n".join(out)


# Optional tags that were created on the wrong commit: "tag:sha tag:sha"
TAG_FIXES = dict(x.split(":", 1) for x in os.environ.get("TAG_FIXES", "").split())
for t, s in TAG_FIXES.items():
    full = sh("git", "rev-parse", f"{s}^{{commit}}")
    api(f"repos/{REPO}/git/refs/tags/{t}", "PATCH", {"sha": full, "force": True})
    print(f"moved tag {t} -> {full[:7]}")

items = []
for r in api(f"repos/{REPO}/releases?per_page=100"):
    ipa = [a for a in r["assets"] if a["name"].endswith(".ipa")]
    if not ipa:
        continue
    tag = r["tag_name"]
    if tag == "latest":
        if not ROLLING:
            continue
        build = int(ROLLING.split(":")[0])
    else:
        build = int(re.search(r"(\d+)$", tag).group(1))
    sha = sh("git", "rev-parse", f"{TAG_FIXES.get(tag, f'refs/tags/{tag}')}^{{commit}}")
    items.append((build, tag, sha, r, ipa[0]))
items.sort(key=lambda x: x[0])

prev = None
for build, tag, sha, r, asset in items:
    ver = version_at(sha)
    if tag == "latest":
        prev_sha, prev_label = ROLLING.split(":")[1], f"build {build - 1}"
    elif prev:
        prev_sha, prev_label = prev[2], prev[1]
    else:
        prev_sha, prev_label = None, None
    new_tag = f"build-{build}" if tag == "latest" else tag
    title = f"{APP} v1.0.{build} (build {build})" if FINDMY_STYLE else f"{APP} {ver} build {build}"
    new_name = f"{APP}-{ver}-build-{build}.ipa"
    patch = {"name": title, "body": notes(ver, build, sha, prev_sha, prev_label)}
    if tag == "latest":
        try:
            api(f"repos/{REPO}/git/refs", "POST", {"ref": f"refs/tags/{new_tag}", "sha": sha})
        except RuntimeError as e:
            if "already exists" not in str(e):
                raise
        patch.update({"tag_name": new_tag, "target_commitish": sha, "prerelease": False})
    api(f"repos/{REPO}/releases/{r['id']}", "PATCH", patch)
    if asset["name"] != new_name:
        api(f"repos/{REPO}/releases/assets/{asset['id']}", "PATCH", {"name": new_name})
    if tag == "latest":
        api(f"repos/{REPO}/git/refs/tags/latest", "DELETE")
    print(f"{tag} -> {new_tag}: {asset['name']} -> {new_name}")
    prev = (build, new_tag, sha)
