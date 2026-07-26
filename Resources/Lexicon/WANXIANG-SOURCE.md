# Wanxiang lexicon attribution

BiLing incorporates the `dicts/jichu.dict.yaml` main vocabulary from
[amzxyz/rime-wanxiang](https://github.com/amzxyz/rime_wanxiang).

- Upstream commit: `1daf1e973001271331517fef3fb86eceb7e69afd`
- Retrieved: 2026-07-27
- Upstream license: Creative Commons Attribution 4.0 International
- Local transformation: tone marks are normalized to tone-free ASCII Pinyin,
  duplicate `(pinyin, text)` records are merged, and the result is compiled
  into an indexed SQLite database for low-memory, read-only lookup.

The complete upstream license is preserved in
`CC-BY-4.0-rime-wanxiang.txt`. BiLing's earlier Apache-2.0
`rime-pinyin-simp` source remains included as a secondary character and word
source.
