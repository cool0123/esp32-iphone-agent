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
            Toggle("允许台机下发任务", isOn: $ops.acceptsTasks).disabled(!ops.enabled)
            Toggle("允许运维更换模型 API Key（仅 HTTPS）", isOn: $ops.allowsKeyRotation)
                .disabled(!ops.enabled || !ops.secureEndpoint)
            Button("重新连接运维服务") { ops.start() }.disabled(!ops.enabled)
            Text(ops.state)
            Text("换密钥授权会保留；更改运维地址或令牌后需要重新开启。电脑不能读取密钥。")
                .font(.footnote)
            Text("接单设置会保留。台机暂时断连时，手机继续执行；重连后可查看结果。")
                .font(.footnote)
            Text("屏幕镜像运行且本 App 在后台时，手机可接单。")
                .font(.footnote)
        }
    }
}
