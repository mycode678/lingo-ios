# iPhone 原生 App（进行中）

**不是把网页包一层。** 除了词典正文那一块用 WKWebView 当"富文本控件"渲染朗文自带的 HTML
（义项、搭配框、同义词框、音标、插图，重写一遍不现实也排不好，欧路/有道/Kindle 都这么做），
其余全部原生：播放引擎、波形、精听交互、锁屏控制、音量键切句、离线缓存、复习。

服务端一行不用改，全走 `/opt/dict` 已有的 HTTP 接口。

## 已经写好的

源码按分层放（见根目录 `ARCHITECTURE.md`），**上层只能调下层**：

| 目录/文件 | 干什么 |
|---|---|
| `Sources/App/` | `LingoApp` 入口、`AppEnv` 依赖注入、`Demo` 演示数据、`DBSelfTest` 库自检屏 |
| `Sources/Engines/` | 全在本机算的引擎：`Player` 播放（变速不变调、A-B 精确循环）、`Aligner` CTC 强制对齐（CoreML）、`Speech` 离线识别、`Compare` 逐词打分与诊断、`Recorder` 录音、`VolumeKeys` **音量键切上下句**、`NowPlaying` 锁屏/耳机控制 |
| `Sources/Stores/` | `DB` 本机 SQLite（进度/收藏/难点/录音索引/额度）、`Cache` 音频沙盒缓存、`Api` 服务端接口（正在降级成可选备份通道） |
| `Sources/Services/` | 业务层（`Store` 在这儿，其余 Service 待建） |
| `Sources/Screens/` | `Today/` `Catalog/` `Drill/` `Mine/` 四组界面，精听台在 `Drill/` |
| `Sources/UI/` | `Theme` 设计 token、`WaveView` 波形（自己画自己收手势）、`TextStyle`、`Audit` 布局体检 |
| `guard-privacy.sh` | 隐私红线守卫：App 里只要再出现上传录音的代码路径，CI 就红 |
| `project.yml` | XcodeGen 工程定义（.pbxproj 是生成物，不手写） |

## 还没写

- `DrillModel` / 各个界面（精听、复习、查词、我的库、随身模式）
- 录音 + 跟读打分（DTW/音高，用 Accelerate 重写）
- 设置页（服务器地址、账号密码、缓存管理）

## 怎么跑起来（Mac 上）

```bash
brew install xcodegen
cd ios && xcodegen generate && open Lingo.xcodeproj
```
Xcode 里选自己的 Apple ID 签名，插上 iPhone 点运行。免费账号签名 7 天到期，
到期在 Xcode 里重新运行一次即可；付费开发者账号（99 美元/年）是一年。

服务器地址在 App 的设置里填，默认 `https://192.168.8.191:8445`。
公网走 Cloudflare 隧道时填隧道域名，账号密码用 nginx 那套 Basic Auth。
