# 听说训练台 iOS —— 整体架构

> 配套文档：`/opt/dict/PLAN.md`（产品方案，用户原话）。
> 方案定什么，这里就怎么落。有冲突以 PLAN.md 为准。
>
> **这份文档管"整体"**：分层、数据、目录、界面骨架。
> 先把这一层定死再做单个功能 —— 不然做到一半发现要动整体，前面白干。

---

## 一、现在的问题（为什么必须先动架构）

现在所有数据都从 `Api.swift` 走网络到 191 那台服务器：查词、例句、词边界、
收藏、进度、录音、打分，一样都不少。方案定的却是**完全脱离服务器**。

也就是说：**现在的数据流方向是反的**。再往上堆功能（材料库、教程、AI 拆解、
会员额度），堆得越多，将来掉头改得越狠。所以先掉头。

掉头之后服务器只剩两件事，而且都不是必需的：
1. 放材料包给 CDN 回源（以后直接传 CDN，服务器可以不出现）
2. 我自己用的 PC 网页版（用户根本接触不到）

---

## 二、分层

从上到下四层，**上层只能调下层，不许反过来**：

```
┌─ 界面层  Screens/          今天 · 材料 · 精听 · 我的 · 教程
├─ 业务层  Services/         目录 权益 练习 教练 奖励
├─ 存储层  Stores/           SQLite  文件  Keychain
└─ 引擎层  Engines/          播放 对齐 识别 比对 —— 全部本机算
```

**引擎层**（已经跑通，不动）
- `Player` 播放、变速、区间循环
- `Aligner` 本机 CTC 强制对齐（CoreML，实测跟服务器差 6 毫秒）
- `Speech` 本机识别（`SFSpeechRecognizer` 离线）
- `Compare` 逐词打分 / 节奏 / 连读 / 一句话诊断

**存储层**（要新建，这是这次的重点）
- `DB` —— SQLite。为什么不用 SwiftData：材料包是**预先做好的 .sqlite 文件**
  从 CDN 下下来，SQLite 可以直接 `ATTACH` 上去查，换成 SwiftData 就得逐条导入，
  几万句要导半天。
- `FileStore` —— 音频、录音、封面。录音只在本机，不上传（方案红线）。
- `Vault` —— Keychain，放购买凭证和 API key。

**业务层**（要新建）
- `CatalogService` 材料目录：按身份推荐、分级、下载、解锁
- `EntitlementService` 权益：会员状态、各种额度、看广告解锁
- `PracticeService` 练习：进度、复习排期、七个练法
- `CoachService` AI 拆解：调 DeepSeek / OpenRouter，走额度
- `RewardService` 奖励：达标、分享海报

**界面层**：只跟业务层说话，不许直接碰 SQLite，也不许直接 `Api.xxx`。

---

## 三、数据

### 三个库分开，各管各的

| 库 | 放什么 | 谁写 | 能不能删 |
|---|---|---|---|
| `packs/<id>.sqlite` | 材料包：句子、词边界、译文、难度分级 | 只读，CDN 下来的 | 能，删了重下 |
| `user.sqlite` | 学习进度、收藏、难点、录音索引、额度计数 | App 写 | **不能**，这是用户的命根子 |
| `Recordings/` | 录音文件 | App 写 | 用户自己决定 |

材料包只读、用户数据可写，两边分开的好处：**材料包能随时删了重下，用户数据一个字不丢**。

### 材料包长什么样

一个包 = 一个 zip，CDN 上一个文件：

```
pack-voa-slow-01.zip
├── manifest.json     包 id、名字、级别、句数、总大小、校验和、封面
├── pack.sqlite       sentences(id, en, cn, level, tags)
│                     words(sent_id, idx, word, start, end)   ← 词边界预先算好
└── audio/*.m4a       每句一个文件
```

**词边界随包预先算好**，装机即用；用户自己导入的材料才在手机上现算
（对齐引擎已经验证过，6 毫秒误差）。

### 用户数据表

```
progress(sent_id, reps, ease, due, last_score)     练习进度、复习排期
fav(sent_id, at)                                    收藏
mark(sent_id, a, b, note)                           难点区间
rec(id, sent_id, path, score, at)                   录音索引
quota(kind, period, used, reset_at)                 额度：AI句数/材料数/导入数
unlock(pack_id, sent_id, at, via)                   解锁记录（via: 会员/看广告/奖励）
```

---

## 四、权益（会员）

方案定的：**订阅制 + 买断，3 种 —— 连续包月 / 连续包年 / 买断**。

```
EntitlementService
├─ 状态：free / subscribed(到期日) / lifetime
├─ 判定：StoreKit 2 的 Transaction.currentEntitlements，本机验，不联网
└─ 额度：本地计数 + 周期重置
     预置材料库   每周 50 句，每日 10 句     （方案写死的数）
     AI 拆解     免费用户每天 100 句 / 只给 7 天
     导入材料数   按身份给
     看广告解锁   免费用户额外加量
```

**为什么额度放本地**：脱离服务器是第一原则。作弊风险接受 —— 这类 app 的
付费动力是"想学好"，不是"想白嫖"，为防几个作弊的把所有人绑回服务器不划算。

**词典例句是红线**：朗文的内容默认整个不给。只有两种情况给：
用户自己导入词典文件、或者是我自己的账号。这条写进 `CatalogService` 的入口判断，
不靠界面藏。

---

## 五、界面骨架

四个 tab 不变，但每个 tab 的职责要按方案重新划：

```
今天    今天练什么 · 到期复习 · 连续天数 · 达标进度（奖励入口）
材料    ⬅ 变化最大
        ├ 按身份推荐：小学课本 / 雅思 / TED / 日常口语 / VOA慢速 / VOA标准
        ├ 分级浏览：每包标难度，点开可预览再决定下不下
        ├ 我导入的：本机、iCloud、网盘、播客
        └ 视频跟随：只做词级跟随界面，音视频在用户自己手机上
精听    现在这一屏（波形 · 选区 · 小句 · 录音比对 · AI 拆解）
我的    进度 · 录音 · 会员 · 教程 · 设置
```

教程不单独占 tab（它是"读一遍就够"的东西，不是每天用的），
放「我的」里，但**第一次打开 app 时强推一次**。

---

## 六、目录怎么摆

```
ios/Sources/
├── App/          LingoApp  AppEnv(依赖注入)  Nav
├── Engines/      Player  Aligner  Speech  Compare  VolumeKeys  NowPlaying
├── Stores/       DB  FileStore  Vault  Cache
├── Services/     Catalog  Entitlement  Practice  Coach  Reward
├── Screens/
│   ├── Today/  Catalog/  Drill/  Mine/  Tutorial/
└── UI/           Theme  WaveView  CurveView  共用小控件
```

现在 26 个文件全平铺在 `Sources/`，`DrillScreen.swift` 一个人 1354 行。
按上面分完之后，`DrillScreen` 只留界面，业务挪进 `PracticeService`。

**依赖注入**：现在到处 `Player.shared`、`Store.shared`、`Api.xxx`。
改成一个 `AppEnv` 从根注入。理由不是"优雅"，是**这些单例没法在测试里替换** ——
七个练法、额度、奖励这些逻辑必须能单元测试，不能每次都开模拟器点。

---

## 七、怎么走过去（不推倒重来）

分四步，每步走完 app 都是能跑的：

**第 1 步 · 立骨架**（不动现有功能）
建 `Stores/DB`、`AppEnv`，把 26 个文件按上面的目录归位。
`Api` 继续留着不动 —— 这一步只搬家，不改行为。

**第 2 步 · 数据掉头**
`user.sqlite` 建起来，进度/收藏/难点/录音改成写本地。
`Api` 降级成"可选的备份通道"，断网照常用。

**第 3 步 · 材料包**
做打包工具（在 201 上跑）：一批音频 → 转写 → 对齐 → 分级 → 出 zip。
App 端做下载、校验、`ATTACH`、解锁。
朗文那批做成**只有我自己能装**的包。

**第 4 步 · 往上堆功能**
权益、奖励、AI 拆解、教程、七个练法、视频跟随 —— 这时候每个都只是
往 `Services/` 里加一个文件加一屏，动不到底下。

---

## 八、这份架构解决了什么

| 方案里的要求 | 架构里靠什么保证 |
|---|---|
| 完全脱离服务器 | 三个库全在本机；引擎全在本机；`Api` 降级成可选 |
| 录音服务器不碰 | 录音只进 `FileStore`，没有上传路径 |
| 材料包放 CDN | 包是自包含 zip，下载器只认 URL，换 CDN 改一行 |
| 材料分级 + 按身份推荐 | 分级和标签在 `pack.sqlite` 里，`CatalogService` 只管筛 |
| 朗文例句不外放 | 入口判断在 Service 层，不靠界面藏 |
| 会员三档 + 各种额度 | `EntitlementService` 一处判定，界面只问不算 |
| 七个练法要能测 | 逻辑在 Service 里，能单测，不用开模拟器 |
