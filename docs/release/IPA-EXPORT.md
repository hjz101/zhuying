# 本地 IPA 导出

## 未签名 IPA

使用关闭签名的真机 Release 构建，通过 `--unsigned` 打包。不读取或使用证书、密码、描述文件，不修改应用标识。不能使用模拟器 App。

```sh
python3 ios/scripts/export-ipa.py \
  --app /path/to/Release-iphoneos/Zhuying.app \
  --unsigned \
  --output artifacts/0.8.0/ipa/竹影-0.8.0-build10-unsigned.ipa
```

此模式检查主 Info.plist、arm64 可执行文件与权限、ZIP 本地文件头和 CRC，并拒绝残留的描述文件、签名资源和主程序 Mach-O 签名命令。生成的同名 JSON 明确记录 `kind: unsigned-device`、`codeSigned: false`、源码提交、构建号与 SHA-256。未签名包可交给用户选择的签名工具处理，不是可直接安装的签名版本。

## 使用本地材料签名

`ios/scripts/export-ipa.py`将已有iPhoneOS App打包为`Payload/Zhuying.app`结构并签名。输入为本机私有目录中的`identity.p12`、`profile.mobileprovision`和`password`三个文件；不要将证书、私钥、密码、描述文件提交Git。提供目录前需在本地安全地从证书包读取材料，不执行压缩包内的指令。

导出前要求输入 App 的显示名为“竹影”，产品名和可执行文件名均为 `Zhuying`；旧名称的构建会被拒绝，不能仅改 IPA 文件名。

压缩包使用标准 ZIP，直接包含 `Payload/Zhuying.app/`。主 `Info.plist` 保持 Xcode 的二进制格式，并先于依赖资源包的 plist 写入；排除 `._Info.plist`、其他 AppleDouble 文件、`.DS_Store` 和 `__MACOSX`。ZIP 本地文件头完整记录 CRC 与压缩前后尺寸，避免依赖流式数据描述符。

工具核对描述文件CMS完整性、有效期、证书绑定、设备范围、应用标识和钥匙串组；通过隔离的临时钥匙串签名，最后删除该钥匙串。Apple签发链仅导入临时钥匙串，不改变系统信任设置。证书密码不出现在工具输出、报告或仓库中。

如果描述文件限定固定应用标识，导出副本使用该标识，工程配置和输入App不修改。此时生成的应用与原标识的安装数据、升级身份和钥匙串范围不同。存在扩展／嵌套应用时拒绝导出，需分别准备其描述文件。

导出后严格核对主 App 的精确路径、plist 必需字段、arm64 可执行文件及其权限、描述文件、签名资源、本地 ZIP 文件头和 CRC；再次解压成品，验证签名、权限和 plist 内容，并生成同名 JSON，记录应用源码提交与导出工具提交、实际安装标识、有效期、字节数和 SHA-256。结构或解压后签名验证失败会删除本次失败产物。只导出本地文件，不上传或安装到用户真机；安装仍受描述文件登记设备、有效期和 Apple 实际证书状态约束。IPA 签名成功不代替原计划的真机、签名升级反馈、iCloud 双设备或性能发布验收。

```sh
python3 ios/scripts/export-ipa.py \
  --app /path/to/Release-iphoneos/Zhuying.app \
  --material /path/to/private-material \
  --output artifacts/0.8.0/ipa/Zhuying.ipa
```

## 无预置书源检查

从 build 15 起，发行包首次书源列表为空，具体书源由用户自行导入。导出后执行：

```sh
python3 ios/scripts/verify-source-free-package.py \
  --ipa artifacts/0.8.0/ipa/竹影-0.8.0-build15-unsigned.ipa \
  --output artifacts/0.8.0/ipa/竹影-0.8.0-build15-unsigned-source-free.json
```

也可用 `--app` 检查构建后的 App。工具检查发行声明、资源中的具体书源定义，以及可执行文件中的已知预设标记；不会把通用 JSON Schema、解析接口或本地书籍样章当作书源。新库空源、外部导入及删除后重启还需实际 Release 界面验证，不能只凭声明字段判断。
