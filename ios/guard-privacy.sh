#!/bin/bash
# 隐私红线守卫。方案里用户的原话：「录音在用户自己的手机上，服务器不碰」
# 「录音在满足用户学习的情况下不碰，决不训练模型」。
#
# 这条不能只靠"现在没人调用"来保证 —— 函数还在，哪天顺手一调承诺就破了。
# 所以在 CI 里守着：App 代码里只要重新出现把录音数据发出去的路径，构建就红。
set -u
cd "$(dirname "$0")/Sources"
BAD=0

# 1) 不许再出现上传录音的接口
# 只看真代码，跳过注释行（说明为什么删掉它的那段注释本身会被误伤）
if grep -rn "uploadRec\b\|/api/rec\"" . | grep -v "^\S*: *//" | grep -v "^\S*: *\*" ; then
  echo "❌ App 代码里出现了上传录音的接口"; BAD=1
fi

# 2) 录音文件的字节不许进网络请求体
#    （httpBody 赋值的地方，附近不许提到录音数据）
if grep -rn -B3 "httpBody" . | grep -iE "rec(ord)?(ing)?Data|wav|m4a|audioData" ; then
  echo "❌ 有把录音字节塞进请求体的嫌疑"; BAD=1
fi

[ $BAD -eq 0 ] && echo "✅ 隐私红线：没有上传录音的代码路径"
exit $BAD
