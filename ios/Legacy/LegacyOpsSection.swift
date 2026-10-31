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
            Button("重新连接运维服务") { ops.start() }.disabled(!ops.enabled)
            Text(ops.state)
            Text("可查看状态、日志和新鲜截图，修改模型配置、测试模型连接及停止任务。")
                .font(.footnote)
        }
    }
}
