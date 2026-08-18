# Data Protection Policy

- policyVersion：1
- 适用：Recovery（P0）、Sync pending/baseline（E4）、AI Session（E4）

## 密钥与算法

每个数据域使用独立随机 256-bit master key，存于 Keychain，`kSecAttrSynchronizable=false`、ThisDeviceOnly、仅指定签名 Core/Broker access group 可读。正文/blob 以分块 AES-256-GCM 加密；每块使用随机 96-bit nonce，AAD 绑定 policyVersion、domain、document/workspace/session ID、blob ID、chunk index 和明文长度。content ID/去重键使用域密钥派生的 HMAC-SHA-256，不暴露正文裸 hash。

SQLite 只存密文 payload 和非敏感索引；正文禁止进入 WAL、rollback journal、FTS、日志或崩溃报告。临时明文优先使用内存或 unlink 后的受限 FD，禁止写系统通用 temp；导出 staging 是用户主动输出事务，不复用 Store 密钥。

## 生命周期

密钥按版本标识；轮换采用新写新 key、后台逐 blob 重加密、旧 key 仅在迁移完成后删除。删除域数据时先删除 key（crypto-erase），再异步清除 blob/SQLite/WAL/shm；备份默认排除 Recovery、Sync pending 和 AI Session。损坏或认证失败绝不返回部分明文，隔离记录并提供删除/人工恢复入口。

Recovery key 丢失只影响恢复副本，不影响用户文件；Sync/AI 撤权立即删除对应域 key。Release 测试必须扫描容器、WAL/temp、日志和 crash fixture，证明不存在已知明文 canary。
