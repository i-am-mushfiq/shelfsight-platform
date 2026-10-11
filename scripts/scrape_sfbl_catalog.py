"""Exhaustive image scraper for https://www.sfbl.com.bd (Square Food & Beverage Ltd).

Phase 1  crawl: BFS over every same-site page, seeded with brute-forced brand,
         category and product IDs so unlinked pages are found too.
Phase 2  assets: every image referenced from HTML (img/src/srcset/style/url()/
         quoted JS strings), linked CSS (recursive @import) and local JS files.
Phase 3  probes: full-size originals behind thumbnail names
         (e.g. 300tn_thumb_x.png -> x.png, stacked prefixes, "(1)" suffixes) and
         recovery of broken references (other folders, same basename).
Phase 4  download everything, mirror site paths under raw/, build products/
         view + manifest.json / products.csv / missing.csv.

Usage: python scripts/scrape_sfbl_catalog.py datasets/sfbl_catalog
"""
import csv
import hashlib
import html
import json
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath

BASE = "https://www.sfbl.com.bd/"
HOSTS = {"www.sfbl.com.bd", "sfbl.com.bd"}
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"
IMG_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico", ".tif", ".tiff", ".avif")
PAGE_EXT = ("", ".php", ".html", ".htm")
BRANDS = {1: "Radhuni", 2: "Ruchi", 3: "Chashi", 4: "Chopstick", 5: "Aaram", 9: "Tara", 10: "Radhuni Kitchen"}
ASSET_DIRS = ("uploaded_files", "images", "")
THUMB_PREFIX = re.compile(r"^(?:\d+tn_thumb_|thumb_|tn_|\d+tn_|small_)", re.I)
DUP_SUFFIX = re.compile(r"\(\d+\)(?=\.[^.]+$)")
MAX_PAGES = 6000
WORKERS = 8

OUT = Path(sys.argv[1]).resolve()
RAW = OUT / "raw"


def fetch(url, binary=False, tries=4):
    err = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": BASE})
            with urllib.request.urlopen(req, timeout=40) as r:
                data = r.read()
                return r.status, r.headers.get("Content-Type", ""), data if binary else data.decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code in (403, 404, 410):
                return e.code, "", None
            err = e
        except Exception as e:  # noqa: BLE001 - retry any network error
            err = e
        time.sleep(1.5 * (i + 1))
    print(f"  !! failed {url}: {err}", flush=True)
    return None, "", None


def norm(url, base):
    url = html.unescape(url.strip().strip("'\""))
    if not url or url.startswith(("data:", "javascript:", "mailto:", "tel:", "#")):
        return None
    u = urllib.parse.urljoin(base, url)
    p = urllib.parse.urlsplit(u)
    if p.scheme not in ("http", "https"):
        return None
    # Keep spaces/parentheses exactly as the site uses them, but encode for HTTP.
    path = urllib.parse.quote(urllib.parse.unquote(p.path), safe="/()!$&'*+,;=:@~-._")
    return urllib.parse.urlunsplit(("https" if p.netloc in HOSTS else p.scheme, p.netloc.lower(), path, p.query, ""))


def is_site(u):
    return urllib.parse.urlsplit(u).netloc in HOSTS


def url_path(u):
    return urllib.parse.unquote(urllib.parse.urlsplit(u).path)


def ext_of(u):
    return PurePosixPath(url_path(u)).suffix.lower()


def is_page(u):
    return is_site(u) and (url_path(u).endswith("/") or ext_of(u) in PAGE_EXT)


CSS_URL = re.compile(r"url\(\s*(['\"]?)([^'\")]+)\1\s*\)", re.I)
CSS_IMPORT = re.compile(r"@import\s+(?:url\()?\s*['\"]?([^'\")\s;]+)", re.I)
# Image paths inside quoted strings (inline JS, JSON, unusual attributes); spaces allowed.
STR_IMG = re.compile(r"""(['"])([^'"<>\n]*?\.(?:png|jpe?g|gif|webp|svg|bmp|ico|tiff?|avif))(?:\?[^'"<>\s]*)?\1""", re.I)


class PageParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links, self.imgs, self.css, self.js = [], [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        for k, v in attrs:
            if v is None:
                continue
            if k in ("src", "data-src", "data-original", "data-lazy", "data-bg", "data-image", "poster", "background", "data", "lowsrc"):
                (self.js if tag == "script" else self.imgs).append(v)
            elif k in ("srcset", "data-srcset"):
                self.imgs += [s.strip().split(" ")[0] for s in v.split(",") if s.strip()]
            elif k == "style":
                self.imgs += [m[1] for m in CSS_URL.findall(v)]
            elif k == "href":
                if tag == "link":
                    rel = (a.get("rel") or "").lower()
                    (self.css if "stylesheet" in rel else self.imgs).append(v)
                else:
                    self.links.append(v)
            elif k == "action":
                self.links.append(v)
            elif k == "content" and v.lower().endswith(IMG_EXT):  # og:image etc.
                self.imgs.append(v)


def extract_images(body, base):
    p = PageParser()
    try:
        p.feed(body)
    except Exception:  # noqa: BLE001 - malformed html; regex passes below still run
        pass
    raw = list(p.imgs) + [m[1] for m in CSS_URL.findall(body)] + [m[1] for m in STR_IMG.findall(body)]
    imgs = {iu for iu in (norm(r, base) for r in raw) if iu and ext_of(iu) in IMG_EXT}
    links = [lu for lu in (norm(r, base) for r in p.links) if lu]
    imgs |= {lu for lu in links if ext_of(lu) in IMG_EXT}
    css = {cu for cu in (norm(r, base) for r in p.css) if cu}
    js = {ju for ju in (norm(r, base) for r in p.js) if ju and is_site(ju) and ext_of(ju) == ".js"}
    return imgs, [lu for lu in links if ext_of(lu) not in IMG_EXT], css, js


def parse_product(page):
    m = re.search(r"<h1[^>]*>\s*<strong>(.*?)</strong>\s*</h1>", page, re.S)
    name = html.unescape(re.sub(r"<[^>]+>", "", m.group(1))).strip() if m else ""
    if not name:
        return None
    block = page[m.start():]
    clean = lambda s: re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s))).strip()
    paras = re.findall(r"<p>(.*?)</p>", block.split('class="slider"')[0], re.S)
    am = re.search(r"Available In.*?<p>(.*?)</p>", block, re.S)
    slider = block.split('class="slider"', 1)[1].split("</td>", 1)[0] if 'class="slider"' in block else ""
    return {
        "name": name,
        "description": clean(paras[0]) if paras else "",
        "available_in": clean(am.group(1)) if am else "",
        "images": re.findall(r"<img[^>]+src=\"([^\"]+)\"", slider),
    }


def parse_menu(page):
    """Left menu of a brand page: [(category, pid, product name)]."""
    out = []
    menu = page.split("id='cssmenu'", 1)
    if len(menu) < 2:
        return out
    for cat_m in re.finditer(r"<li><a href=\"#\"><span>(.*?)</span></a>(.*?)</ul>", menu[1], re.S):
        cat = html.unescape(cat_m.group(1)).strip()
        for pm in re.finditer(r"our_product\.php\?brand_id=(\d+)&(?:amp;)?pid=(\d+)\"><span>(.*?)</span>", cat_m.group(2)):
            out.append((cat, int(pm.group(2)), html.unescape(pm.group(3)).strip()))
    return out


def name_variants(name):
    """Thumbnail-stripped / duplicate-suffix-stripped variants of a filename, best guess first:
    no thumb prefix before partial prefix, exact "(n)" suffix before suffix-stripped."""
    stripped, cur = [], name
    while THUMB_PREFIX.match(cur):
        cur = THUMB_PREFIX.sub("", cur, count=1)
        stripped.insert(0, cur)  # most-stripped first
    out = stripped + [DUP_SUFFIX.sub("", n) for n in stripped + [name] if DUP_SUFFIX.search(n)]
    return [n for i, n in enumerate(out) if n != name and n not in out[:i]]


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    seeds = [BASE, BASE + "index.php", BASE + "all_brands.php", BASE + "our_brands.php"]
    seeds += [f"{BASE}our_brands.php?brand_id={b}" for b in range(1, 41)]
    seeds += [f"{BASE}our_brands_all.php?brand_id={b}&bpc_id=1" for b in range(1, 41)]
    seeds += [f"{BASE}our_product.php?pid={p}" for p in range(0, 401)]
    seeds += [f"{BASE}our_product.php?brand_id={b}&pid=0" for b in range(1, 11)]  # empty templates

    seen, queue = set(), deque()

    def enqueue(u):
        if u and u not in seen:
            seen.add(u)
            queue.append(u)

    for s in seeds:
        enqueue(norm(s, BASE))

    pages = {}  # url -> html (only needed for product/brand pages)
    page_imgs = {}  # url -> set(img urls)
    img_refs = {}  # img url -> set(referrers)
    css_files, js_files = set(), set()
    seen_bpc = set()
    max_pid = 400

    def visit(u):
        status, ctype, body = fetch(u)
        return u, status, ctype, body

    with ThreadPoolExecutor(WORKERS) as ex:
        while queue and len(page_imgs) < MAX_PAGES:
            batch = [queue.popleft() for _ in range(min(len(queue), WORKERS * 4))]
            for u, status, ctype, body in ex.map(visit, batch):
                if body is None or status != 200:
                    continue
                if "html" not in ctype and "<html" not in body[:2000].lower():
                    continue
                if "our_product.php" in u or "our_brands" in u:
                    pages[u] = body
                imgs, links, css, js = extract_images(body, u)
                page_imgs[u] = imgs
                for iu in imgs:
                    img_refs.setdefault(iu, set()).add(u)
                css_files |= css
                js_files |= js
                for lu in links:
                    if not is_page(lu):
                        continue
                    enqueue(lu)
                    pm = re.search(r"[?&]pid=(\d+)", lu)
                    if pm and int(pm.group(1)) > max_pid - 100:  # extend brute-force window
                        for q in range(max_pid + 1, int(pm.group(1)) + 201):
                            enqueue(f"{BASE}our_product.php?pid={q}")
                        max_pid = int(pm.group(1)) + 200
                    cm = re.search(r"bpc_id=(\d+)", lu)
                    if cm and cm.group(1) not in seen_bpc:  # category seen once -> try it for every brand
                        seen_bpc.add(cm.group(1))
                        for b in range(1, 41):
                            for script in ("our_brands.php", "our_brands_all.php"):
                                enqueue(norm(f"{BASE}{script}?brand_id={b}&bpc_id={cm.group(1)}", BASE))
            print(f"pages={len(page_imgs)} queued={len(queue)} images={len(img_refs)}", flush=True)

    # CSS (recursive @import) and local JS asset references
    todo, done_css = deque(css_files), set()
    while todo:
        cu = todo.popleft()
        if cu in done_css:
            continue
        done_css.add(cu)
        _, _, body = fetch(cu)
        if not body:
            continue
        for m in CSS_URL.findall(body):
            iu = norm(m[1], cu)
            if iu and ext_of(iu) in IMG_EXT:
                img_refs.setdefault(iu, set()).add(cu)
        for m in CSS_IMPORT.findall(body):
            iu = norm(m, cu)
            if iu and iu not in done_css:
                todo.append(iu)
    for ju in sorted(js_files):
        _, _, body = fetch(ju)
        if body:
            for m in STR_IMG.findall(body):
                iu = norm(m[1], ju)
                if iu and is_site(iu) and ext_of(iu) in IMG_EXT:
                    img_refs.setdefault(iu, set()).add(ju)
    for extra in ("favicon.ico", "apple-touch-icon.png"):
        img_refs.setdefault(norm(BASE + extra, BASE), set()).add("probe:root-icon")

    def dl(iu):
        status, ctype, data = fetch(iu, binary=True)
        ok = bool(data) and status == 200 and not ctype.startswith("text/")
        return iu, status, (ctype, data) if ok else None

    results, status_of = {}, {}

    def download(urls):
        with ThreadPoolExecutor(WORKERS) as ex:
            for iu, status, res in ex.map(dl, sorted(urls)):
                status_of[iu] = status
                if res:
                    results[iu] = res

    print(f"downloading {len(img_refs)} referenced images", flush=True)
    download(set(img_refs))

    # ---- Probes: originals behind thumbnails, and recovery of broken references.
    def site_variants(iu):
        """Ordered candidate URLs, most likely first."""
        if not is_site(iu):
            return []
        path = PurePosixPath(url_path(iu))
        names = name_variants(path.name)
        out = [norm(str(path.with_name(n)), BASE) for n in names]
        if iu not in results:  # broken reference: same name (then variants) in the known asset folders
            out = [norm(f"{BASE}{d + '/' if d else ''}{n}", BASE) for n in [path.name] + names for d in ASSET_DIRS] + out
        return [v for i, v in enumerate(out) if v != iu and v not in out[:i]]

    variants = {iu: site_variants(iu) for iu in img_refs}
    probes = set().union(*map(set, variants.values())) - set(img_refs)
    print(f"probing {len(probes)} variants (originals / recoveries)", flush=True)
    download(probes)
    originals, recovered = {}, {}  # thumb url -> full-size original ; broken url -> found url
    for iu, vs in variants.items():
        found = [v for v in vs if v in results]
        for v in found:
            img_refs.setdefault(v, set()).add(f"probe:variant-of:{iu}")
        if not found:
            continue
        if iu in results:
            bigger = [v for v in found if len(results[v][1]) > len(results[iu][1])]
            if bigger:
                originals[iu] = bigger[0]
        else:
            recovered[iu] = found[0]

    # ---- Write raw/ mirror
    if RAW.exists():
        shutil.rmtree(RAW)
    files = []
    for iu, (ctype, data) in sorted(results.items()):
        sp = urllib.parse.urlsplit(iu)
        rel = PurePosixPath("" if is_site(iu) else sp.netloc) / url_path(iu).lstrip("/")
        if sp.query:
            rel = rel.with_name(rel.stem + "_" + re.sub(r"\W+", "_", sp.query) + rel.suffix)
        dest = RAW / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        refs = sorted(img_refs.get(iu, []))
        files.append({
            "url": iu,
            "local_path": dest.relative_to(OUT).as_posix(),
            "bytes": len(data),
            "content_type": ctype,
            "sha256": hashlib.sha256(data).hexdigest(),
            "discovered_by": "probe" if refs and all(r.startswith("probe:") for r in refs) else "reference",
            "full_size_of": sorted(t for t, o in originals.items() if o == iu),
            "referenced_from_count": len(refs),
            "referenced_from_sample": refs[:10],
        })
    by_url = {f["url"]: f for f in files}
    missing = [{"url": iu, "status": status_of.get(iu), "recovered_as": recovered.get(iu),
                "referenced_from_count": len(img_refs[iu]), "referenced_from_sample": sorted(img_refs[iu])[:5]}
               for iu in sorted(img_refs) if iu not in results and not all(r.startswith("probe:") for r in img_refs[iu])]

    # ---- Products
    template = set().union(*(page_imgs.get(norm(f"{BASE}our_product.php?brand_id={b}&pid=0", BASE), set()) for b in range(1, 11)),
                           page_imgs.get(norm(f"{BASE}our_product.php?pid=0", BASE), set()))
    products = {}
    for u, body in sorted(pages.items()):
        if "our_product.php" not in u:
            continue
        pid = int(re.search(r"pid=(\d+)", u).group(1))
        info = parse_product(body)
        if not info:
            continue
        p = products.setdefault(pid, {**info, "pid": pid, "page_url": f"{BASE}our_product.php?pid={pid}",
                                      "images": [], "description_images": []})
        for i in info["images"]:
            iu = norm(i, u)
            if iu and iu not in p["images"]:
                p["images"].append(iu)
        for iu in sorted(page_imgs[u] - template):
            iu = recovered.get(iu, iu)
            if iu not in p["images"] and iu not in p["description_images"] and is_site(iu):
                p["description_images"].append(iu)
    placement, categories = {}, {}
    for u, body in pages.items():
        bm = re.search(r"our_brands(?:_all)?\.php\?brand_id=(\d+)", u)
        if bm:
            for cat, pid, _ in parse_menu(body):
                placement.setdefault(pid, (int(bm.group(1)), cat))
                categories.setdefault(int(bm.group(1)), set()).add(cat)
    # Description-only images that are really brand/category template art appear on many products; drop them.
    desc_count = {}
    for p in products.values():
        for iu in p["description_images"]:
            desc_count[iu] = desc_count.get(iu, 0) + 1
    for p in products.values():
        p["description_images"] = [iu for iu in p["description_images"] if desc_count[iu] <= 3]
        b, cat = placement.get(p["pid"], (None, None))
        p["brand_id"] = b
        p["brand"] = BRANDS.get(b, f"brand_{b}") if b else (p["name"].split()[0].title() if p["name"].split()[0].lower() in ("radhuni", "ruchi", "chashi", "chopstick", "aaram", "tara") else "Unlisted")
        p["category"] = cat or "Unlisted"
        p["listed_on_brand_page"] = p["pid"] in placement
        p["full_size_images"] = [originals.get(iu, iu) for iu in p["images"]]

    # ---- products/<brand>/<category>/<pid>_<slug>[_n].ext  (best available resolution)
    prod_dir = OUT / "products"
    if prod_dir.exists():
        shutil.rmtree(prod_dir)
    slug = lambda s: re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    for pid, p in sorted(products.items()):
        p["local_images"] = []
        sources = [(iu, "") for iu in p["full_size_images"]] + [(iu, "desc") for iu in p["description_images"]]
        for n, (iu, kind) in enumerate(sources):
            f = by_url.get(iu)
            if not f:
                continue
            tag = f"_{kind}{n + 1}" if kind else (f"_{n + 1}" if len(p["full_size_images"]) > 1 else "")
            dest = prod_dir / slug(p["brand"]) / slug(p["category"]) / f"{pid:03d}_{slug(p['name'])}{tag}{PurePosixPath(f['local_path']).suffix.lower()}"
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(OUT / f["local_path"], dest)
            p["local_images"].append(dest.relative_to(OUT).as_posix())

    manifest = {
        "source": BASE,
        "scraped_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "pages_crawled": len(page_imgs),
        "brands": {str(k): {"name": BRANDS.get(k, f"brand_{k}"), "categories": sorted(v)} for k, v in sorted(categories.items())},
        "products": [products[k] for k in sorted(products)],
        "images": files,
        "missing": missing,
    }
    (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    with open(OUT / "products.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["pid", "brand_id", "brand", "category", "name", "available_in", "listed_on_brand_page",
                    "image_urls", "full_size_image_urls", "description_image_urls", "local_images", "description", "page_url"])
        for k in sorted(products):
            p = products[k]
            w.writerow([p["pid"], p["brand_id"], p["brand"], p["category"], p["name"], p["available_in"], p["listed_on_brand_page"],
                        " | ".join(p["images"]), " | ".join(p["full_size_images"]), " | ".join(p["description_images"]),
                        " | ".join(p["local_images"]), p["description"], p["page_url"]])
    with open(OUT / "missing.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["url", "http_status", "recovered_as", "referenced_from_count", "referenced_from_sample"])
        for m in missing:
            w.writerow([m["url"], m["status"], m["recovered_as"] or "", m["referenced_from_count"], " | ".join(m["referenced_from_sample"])])
    (OUT / "crawled_urls.txt").write_text("\n".join(sorted(page_imgs)), encoding="utf-8")

    print(f"\nDONE pages={len(page_imgs)} products={len(products)} images={len(files)} "
          f"bytes={sum(f['bytes'] for f in files):,} full_size_originals={len(set(originals.values()))} "
          f"recovered={len(recovered)} still_missing={sum(1 for m in missing if not m['recovered_as'])}")


if __name__ == "__main__":
    main()
