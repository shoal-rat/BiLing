# 笔灵 BiLing

**简体中文** · [English](README_EN.md)

![笔灵——在 Mac 上本地运行的大模型拼音输入法](Docs/hero-zh.svg)

笔灵是一个 macOS 原生拼音输入法。词典引擎在毫秒内给出完整候选，本机运行的
Qwen3-0.6B 读取**光标前的真实文本**把候选重排，你的选择在这台 Mac 上加密学习。
整个工程没有网络权限——不是"承诺不上传"，是根本没有上传的路。

试试连打一整句：输入 `jilindaxuelajixuexiao`，第一候选就是
**吉林大学垃圾学校**——词典里并没有这个词条，它是引擎现场拼出、再由模型确认的
结果。也可以像平时打字那样偷懒：`jilindxmeiykongt` → **吉林大学没有空调**。

## 它现在有多准

这是最重要的一节，因为它是**实测**，而且不是拿作者自己写的例子测的。

评测语料由一个本系统未参与的过程生成：句子取自公开新闻语料，由 jieba 分词、
pypinyin 注音（两者都不知道笔灵词库的存在），按键串再从打字模型里采样出来。
参数只在 dev 集上标定，test 集只跑一次。

| 条件 | 仅词典 | 完整系统 |
|---|---|---|
| 整串全拼 | 45.4% | **52.9%** |
| 全拼 + 前文 | 60.6% | **66.1%** |
| 轻度缩写 | 25.2% | **33.2%** |
| 缩写 + 前文 | 39.0% | **50.0%** |
| 重度缩写 | 15.2% | **18.4%** |
| **合计（n=1761）** | 37.5% | **44.2%** |

**和 macOS 自带拼音比呢？还差一截。** 同一批 260 条、双方都没有前文：

| | Apple 拼音 | 笔灵 |
|---|---|---|
| 整串全拼 | **65.3%** | 59.3% |
| 轻度缩写 | **57.0%** | 39.0% |
| 重度缩写 | 30.0% | 30.0% |
| **合计** | **60.8%** | **50.4%** |

差距从最初的 18.5 个百分点缩到 10.4，重度缩写已经追平，剩下的差距主要在中度
缩写输入上。这个数字写在这里而不是被藏起来，是因为它决定了接下来做什么。

**有前文的时候，差距没了。** 已提交的前文现在直接参与词典层解码（末词替换句首
标记，只升不降），模型门控按上下文单独校准，模型打分权重也按修正后的打分语义
重新扫过。150 条留出集配对测试（两边看到完全相同的前文）：笔灵 77.3%，
Apple 拼音 77.3% —— 打平，95% 置信区间 [−6.0, +6.7]；在 43 条专测前文歧义的
对照集上笔灵 83.7% 对 67.4%，配对差 +16.3 分，95% 置信区间 [+2.3, +30.2]，
不含零。冷启动 Apple 仍然领先，如上表。方法与命令见
`Docs/results/apple-comparison-context.txt`。

![每一步改动带来的准确率变化](Docs/results-progress.svg)

完整方法、消融、误差分析与和已发表结果的对齐，见
**[原理文档 Docs/THEORY.md](Docs/THEORY.md)**。

## 安装

### 直接装（推荐）

Apple silicon Mac，macOS 26 或更新。

1. 从 [Releases](https://github.com/shoal-rat/BiLing/releases/latest) 下载
   `BiLing-*-macOS-arm64.zip` 并解压；
2. 右键 `安装笔灵.command`，选"打开"；
3. 安装器会校验模型摘要、启动服务、跑一遍排序检查，然后注册输入源；
4. 在菜单栏输入法菜单里选 **笔灵**。

发布包是 ad-hoc 签名（没有 Apple Developer ID，未经公证）。macOS 弹出验证提示
时，去"系统设置 → 隐私与安全性"确认后选"仍要打开"；不放心就走源码安装，每一行
都在这个仓库里。

### 从源码装

需要 Xcode 26（或对应命令行工具，Swift 6.3+）、Homebrew、Git LFS。

```bash
git lfs install
git clone https://github.com/shoal-rat/BiLing.git
cd BiLing
brew install llama.cpp ggml libomp
./scripts/install.sh
```

脚本会构建三个可执行文件，组装成自包含的 `BiLing.app`（模型、词库、llama.cpp
动态库全部打进去），装到 `~/Library/Input Methods`，配置两个登录启动项，最后用
真实安装产物跑完整套冒烟检查——任何一步失败都不会覆盖你现有的安装。

装完如果输入法菜单里还没有"笔灵"，注销再登录一次——这是 macOS 的输入源缓存，
不是安装失败。

## 它怎么找到好词

![一次按键之后发生了什么](Docs/pipeline-zh.svg)

关键的取舍：**模型不在按键的必经之路上。**

1. **切分成格。** 按键串解析为音节格，保留全部歧义：`xian` 同时是 先 和
   西安，`fangan` 同时是 方案 和 反感。歧义交给后面消解，不做贪心决定。
2. **查词并连成句。** 144 万词条的索引给出每个片段的候选词；缩写码让
   `dx` → 大学、`meiy` → 没有 也能参与。
3. **精确解码。** 前向 Viterbi 算出每个状态的最优分，反向 A\* 按分数严格递减
   取出前 80 条——这保证交给模型的候选表是**真正有序**的，而不是碰巧有序。
   这一步是长句可用的前提，而且比原来的束搜索**又准又快**。
4. **模型重排。** Qwen3-0.6B 在独立进程里给前 16 个候选打上下文分。上下文优先
   取**输入框里光标前的真实文本**——你在邮件里接着别人的话写，模型看到的就是
   那封邮件。这一步是异步的：分数回来就原位重排，新按键一到就取消旧请求。
5. **你的习惯最后加权。** 选过的词往前排，翻页跳过的默认词轻微降权。

模型进程崩了、还没启动、或者被内存压力收走？词典引擎照常工作，你最多损失
"更懂上下文"的那部分排序，打字本身永远不停。

### 同一串拼音，两种前文

传统输入法不管你正在回复什么，同一串拼音永远同一个排序。笔灵读的是光标前的
真实文本，所以第一候选跟着你的话走：

| 你写到一半的话 | 接着输入 | 第一候选 |
|---|---|---|
| 他这辈子行医救人，是一位好 | `yisheng` | **医生** |
| 这句话让我受用 | `yisheng` | **一生** |
| 爷爷最喜欢下 | `xiangqi` | **象棋** |
| 我突然 | `xiangqi` | **想起** |
| 我们在化学课上做 | `shiyan` | **实验** |
| 他违背了当初的 | `shiyan` | **誓言** |

自己复现：

```bash
"$HOME/Library/Input Methods/BiLing.app/Contents/Helpers/biling-cli" \
  --xpc --context "爷爷最喜欢下" xiangqi
```

前文带来的收益在整个语料上也成立：全拼 52.9% → 66.1%，缩写 33.2% → 50.0%。

真实候选窗（AppKit 原生控件，非拼图）：

![笔灵候选窗实机渲染](Docs/candidate-panel.png)

## 键盘

| 按键 | 动作 |
|---|---|
| `a`–`z`、`'` | 组合拼音 |
| 空格 | 上屏高亮候选 |
| `1`–`9` | 上屏对应编号候选 |
| ← / → | 移动高亮 |
| ↑ / ↓ | 翻页 |
| Return | 原样上屏字母串 |
| Esc | 取消组合 |
| ⌘ / ⌃ / ⌥ 组合键 | 先上屏字面输入，快捷键继续传给应用 |

中文语境下 `,` `.` `?` `!` `:` `;` 自动转全角；中英文相邻自动补空格；两者都能
在设置里关。

**缩写**：整串首字母出词（`jldx` → 吉林大学、`zgrm` → 中国人民），也可以按词
偷懒（`jilindxmeiykongt` → 吉林大学没有空调）。字母串本身是合法全拼时全拼优先，
`fan` 永远是 饭。

**中英混输**不用切换模式：`economicslajizhuanye` → economics 垃圾专业，
`yongvscodexiedaima` → 用 VS Code 写代码。大写字母开头直接进入字面模式，
`iPhone` 不会被强行转换。

## 学习与隐私

![选一次，下一次就更顺手](Docs/learning-zh.svg)

- 每次有效选择立刻写进本地库：AES-GCM 加密，密钥在 Keychain，目录排除在
  Time Machine 与 iCloud 备份之外；
- 学的是"哪个拼音你选了哪个词"的计数，不是按键流水；
- 这些场景永远不学：Secure Input（密码框）激活时、终端和密码管理器里、长数字、
  URL、邮箱、高熵字符串、以及你用 Return 原样上屏的内容；
- "笔灵设置 → 学习与隐私"能看到它学的每一条，也能一键全部清掉。

### LoRA 个性化（进阶，可选）

```bash
./scripts/train_lora.sh
```

用你的选择记录在本机微调模型，全程离线；删除生成的文件即回退。首次运行会建一个
私有 venv 并下载基座模型与转换依赖。

## 性能与能耗

| 项 | 实测 |
|---|---|
| 输入法进程（未开始输入） | 29.6 MB |
| 引擎进程（词库与 n-gram 已载入） | 124 MB |
| 模型守护进程（模型已载入） | 620 MB，其中约 400 MB 可被系统回收 |
| 空闲 10 分钟后 | ≈ 6 MB（模型整体卸载） |
| 纯拼音候选延迟 | 3.8 ms 中位 |
| 缩写输入候选延迟 | 15–20 ms 中位 |
| 模型重排 | 25–50 ms，异步 |

没有任何定时器：不做周期健康检查、不轮询状态。模型懒加载、空闲卸载。低电量
模式下自动把会话切给苹果自带拼音。

## 自己验证

```bash
swift test                                                   # 26 项单元测试
python3 scripts/build_eval_corpus.py --fetch --limit 800     # 生成推导语料
.build/release/biling-cli --evaluate Tests/Corpus/derived-test.tsv
```

```bash
# 词典引擎单独跑（不加载模型）
.build/release/biling-cli --engine-only jilindaxuelajixuexiao
# 已安装的 XPC 服务（和真实输入路径同一条链）
"$HOME/Library/Input Methods/BiLing.app/Contents/Helpers/biling-cli" \
  --xpc jilindaxuelajixuexiao
```

CLI 的排序和输入法用的是同一个混分函数，打印出来的就是你打字时看到的顺序。

## 故障排查

**选了笔灵没反应** —— 重新跑一遍安装器，然后注销登录。

**候选窗一直显示"Qwen · 暂不可用"** —— 词典候选不受影响，可以继续打字。看
`~/Library/Application Support/BiLing/engine.log`；launchd 会自动重启模型进程。

**密码框里打不出字** —— 正常。macOS 在 Secure Input 下会绕过所有第三方输入法。

## 卸载

```bash
./scripts/uninstall.sh
```

App 和两个 LaunchAgent 移到废纸篓。学习数据保留在
`~/Library/Application Support/BiLing`，想一起清的话先在设置里点清除。

## 工程结构

```text
Sources/
├── PinyinLattice/      拼音切分：音节表、切分格、模式判定
├── BackboneEngine/     词典索引、精确格解码、打分模型、加密学习库
├── InputSessionCore/   纯函数按键路由（可单测）
├── IPCProtocol/        带代次标记的 XPC 协议
├── LLMRanker/          llama.cpp 桥 + Qwen 排序器
├── BiLingEngine/       模型守护进程：懒加载、空闲卸载、连接校验
├── BiLingApp/          IMKit 控制器、候选窗、设置界面
└── BiLingCLI/          诊断与评测 CLI
scripts/
├── build_dictionary.py 编译词库（含缩写码）
├── build_bigrams.py    训练词间转移模型
├── build_eval_corpus.py 生成推导评测语料
├── apple_baseline.swift 驱动系统输入法做对比基线
└── train_lora.sh       本机 LoRA 个性化
```

## 词库、模型与致谢

- 词库：[万象拼音](https://github.com/amzxyz/rime_wanxiang)（CC BY 4.0）与
  [Rime pinyin-simp](https://github.com/rime/rime-pinyin-simp)（Apache-2.0），
  编译成只读 SQLite，1,440,094 条词条；
- 转移模型训练语料：[Leipzig Corpora Collection](https://wortschatz.uni-leipzig.de/)
  中文新闻与维基百科，169 万句（与评测语料重合的句子已剔除）；
- 模型：[Qwen3-0.6B-Base](https://huggingface.co/Qwen/Qwen3-0.6B-Base)
  Q4_K_M（Apache-2.0）；
- 解码器形式参考 [libime](https://github.com/fcitx/libime)，缩写门控规则参考
  [librime](https://github.com/rime/librime)。

本项目采用 Apache-2.0 许可，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
