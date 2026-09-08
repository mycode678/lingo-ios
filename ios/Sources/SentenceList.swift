import SwiftUI

/// 例句清单。查词页和精听台共用同一份 —— 两边各写一遍迟早不一致（网页版就吃过这个亏）。
/// 手机上它是一张从底部拉起来的表：点一句直接跳过去，当前这句自动滚到眼前。
struct SentenceListSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    /// 选中哪一句（下标是 store.items 里的位置）
    var onPick: (Int) -> Void
    /// 查词页还要"整条连播"，精听台不需要
    var playAll: (() -> Void)?
    var stopAll: (() -> Void)?
    var isPlayingAll: Bool = false

    @AppStorage("list.filter") private var filter = "all"
    @AppStorage("ui.listFont") private var listFont = 15.0

    private var rows: [(Int, Api.Sentence)] {
        Array(store.items.enumerated()).filter { _, s in
            let p = store.prog[s.src]
            switch filter {
            case "fav":  return (p?.fav ?? 0) == 1
            case "new":  return (p?.reps ?? 0) == 0
            case "mark": return (p?.marks ?? 0) > 0
            case "due":  return (p?.reps ?? 0) > 0 && (p?.due ?? 0) <= Date().timeIntervalSince1970
            default:     return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 筛选钉在顶上，不跟着列表滚 ——
                // 一百多条例句滚到中间想点"收藏"，还得先滑回顶部，太折腾。
                filterBar
                Divider()
                ScrollViewReader { proxy in
                List {
                    ForEach(rows, id: \.1.src) { idx, s in
                        Section {
                            Button {
                                onPick(idx)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    dot(s)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.en)
                                            .font(.system(size: listFont))
                                            .foregroundStyle(idx == store.index ? Color.accentColor : .primary)
                                        if let cn = s.cn, !cn.isEmpty {
                                            Text(cn).font(.system(size: listFont - 2.5))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    marks(s)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(idx == store.index
                                               ? Color.accentColor.opacity(0.10) : Color(.systemBackground))
                            .id(idx)
                        } header: {
                            if idx == 0 || store.items[idx - 1].grp != s.grp {
                                Text(s.gnum ?? s.grp ?? "").font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onAppear {                       // 打开就滚到当前这句，省得自己找
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation { proxy.scrollTo(store.index, anchor: .center) }
                    }
                }
                }
            }
            .navigationTitle("\(store.word) · \(rows.count)/\(store.items.count) 句")
            .navigationBarTitleDisplayMode(.inline)
            // 收起放左边：单手拿手机时左上比右上好够（右手拇指横过去更远）
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("收起") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// 顶上钉住的一条：筛选 + （查词页才有的）整条连播
    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach([("all", "全部"), ("fav", "★ 收藏"), ("new", "没练过"),
                             ("mark", "有难点"), ("due", "该复习")], id: \.0) { k, n in
                        Button { filter = k } label: {
                            Text(n).font(.system(size: 12.5))
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(filter == k ? Color.accentColor
                                                        : Color(.secondarySystemBackground))
                                .foregroundStyle(filter == k ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
            if let playAll {
                Button { isPlayingAll ? stopAll?() : playAll() } label: {
                    Image(systemName: isPlayingAll ? "stop.fill" : "play.fill")
                        .font(.system(size: 13))
                        .frame(width: 34, height: 30)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .background(.bar)
    }

    private func dot(_ s: Api.Sentence) -> some View {
        let p = store.prog[s.src]
        let c: Color = (p?.state ?? 0) == 2 ? .green : ((p?.reps ?? 0) > 0 ? .orange : .gray.opacity(0.4))
        return Circle().fill(c).frame(width: 8, height: 8).padding(.top, 6)
    }
    private func marks(_ s: Api.Sentence) -> some View {
        let p = store.prog[s.src]
        return HStack(spacing: 4) {
            if (p?.fav ?? 0) == 1 { Image(systemName: "star.fill").foregroundStyle(.orange) }
            if let m = p?.marks, m > 0 {
                HStack(spacing: 1) { Image(systemName: "flag.fill"); Text("\(m)") }
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10))
    }
}
