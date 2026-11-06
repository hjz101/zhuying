import SwiftUI

struct ProductionRecordSyncView: View {
    @Environment(\.themeAppearance) private var appAppearance
    @ObservedObject var controller: RecordSyncController
    @State private var pendingAccount: String?
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:23) {
                AppPageHeader(title:"记录同步",subtitle:"书架 · 当前位置 · 书签 · 阅读偏好",icon:"arrow.triangle.2.circlepath.icloud")
                AppSettingsCard("配置与选项",icon:"slider.horizontal.3") {
                    Toggle("启用自动记录同步",isOn:Binding(get:{controller.enabled},set:{ enabled in if enabled { Task { do { let account = try await controller.prepareAccount(); pendingAccount = account } catch { self.error = error.localizedDescription } } } else { controller.disable() } })).disabled(controller.busy).accessibilityIdentifier("recordSyncEnabled")
                    Text(controller.account == nil ? "当前账号尚未确认" : "已确认当前设备 iCloud 账号").font(.system(size:12))
                    if let date = controller.lastSync { Text("上次同步：\(date.formatted())").font(.system(size:11)) }
                    Button("立即同步") { controller.synchronize() }.disabled(!controller.enabled || controller.busy).accessibilityIdentifier("recordSyncNow")
                }
                if controller.busy { ProgressView("正在合并记录") }
                if let message = error ?? controller.message { Text(message).font(.system(size:12)).foregroundStyle(appAppearance.palette.accent).accessibilityIdentifier("recordSyncMessage") }
                if let state = controller.state,!state.conflicts.isEmpty {
                    AppSettingsCard("待确认的冲突",icon:"arrow.triangle.branch") {
                        Text("并发删除优先；其他值暂按设备序号确定。选择一个版本后会生成新的合并记录。").font(.system(size:12))
                        ForEach(state.conflicts,id:\.self) { key in
                            VStack(alignment:.leading,spacing:9) {
                                Text(key.components(separatedBy:":").first ?? "记录").font(.system(size:13,weight:.medium))
                                ForEach(Array((state.alternatives?[key] ?? []).enumerated()),id:\.offset) { _,version in
                                    Button("\(version.deleted ? "保留删除" : "使用此版本") · 设备 \(version.device.prefix(8)) · \(version.counter)") { controller.synchronize(resolving:[key:version]) }.font(.system(size:12)).disabled(controller.busy)
                                }
                            }
                        }
                    }
                }
                Text("默认关闭。启用后，在前台且退出阅读时合并记录，约每 30 秒检查一次。当前位置与最远读过位置独立；删除保留标记，离线旧编辑不会自动复活。正文、PDF／漫画图片、字体和皮肤资源不随记录上传，新设备需要完整备份恢复；缺正文时保留章节身份和历史，不伪造内容。账号变化会停止自动同步并要求重新确认。")
                    .font(.system(size:12)).foregroundStyle(appAppearance.palette.muted)
            }.padding(22)
        }.appPageStyle().navigationTitle("记录同步").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("合并当前设备与此 iCloud 账号的记录？",isPresented:Binding(get:{pendingAccount != nil},set:{if !$0 { pendingAccount = nil }}),titleVisibility:.visible) {
                Button("启用并合并当前书库") { guard let account = pendingAccount else { return }; pendingAccount = nil; Task { do { try await controller.enable(account:account); error = nil; controller.synchronize() } catch { self.error = error.localizedDescription } } }
                Button("取消",role:.cancel) { pendingAccount = nil }
            } message: { Text("这会把当前设备的书架、进度、书签和偏好与所选账号合并。不同账号之间需要重新确认；建议先保留完整本地备份。") }
    }
}
