# Manually vetted root CAs

Roots that are **not** in the Mozilla trust store, but may be used by the VK Video Live CDN.
Every file here must also be present in `TRUST_PEM` (`src/vkplay.lua`); `cert_watch.py` fails otherwise.

Add only via `python scripts/cert_watch.py --add-root FILE --name NAME` and only after checking
the SHA-256 against the official source and at least one independent one.

| File | Source | SHA-256 | Cross-checked with |
|---|---|---|---|
| `russian-trusted-root-ca.pem` | gosuslugi.ru/crt (`gu-st.ru`) | `D26D2D0231B7C39F92CC738512BA54103519E4405D68B5BD703E9788CA8ECF31` | Censys; github.com/koenrh/russian-trusted-root-ca; serial/validity from habr.com/ru/articles/1071256 |
