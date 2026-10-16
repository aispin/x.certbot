# 手动路径（单域名）

**什么时候用这个**：你只有一个域名，不想配置整套 GitHub Actions，也不想把云凭据放进仓库。

**什么时候别用**：多个域名、想要自动续期、想让证书变更可追溯 —— 用
[方案三](../../docs/07-github-actions-cert-sync.md)。那套脚本**在本地也能跑**
（只有 Step Summary 依赖 Actions），只是要写一份 `deploy/domains.yml`。

## 两个脚本

| 脚本 | 作用 |
| --- | --- |
| `issue-and-install.sh` | 一次性：用 acme.sh + 阿里云 DNS-01 签发证书，并 `--install-cert` 到稳定路径，同时把 `deploy-cert-to-cloudbase.sh` 挂成续期钩子 |
| `deploy-cert-to-cloudbase.sh` | 把证书上传到腾讯云 SSL → 拿到证书 ID → 重绑 CloudBase 自定义域名 → 回读校验。**幂等，可反复手工执行** |

调用链：

```
acme.sh --issue（阿里云 DNS-01）
  → --install-cert（复制到稳定路径，再执行 reloadcmd）
    → deploy-cert-to-cloudbase.sh
      → tcb api ssl UploadCertificate
        → tcb domains edit --certid
```

## 前置

- `acme.sh`（`curl https://get.acme.sh | sh -s email=你的邮箱`）
- `tcb`（CloudBase CLI）
- 环境变量（**只在你本机**，不提交）：

| 变量 | 说明 |
| --- | --- |
| `CERT_DOMAIN` | 域名，默认写成 `gitalk.xsin.work`，换成你自己的 |
| `ALIYUN_SECRET_ID_DNS` / `ALIYUN_SECRET_KEY_DNS` | 阿里云 RAM 凭据，DNS-01 用（需要 `alidns:DescribeDomainRecords` / `AddDomainRecord` / `DeleteDomainRecord`） |
| `CLOUDBASE_SECRET_ID` / `CLOUDBASE_SECRET_KEY` | 腾讯云子账号凭据（需要 `QcloudSSLFullAccess`，以及 CloudBase 的 `QcloudAccessForTCBRole`） |

> ⚠️ 不要用腾讯云主账号密钥：它默认可操作账号下全部资源。
> 也不要用 CloudBase 的「环境级 API Key」——它没有追加 CAM 策略的通道，传证书会失败。

## 用法

```bash
export CERT_DOMAIN=your.domain
export ALIYUN_SECRET_ID_DNS=... ALIYUN_SECRET_KEY_DNS=...
export CLOUDBASE_SECRET_ID=...  CLOUDBASE_SECRET_KEY=...
export CLOUDBASE_ENV_ID=env-xxxxxxxx

bash issue-and-install.sh          # 首次：签发 + 挂钩子（会立刻跑一次同步）
bash deploy-cert-to-cloudbase.sh   # 之后任何时候都可手工重跑
```

## 前提与限制

- 域名**必须已完成 ICP 备案**：CloudBase 绑定自定义域名要求备案，这是行政前置
- 该域名**必须已经在 CloudBase 里绑定过**。本脚本只负责**换证书后重绑**，不负责首次绑定
  （首次请用 `tcb domains add`，并要求先做域名归属校验）
- **证书换新后必须重绑**：CloudBase 存的是证书 ID 指针，换了新证书 ID 不变就没生效 ——
  这正是这个脚本存在的理由
- 建议定期演练一次 `acme.sh --renew -d "$CERT_DOMAIN" --force`，别等 60 天后才发现钩子坏了

## 验证边界

脚本做过 `bash -n` 语法检查和**用假 `tcb` 的端到端演练**（覆盖上传 → 解析证书 ID → 重绑 → 回读校验，
以及重复执行命中幂等分支、证书与私钥不匹配时报错退出）。**未对真实腾讯云接口发起过请求** ——
首次真实执行请当作首次验证。
