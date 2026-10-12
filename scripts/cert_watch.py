#!/usr/bin/env python3
"""
Следит за корневыми сертификатами CDN, с которых VK Video Live отдаёт видео.

1. Запрашивает API VK (как плагин) для ссылок из scripts/cdn-probe.json
   и собирает хосты из playerUrls, включая варианты и сегменты внутри .m3u8.
2. К каждому хосту подключается с проверкой по СИСТЕМНОМУ хранилищу
   (на runner'е это список Mozilla из ca-certificates) плюс вручную
   проверенным корням из certs/extra/. Корень берётся из проверенной
   цепочки, а не из того, что прислал сервер.
3. Если корня нет в TRUST_PEM (src/vkplay.lua), добавляет его туда.
   Workflow оформляет это как pull request на ревью.
4. Хост, чья цепочка не проверяется даже по системному хранилищу, ничего
   не добавляет: это ошибка, решение принимает человек.

Требуется Python 3.13+ (ssl.SSLSocket.get_verified_chain) и openssl в PATH.

  python scripts/cert_watch.py                  # по cdn-probe.json
  python scripts/cert_watch.py --host a.b.c     # проверить конкретные хосты
  python scripts/cert_watch.py --add-root ca.cer --name russian-trusted-root-ca
                                                # добавить вручную проверенный корень
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path
from urllib.parse import urljoin, urlsplit

ROOT = Path(__file__).resolve().parent.parent
LUA = ROOT / "src" / "vkplay.lua"
CONFIG = ROOT / "scripts" / "cdn-probe.json"
EXTRA_DIR = ROOT / "certs" / "extra"
PR_BODY = ROOT / "build" / "cert-watch-pr.md"

API = "https://api.live.vkvideo.ru/v1/blog/"
UA = "VLC/3.0.21 LibVLC/3.0.21"
MIN_ROOT_LIFETIME = dt.timedelta(days=3 * 365)   # предупреждать заранее
MAX_PLAYLIST_BYTES = 2_000_000

TRUST_RE = re.compile(r"(local TRUST_PEM = \[\[\n)(.*?)(\]\])", re.S)
PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----\n.*?-----END CERTIFICATE-----\n?", re.S)


# ---------- сбор хостов ------------------------------------------------------

def http_get(url: str, limit: int = MAX_PLAYLIST_BYTES) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read(limit).decode("utf-8", "replace")


def entry_from_url(url: str) -> dict:
    parts = [p for p in urlsplit(url).path.split("/") if p]
    if not parts:
        raise ValueError(f"нет канала в ссылке: {url}")
    if len(parts) >= 3 and parts[1] == "record":
        return {"channel": parts[0], "record": parts[2]}
    return {"channel": parts[0]}


def player_urls(entry: dict) -> list[str]:
    ch = entry["channel"]
    if entry.get("record"):
        data = json.loads(http_get(f"{API}{ch}/public_video_stream/record/{entry['record']}"))
        items = ((data.get("data") or {}).get("record") or {}).get("data") or []
    else:
        data = json.loads(http_get(f"{API}{ch}/public_video_stream?from=layer"))
        items = data.get("data") or []
    return [p["url"] for it in items[:1] for p in (it.get("playerUrls") or []) if p.get("url")]


def playlist_children(url: str, text: str) -> list[str]:
    out = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            out += [urljoin(url, u) for u in re.findall(r'URI="([^"]+)"', line)]
        else:
            out.append(urljoin(url, line))
    return out


def collect_hosts(urls: list[str], depth: int = 2) -> set[str]:
    hosts, seen = set(), set()
    queue = [(u, 0) for u in urls]
    while queue:
        url, d = queue.pop(0)
        if url in seen:
            continue
        seen.add(url)
        parts = urlsplit(url)
        if parts.scheme != "https" or not parts.hostname:
            continue
        hosts.add(parts.hostname)
        if d >= depth or ".m3u8" not in parts.path:
            continue
        try:
            children = playlist_children(url, http_get(url))
        except Exception as e:  # noqa: BLE001
            print(f"::warning::cannot read playlist {parts.hostname}: {e}")
            continue
        # из каждого плейлиста достаточно пары ссылок: хосты повторяются
        queue += [(c, d + 1) for c in children[:3]]
    return hosts


# ---------- сертификаты ------------------------------------------------------

def load_cert_file(path: Path) -> bytes:
    raw = path.read_bytes()
    if b"-----BEGIN CERTIFICATE-----" in raw:
        pems = PEM_RE.findall(raw.decode("ascii", "replace").replace("\r\n", "\n"))
        if len(pems) != 1:
            raise ValueError(f"{path}: ожидался ровно один сертификат, найдено {len(pems)}")
        return pem_to_der(pems[0])
    return raw  # DER (.cer / .crt с Госуслуг обычно в DER)


def der_to_pem(der: bytes) -> str:
    b64 = base64.b64encode(der).decode()
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(
        b64[i:i + 64] for i in range(0, len(b64), 64)) + "\n-----END CERTIFICATE-----\n"


def extra_roots() -> list[bytes]:
    return [load_cert_file(p) for p in sorted(EXTRA_DIR.glob("*.pem"))] if EXTRA_DIR.is_dir() else []


def check_root_ca(der: bytes) -> None:
    """Самоподписанный CA-сертификат, иначе ошибка."""
    out = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-nameopt", "RFC2253",
         "-subject", "-issuer", "-ext", "basicConstraints"],
        input=der, capture_output=True, check=True).stdout.decode()
    subject = re.search(r"^subject=(.*)$", out, re.M).group(1).strip()
    issuer = re.search(r"^issuer=(.*)$", out, re.M).group(1).strip()
    if subject != issuer:
        raise ValueError(f"это не корень: issuer {issuer} != subject {subject}")
    if "CA:TRUE" not in out:
        raise ValueError("нет basicConstraints CA:TRUE")
    # Подпись самоподписанного корня (без -check_ss_sig OpenSSL её не проверяет)
    with tempfile.TemporaryDirectory() as tmp:
        pem = Path(tmp) / "root.pem"
        pem.write_text(der_to_pem(der), encoding="ascii")
        r = subprocess.run(["openssl", "verify", "-no-CAfile", "-no-CApath", "-check_ss_sig",
                            "-CAfile", str(pem), str(pem)], capture_output=True, text=True)
        if r.returncode != 0:
            raise ValueError("самоподпись не проверяется: " + (r.stdout + r.stderr).strip())


def verified_root(host: str, extras: list[bytes]) -> bytes:
    ctx = ssl.create_default_context()
    # Python 3.13 включает X509_STRICT, которого нет в GnuTLS VLC:
    # проверяем так же, как VLC, иначе будут ложные срабатывания
    ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
    for der in extras:
        ctx.load_verify_locations(cadata=der)
    with socket.create_connection((host, 443), timeout=15) as s:
        with ctx.wrap_socket(s, server_hostname=host) as t:
            return t.get_verified_chain()[-1]


def cert_info(der: bytes) -> tuple[str, dt.datetime]:
    out = subprocess.run(
        ["openssl", "x509", "-inform", "DER", "-noout", "-nameopt", "RFC2253", "-subject", "-enddate"],
        input=der, capture_output=True, check=True).stdout.decode()
    subject = re.search(r"^subject=(.*)$", out, re.M).group(1).strip()
    end = re.search(r"^notAfter=(.*)$", out, re.M).group(1).strip()
    return subject, dt.datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)


def sha1(der: bytes) -> str:
    return hashlib.sha1(der).hexdigest().upper()


def pem_to_der(pem: str) -> bytes:
    body = "".join(l for l in pem.splitlines() if l and not l.startswith("-----"))
    return base64.b64decode(body)


def render_trust(roots: list[bytes]) -> str:
    """TRUST_PEM: корни с комментариями, по порядку сроков действия (дольше живущий первым)."""
    blocks = []
    for der in sorted(roots, key=lambda d: cert_info(d)[1], reverse=True):
        subject, end = cert_info(der)
        blocks.append(f"# {subject}\n# SHA-1 {sha1(der)}  notAfter {end:%Y-%m-%d}\n" + der_to_pem(der))
    return "".join(blocks)


# ---------- main -------------------------------------------------------------

def write_trust(lua: str, m: re.Match, roots: list[bytes]) -> None:
    LUA.write_text(lua[:m.start(2)] + render_trust(roots) + lua[m.end(2):], encoding="utf-8")


def add_root(path: Path, name: str, lua: str, m: re.Match, bundled: list[bytes]) -> int:
    der = load_cert_file(path)
    check_root_ca(der)
    subject, end = cert_info(der)
    fp1, fp256 = sha1(der), hashlib.sha256(der).hexdigest().upper()
    print(f"Subject : {subject}\nnotAfter: {end:%Y-%m-%d}\nSHA-1   : {fp1}\nSHA-256 : {fp256}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name):
        print("::error::--name: только a-z, 0-9, . _ -")
        return 1
    EXTRA_DIR.mkdir(parents=True, exist_ok=True)
    target = EXTRA_DIR / f"{name}.pem"
    target.write_text(f"# {subject}\n# SHA-256 {fp256}\n" + der_to_pem(der), encoding="ascii", newline="\n")
    if fp1 not in {sha1(d) for d in bundled}:
        write_trust(lua, m, bundled + [der])
    print(f"Сохранён {target.relative_to(ROOT)} и добавлен в TRUST_PEM. Сверьте SHA-256 выше с официальным.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", action="append", default=[], help="проверить хост вместо cdn-probe.json")
    ap.add_argument("--render", action="store_true", help="только переформатировать TRUST_PEM")
    ap.add_argument("--add-root", type=Path, metavar="FILE", help="добавить вручную проверенный корень (PEM/DER)")
    ap.add_argument("--name", help="имя файла в certs/extra/ для --add-root")
    args = ap.parse_args()

    lua = LUA.read_text(encoding="utf-8")
    m = TRUST_RE.search(lua)
    if not m:
        print("::error::TRUST_PEM не найден в src/vkplay.lua")
        return 1
    bundled = [pem_to_der(p) for p in PEM_RE.findall(m.group(2))]
    bundled_ids = {sha1(d) for d in bundled}

    if args.add_root:
        try:
            return add_root(args.add_root, args.name or args.add_root.stem.lower(), lua, m, bundled)
        except (ValueError, OSError, subprocess.CalledProcessError) as ex:
            print(f"::error::--add-root {args.add_root}: {ex}")
            return 1
    if args.render:
        write_trust(lua, m, bundled)
        return 0

    # Ручные корни обязаны быть в плагине: иначе CI проверил бы то, чего нет у пользователей
    extras = extra_roots()
    missing = [cert_info(d)[0] for d in extras if sha1(d) not in bundled_ids]
    if missing:
        print("::error::certs/extra/ содержит корни, которых нет в TRUST_PEM: " + "; ".join(missing)
              + ". Добавляйте ручные корни только через: python scripts/cert_watch.py --add-root FILE --name NAME")
        return 1
    extra_ids = {sha1(d) for d in extras}

    # хосты
    hosts = set(args.host)
    if not hosts:
        cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
        for url in cfg.get("urls", []):
            try:
                urls = player_urls(entry_from_url(url))
            except Exception as ex:  # noqa: BLE001
                print(f"::warning::API {url}: {ex}")
                continue
            if not urls:
                print(f"{url}: offline / нет playerUrls")
                continue
            found = collect_hosts(urls)
            print(f"{url}: {', '.join(sorted(found))}")
            hosts |= found
    if not hosts:
        print("::warning::Не найдено ни одного хоста: проверьте ссылки на записи в scripts/cdn-probe.json.")
        return 0

    # проверка
    rows, failures, new_roots, used = [], [], [], set()
    now = dt.datetime.now(dt.timezone.utc)
    for host in sorted(hosts):
        try:
            der = verified_root(host, extras)
        except Exception as ex:  # noqa: BLE001
            failures.append(host)
            rows.append((host, f"❌ {ex}", ""))
            print(f"::error::{host}: цепочка не проверяется ни системным хранилищем, ни certs/extra/: {ex}")
            continue
        subject, end = cert_info(der)
        fp = sha1(der)
        used.add(fp)
        if fp in extra_ids:
            status = "встроен (ручной, certs/extra)"
        elif fp in bundled_ids:
            status = "встроен"
        else:
            status = "🆕 НЕ встроен"
            if all(sha1(d) != fp for d in new_roots):
                new_roots.append(der)
        if end - now < MIN_ROOT_LIFETIME:
            print(f"::warning::{host}: корень {subject} истекает {end:%Y-%m-%d}")
        rows.append((host, subject, f"{status}, до {end:%Y-%m-%d}"))

    # отчёт
    summary = ["| Хост | Корень | Статус |", "|---|---|---|"] + [f"| {a} | {b} | {c} |" for a, b, c in rows]
    unused = [cert_info(d)[0] for d in bundled if sha1(d) not in used]
    if unused:
        summary.append("\nВстроенные, но сейчас не используемые корни: " + "; ".join(unused))
    text = "\n".join(summary) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write("## CDN root certificates\n\n" + text)

    # обновление TRUST_PEM (только корни из хранилища Mozilla)
    changed = bool(new_roots)
    if changed:
        write_trust(lua, m, bundled + new_roots)
        PR_BODY.parent.mkdir(parents=True, exist_ok=True)
        added = "\n".join(f"- `{cert_info(d)[0]}` — SHA-1 `{sha1(d)}`" for d in new_roots)
        PR_BODY.write_text(
            "CDN VK Video Live отдаёт видео с хостов, цепочка которых ведёт к корням, "
            "которых нет в `TRUST_PEM`:\n\n" + added +
            "\n\nКорни взяты из проверенной цепочки (хранилище Mozilla на runner'е), "
            "а не из ответа сервера.\n\n" + text +
            "\nПеред merge сверьте отпечатки с сайтом удостоверяющего центра, затем выпустите новый релиз.\n",
            encoding="utf-8")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as f:
            f.write(f"changed={'true' if changed else 'false'}\n")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
