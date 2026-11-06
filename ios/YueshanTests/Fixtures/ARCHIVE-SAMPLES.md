# 归档样本

`original-*`、`mixed-books.zip` 和 `unsafe-archive.zip` 使用本项目原创文字／纯色图片制作。分别覆盖 ZIP、RAR4 stored、7z LZMA、自然排序和越界路径；测试会读取实际展开内容，不以扩展名判定成功。

`upstream-rar5-compressed.rar` 来自 libarchive v3.8.7 `libarchive/test/test_read_format_rar5_compressed.rar.uu`（uu 解码），436 字节，SHA-256 `68f9d7e2662cd5bc5607ba9c6bf1edbf121cf3b08011a7d8643091791750a7c8`。上游断言内容为 `test.bin`、1200 字节。许可见 `LIBARCHIVE-RAR5-LICENSE.txt`。

`upstream-encrypted.rar` 来自同版本 `test_read_format_rar_encryption_data.rar.uu`（uu 解码），用于确认当前明确拒绝加密归档。许可见 `LIBARCHIVE-RAR-ENCRYPTION-LICENSE.txt`。

上游固定版本：https://github.com/libarchive/libarchive/tree/v3.8.7/libarchive/test 。这些兼容样本仅用于测试，不作为用户书库内容或在线来源验收。
