# 自建远程后端 v1

沿用 Demo 远程后端入口、设置卡片、密钥字段和连接测试。用户在应用内选择单个书源、填 HTTPS 服务根地址及令牌，明确确认后启用。默认关闭、直连回退默认关闭。密钥保存在设备专用钥匙串，按源／源主机／后端主机隔离；不会进入书库备份、分享或报告。

生效范围：该源原生搜索／目录／正文、段评和明确开启网络的脚本桥。允许的原请求认证头及已启用的浏览器 Cookie 会通过 TLS 发送给后端，启用确认与页面明确说明。账号登录密码、WebKit 页面、云同步和其他服务不经后端。后端与此源代理／DNS／指定IP互斥。仅超时、域名解析／连接失败、离线及连接丢失在明确启用后回退；认证错误、TLS、协议、HTTP状态不回退。

## 部署

Node 22及以上，无第三方运行依赖：

```sh
export YUESHAN_GATEWAY_TOKEN='<在服务器私下设置至少16字符的令牌>'
export YUESHAN_GATEWAY_SOURCES='{"shushan":{"origin":"https://v1.vossc.com","paths":["/search","/details","/catalog","/content","/para","/idea_comment"]}}'
node backend/reader-gateway.mjs
```

示例白名单应按当前源真实端点调整。默认只监听127.0.0.1:8787，前置自己管理的 HTTPS 反向代理；应用内填写 HTTPS 根地址。令牌不写入仓库。不要把服务配置成任意URL的公共代理。管理员负责只配置有权访问的上游、身份验证及TLS。

## 协议与边界

`POST /v1/forward`，`Authorization: Bearer <backend key>`，JSON `{sourceID,sourceOrigin,path,method,headers,bodyBase64?}`。`POST /v1/status`使用同样认证与`{sourceID,sourceOrigin}`做连接探测，核对绑定而不访问上游、不要求开放根路径。服务端通过自身配置确定固定HTTPS源并要求与客户端原始主机一致，精确路径或显式以`/`结尾的子树白名单；客户端不能指定任意源。返回`{version:1,status,headers,bodyBase64}`，恢复原始书源 URL 与 HTTP 状态。错误响应不回显正文、令牌或源查询。

只支持GET／POST、请求1MiB（原POST体512KiB）、上游体4MiB、8个在途请求、15秒上游超时。重定向全部拒绝，保留系统TLS验证；不支持流式/WebSocket。响应只带Content-Type/Retry-After，不传Set-Cookie。服务器不记录请求内容；部署时反向代理日志也应避免敏感查询。

验证包含 Node 真实HTTP服务鉴权／源和路径限制／请求头／重定向／流式长度／超时，iOS协议封装、状态还原、钥匙串隔离和直连策略，以及设置页确认流程。当前交付可自行部署的服务与客户端；未替用户部署外部服务器，用户服务线上联调需其应用内配置。
