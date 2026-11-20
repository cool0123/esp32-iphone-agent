import SwiftUI

struct LegacyOpsSection: View {
    @ObservedObject var ops: OpsController
    var body: some View {
        Section(header: Text("远程运维")) {
            TextField("管理服务地址", text: $ops.endpoint)
                .autocapitalization(.none).disableAutocorrection(true).keyboardType(.URL)
            SecureField("设备令牌", text: $ops.token)
                .autocapitalization(.none).disableAutocorrection(true)
            Toggle("启用远程运维", isOn: $ops.enabled)
            Toggle("允许电脑下发调试任务（本次运行）", isOn: $ops.acceptsTasks).disabled(!ops.enabled)
            Toggle("允许运维更换模型 API Key（仅 HTTPS）", isOn: $ops.allowsKeyRotation)
                .disabled(!ops.enabled || !ops.secureEndpoint)
            Button("重新连接运维服务") { ops.start() }.disabled(!ops.enabled)
            Text(ops.state)
            Text("换密钥授权会保留；更改运维地址或令牌后需要重新开启。电脑不能读取密钥。")
                .font(.footnote)
            Text("开启屏幕镜像后离开本 App，即可从电脑下发任务。画面失效或收到停止指令后会中止。")
                .font(.footnote)
        }
    }
}
