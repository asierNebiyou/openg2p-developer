#!/usr/bin/env python3
"""Check deployment-pin coherence across the local stack and the variant repos.

The failures this exists to catch, all seen for real in this stack:

  * a variant's thin Dockerfiles (ARG RP_VERSION) and its Helm chart's
    openg2p-registry dependency drifting apart, so the image is built FROM one
    platform build while the chart deploys another;
  * a "1.1.3" image whose build manifest actually pinned platform 1.1.2;
  * the shared registry staff UI image pinned to a different platform version
    than the product APIs it talks to (blank dropdowns, 401s on /get-all-languages);
  * floating :latest / :develop tags on registry images, so `docker compose up`
    can get a different build than the one just built locally.

Read-only. Exit code 1 if anything is incoherent, so it can gate CI.
Variant repos that are not cloned are reported as skipped, not failed.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
VERSIONS = ROOT / "versions.yaml"

# variant key in versions.yaml -> (chart dir relative to the product repo)
VARIANT_CHARTS = {
    "national_social_registry": "helm/mowsa-nsr",
    "village_social_security_registry": "helm/vsss",
    "farmer_registry": None,  # no wrapper chart in this repo's workflow
}

MOVING_NAMES = {"latest", "develop", "main", "master", "edge", "nightly", "stable"}


def is_moving_tag(ref: str) -> bool:
    """True when the tag can point at different content over time.

    :latest and :develop are the obvious ones, but a bare major or major.minor
    tag moves too: asierneb/openg2p-nsr-celery:1.2 is whatever 1.2.x was pushed
    last. Only a full major.minor.patch (optionally with a prerelease suffix) or
    a digest is immutable in practice.
    """
    if "@sha256:" in ref:
        return False
    tag = ref.rsplit(":", 1)[-1] if ":" in ref.rsplit("/", 1)[-1] else ""
    if not tag:
        return True  # no tag at all == :latest
    if tag.lower() in MOVING_NAMES:
        return True
    return bool(re.fullmatch(r"\d+(\.\d+)?", tag))


problems: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


def skip(msg: str) -> None:
    notes.append(msg)
    print(f"  skip  {msg}")


def workspace_root(data: dict) -> Path:
    env = os.environ.get("OPENG2P_WORKSPACE")
    if env:
        return Path(env).expanduser().resolve()
    default = (data.get("workspace") or {}).get("default_path", "../openg2p-workspace")
    return (ROOT / default).resolve()


def docker_pins(repo: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for df in sorted((repo / "docker").glob("*/Dockerfile")):
        m = re.search(r"^ARG RP_VERSION=(\S+)", df.read_text(encoding="utf-8", errors="replace"), re.M)
        if m:
            pins[df.relative_to(repo).as_posix()] = m.group(1)
    return pins


def chart_registry_pin(chart_yaml: Path) -> str | None:
    m = re.search(
        r"-\s*name:\s*openg2p-registry\b.*?version:\s*(\S+)",
        chart_yaml.read_text(encoding="utf-8", errors="replace"),
        re.S,
    )
    return m.group(1) if m else None


def main() -> int:
    data = yaml.safe_load(VERSIONS.read_text(encoding="utf-8")) or {}
    images = data.get("images") or {}
    repos = data.get("repos") or {}
    rp = data.get("registry_platform_version")
    ws = workspace_root(data)

    print(f"versions.yaml : {VERSIONS}")
    print(f"workspace     : {ws}")
    print(f"platform pin  : {rp or '(not set)'}\n")

    print("1) registry_platform_version is declared")
    if not rp:
        fail("versions.yaml has no registry_platform_version — nothing to check variants against")
        return 1
    ok(f"registry_platform_version = {rp}")

    print("\n2) shared registry staff UI image matches the platform pin")
    ui = str(images.get("registry_staff_portal_ui", ""))
    ui_tag = ui.rsplit(":", 1)[-1] if ":" in ui else ""
    if not ui:
        fail("images.registry_staff_portal_ui is not set")
    elif ui_tag != rp:
        fail(
            f"registry_staff_portal_ui is {ui!r} (tag {ui_tag!r}) but the platform pin is {rp!r}; "
            "the UI and the product APIs must come from the same platform build"
        )
    else:
        ok(f"registry_staff_portal_ui tag {ui_tag} == platform pin")

    print("\n3) no moving tags on the OpenG2P application images")
    # Third-party infra (postgres, redis, keycloak, minio) commonly tracks a
    # minor tag on purpose; that is a choice, not drift. Only the OpenG2P-built
    # application images have to be immutable, because those are what a release
    # is made of.
    INFRA = {"postgres", "redis", "minio", "keycloak"}
    moving_app, moving_infra = {}, {}
    for k, v in images.items():
        if not is_moving_tag(str(v)) or k.startswith(("pbms", "g2p_bridge")):
            continue
        (moving_infra if k in INFRA else moving_app)[k] = v
    if moving_app:
        for k, v in sorted(moving_app.items()):
            fail(f"images.{k} = {v} — moving tag; a release cannot be reproduced from it")
    else:
        ok("every OpenG2P application image is pinned to an immutable tag")
    for k, v in sorted(moving_infra.items()):
        print(f"  note  images.{k} = {v} — tracks a minor tag (fine for infra, "
              "pin it if you need byte-identical rebuilds)")

    print("\n4) each variant repo pins the platform in lockstep (Dockerfiles + chart)")
    for key, chart_rel in VARIANT_CHARTS.items():
        spec = repos.get(key)
        if not spec:
            skip(f"{key}: not declared in versions.yaml repos")
            continue
        repo = ws / spec.get("path", key)
        if not repo.is_dir():
            skip(f"{key}: not cloned at {repo}")
            continue

        pins = docker_pins(repo)
        if not pins:
            skip(f"{key}: no ARG RP_VERSION in docker/*/Dockerfile (still on the fat build model)")
            continue

        values = set(pins.values())
        if len(values) != 1:
            fail(f"{key}: Dockerfile RP_VERSION pins disagree: " +
                 ", ".join(f"{p}={v}" for p, v in sorted(pins.items())))
            continue
        pin = values.pop()

        if chart_rel:
            chart_yaml = repo / chart_rel / "Chart.yaml"
            if chart_yaml.is_file():
                cpin = chart_registry_pin(chart_yaml)
                if cpin is None:
                    fail(f"{key}: {chart_rel}/Chart.yaml declares no openg2p-registry dependency")
                elif cpin != pin:
                    fail(f"{key}: Dockerfiles pin {pin} but {chart_rel}/Chart.yaml pins {cpin}")
                else:
                    ok(f"{key}: Dockerfiles and chart both pin {pin}")
            else:
                skip(f"{key}: {chart_rel}/Chart.yaml not found")
        else:
            ok(f"{key}: Dockerfiles pin {pin} (no wrapper chart to cross-check)")

        if pin != rp:
            fail(f"{key}: pins platform {pin} but versions.yaml declares {rp}")

    print("\n5) declared repo refs exist in the clone")
    for key, spec in repos.items():
        path = (spec or {}).get("path")
        ref = (spec or {}).get("ref")
        if not path or not ref:
            continue
        repo = ws / path
        if not (repo / ".git").exists():
            continue
        import subprocess
        r = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            r2 = subprocess.run(
                ["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"origin/{ref}^{{commit}}"],
                capture_output=True, text=True,
            )
            if r2.returncode != 0:
                fail(f"repos.{key}.ref = {ref!r} does not resolve in {repo} (nor as origin/{ref})")
            else:
                ok(f"repos.{key}.ref = {ref} (via origin/{ref})")
        else:
            ok(f"repos.{key}.ref = {ref}")

    print("\n" + "=" * 70)
    if problems:
        print(f"{len(problems)} pin problem(s):")
        for p in problems:
            print(f"  - {p}")
    else:
        print("All pins coherent.")
    if notes:
        print(f"\n{len(notes)} skipped (not cloned / not applicable):")
        for n in notes:
            print(f"  - {n}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
