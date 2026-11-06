# 真实书源验收

普通`Yueshan`测试只使用原创或受控数据，不借用用户登录。额外`Yueshan Live Acceptance` scheme需要在同一模拟器的正式App里已有、经用户授权的书山登录。密码与API Key始终只在应用内，不传给脚本、测试参数或报告。

专用scheme通过`--production --live-source-acceptance`启动：仅Debug识别此标记，Release忽略。它使用单独的LiveAcceptance数据库／导入／字体／缓存／UserDefaults，复用正常正式Keychain已有登录；测试不会登录、登出或编辑账号。普通`--ui-testing`同时出现时禁用此标记，防止普通UI测试混入真实账号。测试书名为公开经典《西游记》《红楼梦》，固定已验证的番茄来源版本；源不可用时测试明确失败，不用替身补通过。

测试实际点击搜索结果、等待详情与目录、打开第一回、连续读三回、退出并终止进程，再重启继续第三回，比较完整渲染内容。只生成公开书名、章节元数据、内容长度／哈希、通过状态与截图，禁止将真实凭据或完整响应导出到Git。其后可恢复正常正式App启动，正常书库不受影响。

另外`--validate-live-library`应用内诊断使用Documents/DevelopmentValidation/LiveLibrary独立正式仓库，验证保存收藏／书签／排版／位置和六章缓存。第二次带`--live-library-restart`，在未配置源网络提供器的新进程里重新打开缓存和记录。诊断不能代替界面点击验收，两项各保留证据。

真实源通过后仍不代表G3发布门槛通过：iOS17与真机、签名／内测、冻结性能，以及音频／云等各自真实服务条件单列。
