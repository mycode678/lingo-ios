# 听说训练台 · iPhone App

把朗文当代6双解当教材，系统地练**精听**和口语：查词 → 把词收进学习计划 →
在波形上圈出听不懂的那半秒反复听 → 跟读录音打分 → 按记忆曲线复习。

**不是网页套壳**：除了词典正文那一块用 WKWebView 渲染朗文自带的 HTML 排版
（义项、搭配框、同义词框、音标、插图，重写不现实也排不好），其余全部原生 ——

- **AVAudioEngine 播放引擎**：变速不变调、A-B 段精确循环、零延迟起播
- **音量键切上一句/下一句**（监听 outputVolume 再复位；这是网页绝对做不到的）
- **锁屏 / 耳机 / 车机控制**，走路通勤时屏幕黑着也能练
- **自绘波形**：单指平移、双指缩放、点一下把最近的边界拉过来、长按画选区、两端大手柄
- **按停顿自动切小句**（用服务端的强制对齐结果），一点就只听那一个意群
- **离线缓存**：一个词的例句先下到手机，出门没网也能练

后端是自己家里那台服务器（`/opt/dict`，词典 + 强制对齐 + 学习进度），
App 里填地址就行，公网走 Cloudflare 隧道 + Basic Auth。

## 编译

CI 每次推送自动出一个**未签名的 .ipa**（Actions → build-ipa → Artifacts），
用 [SideStore](https://sidestore.io) 在手机上用自己的 Apple ID 签名安装。

本地编译：
```bash
brew install xcodegen
cd ios && xcodegen generate && open Lingo.xcodeproj
```
