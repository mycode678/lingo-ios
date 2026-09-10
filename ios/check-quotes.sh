#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""中文引号守卫。

栽过的坑：在 Swift 字符串里写中文时，把「」打成了 ASCII 的 "，
于是 "……你觉得"说得快"……" 这一串在编译器眼里是三段，中间那段变成了标识符，
报一堆 cannot find '说得快' in scope。一次推送因为这个整轮 CI 白跑。

这个脚本几毫秒跑完，放在 CI 最前面（跟隐私守卫一起），编译都不用等。
判据：一个 ASCII 引号，前一个字符是汉字，而后一个字符不是"收尾该出现的东西"
（右括号、逗号、加号、空格、行尾）——那它一定是被当成中文引号用了。
"""
import re, sys, glob, os

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "Sources"))

def is_cjk(c):
    return c and '一' <= c <= '鿿'

bad = []
for f in sorted(glob.glob('**/*.swift', recursive=True)):
    in_multiline = False
    for i, line in enumerate(open(f, encoding='utf-8'), 1):
        st = line.strip()
        if st.count('"""'):
            in_multiline = not in_multiline
            continue
        if in_multiline or st.startswith('//'):
            continue
        # 行尾注释里怎么写都行（那不进编译），只看代码部分。
        # 找第一个"不在字符串里"的 //。
        depth_in_str = False
        cut = len(line)
        k = 0
        while k < len(line) - 1:
            c = line[k]
            if c == '\\':
                k += 2; continue
            if c == '"':
                depth_in_str = not depth_in_str
            elif c == '/' and line[k+1] == '/' and not depth_in_str:
                cut = k; break
            k += 1
        line = line[:cut]
        for m in re.finditer(r'"', line):
            j = m.start()
            prev = line[j-1] if j else ''
            nxt = line[j+1] if j + 1 < len(line) else ''
            # 收尾之后合法能跟的东西：括号、逗号、拼接、点号（.utf8）、分号、行尾…
            if is_cjk(prev) and nxt not in (')', ',', '+', ' ', ']', '}', ':', ';',
                                            '.', '', '\n', '"'):
                bad.append(f"{f}:{i}: {line.strip()[:100]}")

if bad:
    print("❌ 中文里把引号打成了 ASCII 的 \"（该用「」）：")
    for b in bad:
        print("   " + b)
    sys.exit(1)
print("✅ 中文引号：没有把 「」 打成 \" 的地方")
