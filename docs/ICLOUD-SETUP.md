# iCloud 构建配置

当前未签名开发构建保持 iCloud 关闭，并在原生 iCloud 页面显示原因；用户已说明暂时无法提供真机与开发团队，不重复要求。原生传输与备份界面已接入，模拟传输模型不替代真实账号验收。

具备签名条件后，在 Xcode 对应用目标启用 iCloud Documents，容器与 `YueshanCloudContainer` 一致（默认 `iCloud.com.yueshan.reader`）。可参考 `ios/Yueshan/iCloud.entitlements.example`，由实际开发团队生成授权；在目标 Info 中设置布尔 `YueshanCloudEnabled=true`，并将签名权限文件配置为该团队实际可用容器。不要仅改布尔开关而省略授权。

完整备份使用该容器 `Documents/Yueshan/Backups`；记录日志保留在 `Records-v1`。备份在应用内下载校验、再次确认后恢复，旧书库保留为回滚代。上传状态由系统管理，文件写入成功不等于远端上传已完成。尚未下载的文件先请求系统下载，未就绪返回可重试状态。

传输每次检查当前账号，换账号会停止页面操作并清空待恢复对象；读取、写入使用 NSFileCoordinator，并支持取消。仍需在有授权的实际设备验证无账号、账号切换、断网、配额、后台上传、新设备下载与恢复。记录同步的完整应用接入和冲突操作继续单列，不能仅依据模型测试宣布 T056 完成。
