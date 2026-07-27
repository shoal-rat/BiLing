# 笔灵的工作原理：把输入法建模为受约束的上下文排序

*BiLing: Pinyin Input as Constrained, Context-Aware Ranking*

**Abstract.** BiLing treats pinyin-to-character conversion not as free text
generation but as ranking over a phonetically closed candidate set: a
1.44M-entry lexicon proposes every legal candidate within milliseconds, a
local Qwen3-0.6B re-scores the head of that list against the text already
before the caret, and a decaying personal prior adjusts the final order.
Because the language model chooses among dozens of options rather than
generating freely, a 0.6-billion-parameter model is sufficient, and because
it sits off the keystroke path, its cost is bounded and interruptible. On an
Apple M5, the deterministic stage answers a 21-key sentence in 2.8 ms and
the model's re-rank lands in 28.5 ms while composing. All inference,
context reading, and learning happen on the local machine.

以下正文使用中文。所有数字都是本仓库当前版本在同一台机器上的实测值，
复现命令随文给出。

---

## 1. 问题形式化

拼音转汉字（P2C）的经典表述：给定按键串 $x$ 与已有前文 $h$，求

$$\hat{c} = \arg\max_{c \,\in\, C(x)} \; P(c \mid x, h)$$

关键在于候选集 $C(x)$ 是**封闭且可枚举的**：合法候选必须与 $x$ 的某种
音节切分逐段对齐。这把问题从"生成"降级为"排序"——模型不需要会写文章，
只需要在几十个音同的候选里判断哪个更贴合前文。这正是 0.6B 模型够用的
原因：任务的分支因子被拼音约束砍掉了几个数量级。

笔灵把 $C(x)$ 的构造与 $P$ 的估计拆给两个性格完全不同的组件：

- **词典引擎**（确定性，微秒级）：负责 $C(x)$ 的完整性——每一个合法
  候选都必须在列表里，翻页可达；
- **Qwen3-0.6B-Base**（概率性，几十毫秒）：负责 $P(\cdot \mid h)$ 的
  上下文敏感性——它从不新增候选，只重排前 16 个。

模型永远不在按键的必经之路上：它挂了、慢了、被卸载了，词典排序照常
工作。这个不对称设计是全文所有性质（延迟、能耗、鲁棒性）的根源。

## 2. 候选生成：切分格与句子束

**切分格。** 按键串先解析为音节格（lattice），保留全部切分歧义：
`xian` 同时是 `xian`（先）与 `xi'an`（西安），`fangan` 同时是
`fang'an`（方案）与 `fan'gan`（反感）。撇号强制断音。不做贪心切分，
歧义交给排序层消解。

**精确命中。** 完整键直接查询 1.44M 词条的只读 SQLite 索引
（主键 `(key, text)`，常驻预编译语句）。

**句子束搜索。** 键没有整词命中时（如 `jilindaxuelajixuexiao`），
束搜索沿键逐段扩展：每个位置查询以该位置开头的全部词典前缀
（键区间探测提前终止），束宽 64，按分数均值剪枝。段分数为

$$s(\text{seg}) = \ln(1 + w) + 0.35 \cdot |\text{key}| - \mathbb{1}[|\text{key}| = 1] \cdot 8$$

其中 $w$ 是词频权重；末项惩罚单字母词条（嗯 `n`、呣 `m`），否则
`fan` 会被"发嗯"这类合法但荒谬的拼接碾压。示例
`jilindaxuelajixuexiao → 吉林大学垃圾学校` 就是束搜索现场把
吉林大学 + 垃圾 + 学校 三段接出来的——词库里并没有这个词条。

**简拼（缩写）。** 词库为每个词条预存声母串（北京会议 → `bjhy`），
以 `(abbrev, weight)` 复合索引支持按词频降序的免排序查询。两种用法：
整键简拼直接出词（`jldx` → 吉林大学、`zgrm` → 中国人民）；束搜索的
每个位置还可以把**剩余尾串**当声母展开（`beijinghy` → 北京 + 还有）。
门控规则防止简拼污染全拼：键本身能完整切分成拼音时，尾部简拼扩展整个
关闭（`fan` 永远是 饭，不会长出 发+你），整键简拼解释也只以低分陪跑。

**拉丁词汇。** 约 260 条精选词条（带大小写还原：`claude → Claude`、
`gdp → GDP`、`xswl`）与 macOS 系统 20 万词表（懒加载）并入候选。
排序规则：键同时是合法拼音时中文优先（`ai` → 爱 第一、AI 前几名）；
键无真实词条对应时专名置顶（`openai` → OpenAI，而不是"哦喷爱"）。

## 3. 打分：三项混合与上下文校准

最终分数为

$$S(c) = B_{\text{lex}}(c, x) \;+\; \lambda(h) \cdot L_{\text{Qwen}}(c \mid h) \;+\; U(c)$$

**词典项 $B_{\text{lex}}$**：词频、词长与整词奖励的组合，保证没有模型
时排序仍然合理。

**模型项 $L_{\text{Qwen}}$**：候选接在前文后的对数概率，全候选共享
前缀、一批解码得到；按 $\sqrt{\text{token数}}$ 归一，避免 BPE 切分
碎的候选被系统性低估。

**上下文校准 $\lambda(h)$**：有前文取 0.42，无前文取 0.25。依据是一个
实测现象：冷启动时模型的偏好主要反映语体风格而非用户意图——对
`laji`，无前文的 Qwen 更喜欢网络写法"辣鸡"（logP 差约 2.1），而词频
证据 8:1 支持"垃圾"。降低冷启动权重后词频占上风；一旦有了前文
（"我真的受够了……"），模型自己也倒向"垃圾"，高权重顺理成章。
证据多，话语权大；证据少，先验说了算——这就是校准的全部内容。

**个人先验 $U$**：选中计数按使用时钟指数衰减（时间常数 200 次提交），
被跳过的默认候选轻微减分。存储为 AES-GCM 加密的
"拼音→词→计数"聚合，密钥在 Keychain，永不出机。

**LoRA 个性化（可选的第四层）**：`scripts/train_lora.sh` 把选择记录
导出为语料，在本机用 mlx-lm 对 Qwen3-0.6B-Base 做 LoRA 微调，融合导出
GGUF 并量化回 Q4_K_M；守护进程在下一次懒加载时自动改用个人模型。选择
"融合整模"而非适配器挂载作为默认路径，是因为 mlx 适配器与 llama.cpp
适配器格式互不兼容，而融合+量化链路完全离线、无 PyTorch 依赖；推理层
同时保留标准 GGUF 适配器入口（`BILING_LORA_PATH`），供已有转换产物的
用户以 $W + s \cdot BA$ 方式挂载。删除个人模型文件即回退，词频先验与
LoRA 互不依赖。

## 4. 上下文从哪来：读光标前的真实文本

传统输入法只有两种"上下文"：没有，或者仅限本会话自己上屏过的字。
笔灵每次组词开始时通过 InputMethodKit 向宿主应用读取一次
**光标前至多 600 个字符**（`attributedSubstring`），作为 $h$ 直接
喂给模型；不支持该接口的客户端（如 Terminal）自动退回会话内已提交
文本。效果可以直接测量——同一串拼音，前文不同，第一候选不同：

| 光标前的文本 | 输入 | 第一候选 |
|---|---|---|
| 他这辈子行医救人，是一位好 | `yisheng` | 医生 |
| 这句话让我受用 | `yisheng` | 一生 |
| 我突然 | `xiangqi` | 想起 |
| 爷爷最喜欢下 | `xiangqi` | 象棋 |
| 我们在化学课上做 | `shiyan` | 实验 |
| 他违背了当初的 | `shiyan` | 誓言 |

（六行均为安装版实测；复现：`biling-cli --xpc --context "<前文>" <拼音>`。）

每次组词只读一次也是效率决策：组词期间 $h$ 不变，守护进程的 KV
前缀缓存可以持续命中（§5）。

## 5. 推理效率：让 28 毫秒成为常态

单次重排 = 一次前缀解码（仅当上下文变化）+ 一批候选续写解码 +
每行一次全词表 softmax。三个针对性优化：

1. **KV 前缀缓存**。上下文 token 驻留序列 0，跨请求比较最长公共前缀，
   只解码新增后缀；上下文裁剪带滞回（3072 字符收缩到 1536），窗口在
   两次裁剪之间字节稳定。组词期间上下文不变——解码量为零。
2. **共享前缀批量打分**。16 个候选经 `llama_memory_seq_cp` 共享同一
   前缀 KV（统一缓存下零拷贝），续写 token 合成一个 batch 一次
   `llama_decode`。
3. **向量化 softmax**。151,936 维 logits 的 log-sum-exp 用 Accelerate
   （`vDSP_maxv` / `vvexpf` / `vDSP_sve`）计算，替换掉此前每键上千万
   次的标量 `exp` 循环。

![各阶段实测延迟](theory-latency.svg)

| 阶段 | 实测 | 条件 |
|---|---|---|
| 词典引擎（21 键整句） | 2.8 ms | `--engine-only`，同步路径 |
| Qwen 重排 · 上下文未变 | 28.5 ms | 组词中的每一键（KV 全命中） |
| Qwen 重排 · 上下文新增一句 | 44.7 ms | 提交后第一键（解码新后缀） |
| Qwen 重排 · 冷上下文 | 61.8 ms | 换输入框后第一键 |
| 对照：1.2.0 每一键 | ≈ 62 ms 起 | 每键清 KV + 标量 softmax |

测量环境：Apple M5 / 16 GB / macOS 26.5，Qwen3-0.6B-Base Q4_K_M，
已安装 XPC 服务，`jilindaxuelajixuexiao`（16 候选）。

## 6. 常驻的代价：能耗与内存

输入法是永续后台进程，笔灵的原则是**空闲成本必须趋近于零**：

- 无任何定时器：不做周期健康检查、不轮询状态，事件驱动重连；
- 模型懒加载，空闲 10 分钟整体卸载，守护进程回落到数 MB；
- 权重 mmap：636 MB 驻留中约 400 MB 是干净页，内存压力下系统可直接
  回收；
- 低电量模式下自动把会话切给苹果拼音（未启用时退化为纯词典模式）。

![守护进程内存状态](theory-memory.svg)

诚实的对比：**待机时**笔灵与系统拼音都接近零消耗；**持续打字时**
笔灵每键多付一次约 20–30 ms 的 GPU 脉冲——这是上下文排序的直接
成本，系统拼音没有这一步。绝对差值小（打字不是持续负载），且真正
需要省电时笔灵会自动让位。

## 7. 与已有路线的关系

- **传统 n-gram 输入法**（librime 等）：候选完整性与毫秒延迟的标杆，
  笔灵的词典层和用户词频衰减公式直接继承这条路线；差别在它们的
  $P(c \mid h)$ 只有二三元窗口，且从不读取输入框已有内容。
- **云端大模型输入法**：上下文理解强，但按键逐次上传、断网退化、
  延迟受网络支配。笔灵证明 0.6B 本地模型在"排序"这个受约束任务上
  已经够到同类体验。
- **学术原型**：把冻结 GPT 用于拼音约束解码的 PinyinGPT
  （[arXiv:2203.00249](https://arxiv.org/abs/2203.00249)）、生成式
  输入范式 GeneInput（[arXiv:2311.01166](https://arxiv.org/abs/2311.01166)）、
  端侧 Qwen3-0.6B 输入法 HuoziIME
  （[arXiv:2604.14159](https://arxiv.org/html/2604.14159v1)）、以及
  社区实现 [lime](https://github.com/xushengfeng/lime)。笔灵的差异
  点：模型严格移出按键路径（词典兜底）、读取宿主输入框上下文、
  上下文校准的混合打分、以及以能耗为一等公民的工程化
  （KV 复用 / 空闲卸载 / 零轮询）。

## 8. 局限与下一步

- **简拼只做了保守的两档**（整键简拼 + 尾部简拼）：任意位置的混合
  简拼（`bj` + `daxue` + `hy` 交错）尚未展开——先行研究一致表明这是
  准确率悬崖，全开会把候选质量拖垮；
- **LoRA 训练数据目前是选择记录**（短语级），不是完整语句流——这是
  隐私设计的直接后果（笔灵不存句子），个性化上限相应受限；训练效果
  没有自动评估门槛，靠删除文件回退兜底；
- 模型只重排前 16 个候选，后页仍是纯词频序；
- 束搜索的段级独立性假设偶尔产生不自然的长句拼接，靠模型重排兜底。

## 复现清单

```bash
swift test                                            # 25 项测试
.build/release/biling-cli --engine-only jilindaxuelajixuexiao   # 2.8 ms 词典
.build/release/biling-cli --engine-only jldx          # 简拼 → 吉林大学
biling-cli --xpc jilindaxuelajixuexiao                # 完整链路
biling-cli --xpc --context "爷爷最喜欢下" xiangqi      # 上下文翻转
./scripts/train_lora.sh --iters 200                   # 本地 LoRA 个性化
```

数据、图表与本文所有断言均可由上述命令在本仓库当前提交上复现。
