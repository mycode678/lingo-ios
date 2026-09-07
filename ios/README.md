# iPhone 原生 App（进行中）

**不是把网页包一层。** 除了词典正文那一块用 WKWebView 当"富文本控件"渲染朗文自带的 HTML
（义项、搭配框、同义词框、音标、插图，重写一遍不现实也排不好，欧路/有道/Kindle 都这么做），
其余全部原生：播放引擎、波形、精听交互、锁屏控制、音量键切句、离线缓存、复习。

服务端一行不用改，全走 `/opt/dict` 已有的 HTTP 接口。

## 已经写好的

| 文件 | 干什么 |
|---|---|
| `Sources/Api.swift` | 服务端接口 + 数据模型；自签证书只对配置的那台放行 |
| `Sources/Player.swift` | AVAudioEngine 播放引擎：变速不变调、A-B 段精确循环、包络给波形用 |
| `Sources/VolumeKeys.swift` | **音量键切上一句/下一句**（监听 outputVolume 再复位，网页做不到） |
| `Sources/NowPlaying.swift` | 锁屏/控制中心/耳机/车机的播放控制 |
| `Sources/Cache.swift` | 音频下到沙盒，走路没网也能练；按最久没用淘汰 |
| `Sources/WaveView.swift` | 波形：自己画自己收手势（单指平移、双指缩放、点一下拉边、长按画选区、大手柄） |
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
