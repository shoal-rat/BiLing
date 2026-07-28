# Baseline — recorded before the v2 architecture work

Commit: b92f044734c9ca3298ffc4b464382d3a92ba60d8
Date:   2026-07-28T04:32:42Z
Machine: Apple M5 / 16 GB / macOS 26.5.2

## Unit tests
```
✔ Test literalEscapeIsAlwaysReachable() passed after 9.018 seconds.
✔ Test run with 26 tests in 0 suites passed after 9.019 seconds.
```

## Derived corpus, held-out test
```
full n=412  top1  45.4%  top5  60.7%  cover  70.1%  MRR 0.522  median    4.1 ms  p95    9.1 ms
abbrev n=310  top1  25.2%  top5  36.8%  cover  51.0%  MRR 0.308  median   21.5 ms  p95   42.7 ms
abbrev-heavy n=402  top1  15.2%  top5  21.9%  cover  32.6%  MRR 0.184  median   16.1 ms  p95   34.0 ms
full-ctx n=401  top1  60.6%  top5  71.3%  cover  76.8%  MRR 0.657  median    2.0 ms  p95    3.7 ms
abbrev-ctx n=236  top1  39.0%  top5  50.8%  cover  64.4%  MRR 0.447  median    9.0 ms  p95   20.3 ms
OVERALL n=1761 top1  37.5%  top5  48.7%  cover  58.9%  MRR 0.428  median    7.2 ms  p95   32.6 ms
--- full system ---
full n=412  top1  52.9%  top5  63.8%  cover  70.1%  MRR 0.577  median   41.0 ms  p95   68.6 ms
abbrev n=310  top1  33.2%  top5  42.3%  cover  51.0%  MRR 0.368  median   55.2 ms  p95   98.0 ms
abbrev-heavy n=402  top1  18.4%  top5  26.6%  cover  32.6%  MRR 0.216  median   47.4 ms  p95   88.1 ms
full-ctx n=401  top1  66.1%  top5  73.3%  cover  76.8%  MRR 0.693  median   34.4 ms  p95   44.6 ms
abbrev-ctx n=236  top1  50.0%  top5  55.1%  cover  64.4%  MRR 0.527  median   35.9 ms  p95   52.5 ms
OVERALL n=1761 top1  44.2%  top5  52.5%  cover  58.9%  MRR 0.477  median   41.0 ms  p95   83.8 ms
```
