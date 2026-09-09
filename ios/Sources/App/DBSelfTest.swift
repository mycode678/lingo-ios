import SwiftUI

/// 本机库的自检屏（只在 `-dbtest` 下出现，正式包里不渲染）。
///
/// 为什么做成一屏而不是单元测试：这个工程没有单元测试 target，
/// 而真正要验的是"**在真机上、杀掉 App 再打开，数据还在不在**" ——
/// 这件事只有 UI 测试能验（它能 terminate 再 launch）。
/// 沿用 `-alignbench` 那一屏的老办法：结果写在带标识的文字上，测试读它。
struct DBSelfTest: View {
    @State private var lines: [(String, String, String)] = []   // 标识、名字、结果

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机库自检").font(.title2.bold())
            ForEach(lines, id: \.0) { id, name, val in
                HStack {
                    Text(name).foregroundStyle(.secondary)
                    Spacer()
                    Text(val).monospacedDigit()
                        .accessibilityIdentifier(id)
                }
                .font(.system(size: 15))
            }
            Spacer()
        }
        .padding()
        .task { run() }
    }

    private func run() {
        // 自检用单独的库文件，绝不碰真的 user.sqlite
        let path = NSTemporaryDirectory() + "selftest.sqlite"
        let write = ProcessInfo.processInfo.arguments.contains("-dbwrite")
        if write { try? FileManager.default.removeItem(atPath: path) }
        let db = DB(testPath: path)
        var out: [(String, String, String)] = []

        do {
            // ① 迁移跑两遍必须一样 —— 幂等是验收标准
            try db.migrate()
            let v1 = db.version
            try db.migrate()
            let v2 = db.version
            out.append(("dbVersion", "库版本", "\(v2)"))
            out.append(("dbIdempotent", "迁移跑两遍",
                        v1 == v2 && v1 == DB.latestVersion ? "一样，OK" : "不一样！\(v1)→\(v2)"))

            // ② 六张表都在
            let tabs = try db.rows(
                "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                .compactMap { $0["name"] as? String }.sorted()
            let want = ["fav", "mark", "meta", "progress", "quota", "rec", "sent", "unlock"]
            out.append(("dbTables", "表",
                        tabs == want ? "八张都在" : "对不上：\(tabs.joined(separator: ","))"))

            // ⑦ 收藏和难点也走本机
            let ps2 = PracticeService(db: db)
            ps2.setFav("selftest/fav", true)
            let favOK = ps2.isFav("selftest/fav")
            ps2.setFav("selftest/fav", false)
            let unfavOK = !ps2.isFav("selftest/fav")
            ps2.setMarks("selftest/mk", [(1.0, 1.5), (2.0, 2.4)])
            ps2.setMarks("selftest/mk", [(1.0, 1.5)])          // 整组覆盖，不许留旧的
            let mk = ps2.marks("selftest/mk")
            out.append(("dbFavMark", "收藏与难点",
                        favOK && unfavOK && mk.count == 1 && abs(mk[0].1 - 1.5) < 1e-9
                        ? "OK" : "不对 fav=\(favOK)/\(unfavOK) marks=\(mk.count)"))

            if write {
                // ③ 写一条进度（这一趟只写，写完测试会杀掉 App）
                try db.run("""
                    INSERT INTO progress(sent_id, reps, ease, due, last_score, updated_at)
                    VALUES(?,?,?,?,?,?)
                    ON CONFLICT(sent_id) DO UPDATE SET reps=excluded.reps
                    """, ["selftest/1", 7, 2.35, 1234.5, 88.0, 1000.0])
                out.append(("dbWrote", "写入", "写好了"))
            } else {
                // ④ 重开之后读回来，值必须一模一样
                let r = try db.row("SELECT * FROM progress WHERE sent_id=?", ["selftest/1"])
                if let r, let reps = r["reps"] as? Int, let ease = r["ease"] as? Double {
                    out.append(("dbReadBack", "重开后读回",
                                reps == 7 && abs(ease - 2.35) < 1e-9 ? "值一样，OK"
                                                                    : "对不上 reps=\(reps) ease=\(ease)"))
                } else {
                    out.append(("dbReadBack", "重开后读回", "没读到"))
                }
            }

            // ⑤ 本地排期：没听懂要 10 分钟后再撞，会了要推到明天以后
            let ps = PracticeService(db: db)
            let now = Date().timeIntervalSince1970
            let d1 = ps.grade("selftest/sm2", 1)
            let ok1 = abs(d1 - (now + 600)) < 30
            _ = ps.grade("selftest/sm2", 3)
            let d3 = ps.grade("selftest/sm2", 3)
            let ok3 = d3 > now + 86400
            out.append(("dbSchedule", "本地排期",
                        ok1 && ok3 ? "OK" : "不对 没听懂+\(Int(d1-now))秒 会了+\(Int((d3-now)/86400))天"))

            // ⑥ 中文和撇号能原样存回来（绑定字符串用错 destructor 会读出乱码，经典坑）
            let s = "劳驾，请问'博物馆'怎么走？"
            try db.run("INSERT OR REPLACE INTO fav(sent_id, at) VALUES(?,?)", [s, 1.0])
            let back = try db.row("SELECT sent_id FROM fav WHERE at=1.0")?["sent_id"] as? String
            out.append(("dbText", "中文原样存取", back == s ? "OK" : "串了：\(back ?? "nil")"))
        } catch {
            out.append(("dbFatal", "出错", "\(error)"))
        }
        lines = out
    }
}
