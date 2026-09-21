#!/usr/bin/env python3
"""Render the macOS Mihomo Codex sidecar config.

Keeps the official v2.7.2 semantics: mixed-port 3101, HTTP proxy-providers,
health-check, and a CODEX-ROTATE round-robin group. Extra providers are only
added so more than one airport subscription / local snapshot can share the same
rotate group. Subscription URLs never go to stdout.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

SKIP_LINE = re.compile(r"静态前置|住宅静态|香港|🇭🇰|Hong\s*Kong|HongKong")
SKIP_NAME = re.compile(
    r"(剩余|到期|官网|流量|套餐|通知|更新|过期|重置|距离下次|到期时间|香港|🇭🇰|Hong\s*Kong|HongKong)"
)
FLOW_NAME = re.compile(r"\{\s*name:\s*([^,}]+?)\s*,")
BLOCK_NAME = re.compile(r"^\s+-\s+name:\s+[\"']?(.+?)[\"']?\s*$", re.MULTILINE)
EXCLUDE_FILTER = (
    r"(剩余|到期|官网|流量|套餐|通知|更新|过期|重置|距离下次|静态前置|住宅静态|"
    r"香港|🇭🇰|Hong\s*Kong|HongKong)"
)


def yq(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def load_env_file(path: Path) -> None:
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue
        os.environ[key] = value.strip().strip("'\"")


def subscription_urls() -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for key in (
        "MIHOMO_CODEX_SUBSCRIPTION_URL",
        "MIHOMO_CODEX_SUBSCRIPTION_URL_2",
        "MIHOMO_CODEX_SUBSCRIPTION_URL_3",
    ):
        value = os.environ.get(key, "").strip()
        if value:
            urls.append(value)
    extra = os.environ.get("MIHOMO_CODEX_SUBSCRIPTION_URLS", "")
    for part in re.split(r"[\n,;]+", extra):
        value = part.strip()
        if value:
            urls.append(value)
    unique: list[str] = []
    for url in urls:
        if url in seen:
            continue
        seen.add(url)
        unique.append(url)
    if not unique:
        raise RuntimeError("missing MIHOMO_CODEX_SUBSCRIPTION_URL")
    return unique


def local_sources() -> list[Path]:
    raw = os.environ.get("MIHOMO_CODEX_LOCAL_SOURCES", "").strip()
    if raw:
        items = [Path(part.strip()).expanduser() for part in re.split(r"[\n,;]+", raw) if part.strip()]
    else:
        config_dir = Path.home() / ".config/clash.meta"
        items = [config_dir / "白嫖.yaml", config_dir / "赔钱机场.yaml"]
    return [path for path in items if path.is_file()]


def extract_proxy_body(text: str) -> str:
    match = re.search(r"(?ms)^proxies:\n(.*?)(?=^proxy-groups:)", text)
    if not match:
        return ""
    lines: list[str] = []
    for line in match.group(1).splitlines(keepends=True):
        if SKIP_LINE.search(line):
            continue
        if line.startswith("# BEGIN LOCAL") or line.startswith("# END LOCAL"):
            continue
        lines.append(line)
    return "".join(lines).strip("\n") + ("\n" if lines else "")


def count_leaf_names(body: str) -> int:
    names: set[str] = set()
    for raw in FLOW_NAME.findall(body) + BLOCK_NAME.findall(body):
        name = raw.strip().strip("\"'")
        if name and not SKIP_NAME.search(name):
            names.add(name)
    return len(names)


def render_http_provider(name: str, url: str, relpath: str, prefix: str) -> str:
    return (
        "  {name}:\n"
        "    type: http\n"
        "    url: {url}\n"
        "    interval: 3600\n"
        "    path: {path}\n"
        "    proxy: SUB-FETCH\n"
        "    header:\n"
        "      User-Agent:\n"
        "        - clash.meta\n"
        "    health-check:\n"
        "      enable: true\n"
        "      url: https://www.gstatic.com/generate_204\n"
        "      interval: 300\n"
        "      timeout: 5000\n"
        "    exclude-filter: {exclude}\n"
        "    override:\n"
        "      additional-prefix: {prefix}\n"
    ).format(
        name=name,
        url=yq(url),
        path=yq(relpath),
        exclude=yq(EXCLUDE_FILTER),
        prefix=yq(prefix),
    )


def render_file_provider(name: str, relpath: str, prefix: str) -> str:
    return (
        "  {name}:\n"
        "    type: file\n"
        "    path: {path}\n"
        "    health-check:\n"
        "      enable: true\n"
        "      url: https://www.gstatic.com/generate_204\n"
        "      interval: 300\n"
        "      timeout: 5000\n"
        "    exclude-filter: {exclude}\n"
        "    override:\n"
        "      additional-prefix: {prefix}\n"
    ).format(
        name=name,
        path=yq(relpath),
        exclude=yq(EXCLUDE_FILTER),
        prefix=yq(prefix),
    )


def main() -> int:
    data_dir = Path(os.environ.get("MIHOMO_CODEX_DATA", "")).expanduser()
    if not data_dir:
        raise RuntimeError("MIHOMO_CODEX_DATA is required")
    load_env_file(data_dir / "subscriptions.env")
    secret_path = Path(os.environ.get("MIHOMO_CODEX_SECRET_FILE", str(data_dir / "controller.secret")))
    if not secret_path.is_file():
        raise RuntimeError("controller secret missing")
    secret = secret_path.read_text(encoding="utf-8").strip()
    if not secret:
        raise RuntimeError("controller secret empty")

    port = os.environ.get("MIHOMO_CODEX_PORT", "3101")
    controller = os.environ.get("MIHOMO_CODEX_CONTROLLER", "127.0.0.1:9098")
    fetch_port = os.environ.get("MIHOMO_CODEX_FETCH_PORT", "7890")
    providers_dir = data_dir / "providers"
    providers_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(providers_dir, 0o700)

    provider_blocks: list[str] = []
    rotate: list[str] = []
    summary: list[dict] = []

    for index, url in enumerate(subscription_urls(), start=1):
        name = "airport" if index == 1 else "airport{}".format(index)
        relpath = "./providers/{}.yaml".format(name)
        prefix = "a{}-".format(index)
        provider_blocks.append(render_http_provider(name, url, relpath, prefix))
        rotate.append(name)
        summary.append({"name": name, "kind": "http", "index": index})

    for index, source in enumerate(local_sources(), start=1):
        body = extract_proxy_body(source.read_text(encoding="utf-8"))
        if not body.strip():
            continue
        name = "local{}".format(index)
        filename = "local-{}.yaml".format(index)
        dest = providers_dir / filename
        dest.write_text("proxies:\n" + body, encoding="utf-8")
        os.chmod(dest, 0o600)
        provider_blocks.append(
            render_file_provider(name, "./providers/" + filename, "l{}-".format(index))
        )
        rotate.append(name)
        summary.append(
            {
                "name": name,
                "kind": "file",
                "leaves": count_leaf_names(body),
                "source": source.name,
            }
        )

    if not rotate:
        raise RuntimeError("no harvest providers")

    use_lines = "".join("      - {}\n".format(name) for name in rotate)
    directed_port = int(os.environ.get("MIHOMO_CODEX_DIRECTED_PORT", "3102"))
    if not 1 <= directed_port <= 65535 or directed_port == int(port):
        raise RuntimeError("invalid MIHOMO_CODEX_DIRECTED_PORT")
    config = (
        "mixed-port: {port}\n"
        "allow-lan: false\n"
        "bind-address: 127.0.0.1\n"
        "mode: rule\n"
        "log-level: warning\n"
        "ipv6: false\n"
        "external-controller: {controller}\n"
        "secret: {secret}\n"
        "listeners:\n"
        "  - name: codex-harvest-directed\n"
        "    type: mixed\n"
        "    listen: 127.0.0.1\n"
        "    port: {directed_port}\n"
        "    proxy: CODEX-HARVEST-SELECT\n"
        "proxies:\n"
        "  - name: SUB-FETCH\n"
        "    type: http\n"
        "    server: 127.0.0.1\n"
        "    port: {fetch_port}\n"
        "proxy-providers:\n"
        "{providers}"
        "proxy-groups:\n"
        "  - name: CODEX-HARVEST-SELECT\n"
        "    type: select\n"
        "    use:\n"
        "{use_lines}"
        "    exclude-filter: {exclude}\n"
        "  - name: CODEX-ROTATE\n"
        "    type: load-balance\n"
        "    strategy: round-robin\n"
        "    use:\n"
        "{use_lines}"
        "    exclude-filter: {exclude}\n"
        "    url: https://www.gstatic.com/generate_204\n"
        "    interval: 180\n"
        "    timeout: 5000\n"
        "rules:\n"
        "  - MATCH,CODEX-ROTATE\n"
    ).format(
        port=port,
        directed_port=directed_port,
        controller=controller,
        secret=secret,
        fetch_port=fetch_port,
        providers="".join(provider_blocks),
        use_lines=use_lines,
        exclude=yq(EXCLUDE_FILTER),
    )
    config_path = data_dir / "config.yaml"
    config_path.write_text(config, encoding="utf-8")
    os.chmod(config_path, 0o600)
    print(json.dumps({"ok": True, "providers": summary, "rotate": rotate}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)