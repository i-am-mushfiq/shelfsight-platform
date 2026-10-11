# SFBL product catalog (scraped)

Every image published on https://www.sfbl.com.bd (Square Food & Beverage Ltd), scraped 2026-10-10.
Images are Square's property; use them as internal reference / SKU catalog material only.

Regenerate (stdlib only, ~5 min, wipes `raw/` and `products/`):

```text
python scripts/scrape_sfbl_catalog.py datasets/sfbl_catalog
```

## Layout

| Path | Contents |
|---|---|
| `products/<brand>/<category>/<pid>_<name>[_n].<ext>` | One file per product packshot, best resolution available. `_descN` files are extra artwork from the product description (e.g. lifestyle banners). |
| `raw/` | Byte-exact mirror of every image by site path (`raw/uploaded_files/...`, `raw/images/...`). Third-party images (YouTube TVC thumbnails, jQuery UI / bxslider sprites) under `raw/<host>/`. |
| `products.csv` | One row per product: pid, brand, category, name, pack sizes, description, image URLs, local files. |
| `manifest.json` | Brands → categories, products, and every image with URL, sha256, size, referring pages, and whether it was found by reference or by probing. |
| `missing.csv` | References the site makes that the server does not serve, and where a working copy was recovered. |
| `crawled_urls.txt` | Every page fetched. |

## Coverage

- 4,122 pages crawled. Product IDs 0–400, brand IDs 1–40 and every category ID × brand were brute-forced, and the ID ranges of press, TV, achievement and contact pages were probed; nothing unlinked carried new images.
- 933 image files (861 unique contents, ~198 MB): 712 from `uploaded_files/`, 42 site chrome, 154 YouTube TVC thumbnails.
- 99 products (Radhuni, Ruchi, Chashi, Chopstick, Aaram). 88 have a packshot; the other 10 have no image on the site. 13 products are not listed on any brand page (old or hidden SKUs) and appear under `unlisted/`.
- The site shows `300tn_thumb_*` thumbnails; 231 full-size originals were found by stripping that prefix, mostly 700–1300 px versus 300 px. `products/` uses the original; `raw/` keeps both.
- 9 references are dead on the server itself (template sprites and one deleted press photo); see `missing.csv`.

Brands 9 (Tara) and 10 (Radhuni Kitchen) have brand pages but no product listings; their logos and banners are in `raw/uploaded_files/`.
