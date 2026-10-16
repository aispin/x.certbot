# 手动路径（单域名）

**什么时候用这个**：你只有一个域名，不想配置整套 GitHub Actions，也不想把云凭据放进仓库。

**什么时候别用**：多个域名、想要自动续期、想让证书变更可追溯 —— 用
[方案三](../../docs/07-github-actions-cert-sync.md)。那套脚本**在本地也能跑**
（只有 Step Summary 依赖 Actions），只是要写一份 `deploy/domains.yml`。

## 一个脚本，三个子命令

| 子命令 | 作用 |
| --- | --- |
| `issue` | 一次性：用 acme.sh + 阿里云 DNS-01 签发证书，并 `--install-cert` 到稳定路径，同时把**本脚本的 `deploy` 子命令**挂成续期钩子（`--reloadcmd`）。`--install-cert` 会**立刻执行一次**钩子，所以 `issue` 跑完其实已经同步过一次 |
| `deploy` | 把证书上传到腾讯云 SSL → 拿到证书 ID → 重绑 CloudBase 自定义域名 → 回读校验。**幂等，可反复手工执行**；它同时就是 acme.sh 续期钩子的入口 |
| `renew` | 强制续期一次（`acme.sh --renew --force`），用来演练钩子是否真的会触发 |

> 以前这里拆成 `issue-and-install.sh` + `deploy-cert-to-cloudbase.sh` 两个文件，
> 唯一的原因是 acme.sh 的 `--reloadcmd` 需要一个能独立执行的入口。
> 一个脚本 + 子命令同样满足这一点，所以合并成了 `cert.sh`。

调用链：

```
cert.sh issue（acme.sh --issue，阿里云 DNS-01）
  → --install-cert（复制到稳定路径，再 eval --reloadcmd）
    → cert.sh deploy（同一个脚本）
      → tcb api ssl UploadCertificate
        → tcb domains edit --certid
          → tcb domains ls（回读校验）
```

## 前置

- `acme.sh`（`curl https://get.acme.sh | sh -s email=你的邮箱`；`issue` 子命令也会自动装）
- `node`（>=18）、`openssl`
- `tcb`（CloudBase CLI）
- 环境变量（**只在你本机**，不提交）：

| 变量 | 说明 |
| --- | --- |
| `CERT_DOMAIN` | 域名，**必填**（没有默认值） |
| `ACME_EMAIL` | ACME 账户邮箱，可选；不设时用 `admin@<域名去掉首个标签>` |
| `ALIYUN_SECRET_ID_DNS` / `ALIYUN_SECRET_KEY_DNS` | 阿里云 RAM 凭据，DNS-01 用（需要 `alidns:DescribeDomainRecords` / `AddDomainRecord` / `DeleteDomainRecord`） |
| `CLOUDBASE_SECRET_ID` / `CLOUDBASE_SECRET_KEY` | 腾讯云子账号凭据（需要 `QcloudSSLFullAccess`，以及 CloudBase 的 `QcloudAccessForTCBRole`） |
| `CLOUDBASE_ENV_ID` | CloudBase 环境 ID，`env-` 开头（`issue` / `deploy` 必填） |
| `LOG_FILE` | 钩子日志文件，默认 `/var/log/cert-sync.log` |

> 脚本内置的进阶开关（`ACME_SERVER` / `KEY_LENGTH` / `SSL_DIR` / `CERT_FULLCHAIN` /
> `CERT_PRIVKEY` / `CERT_ALIAS` / `STATE_DIR` / `DELETE_OLD_CERT` / `TCB_BIN` / `NODE_BIN`）
> 见脚本头注释。旧写法 `Ali_Key` / `Ali_Secret` / `TCB_SECRET_ID` / `TCB_SECRET_KEY` 仍然兼容。

> ⚠️ 不要用腾讯云主账号密钥：它默认可操作账号下全部资源。
> 也不要用 CloudBase 的「环境级 API Key」——它没有追加 CAM 策略的通道，传证书会失败。

## 用法

```bash
export CERT_DOMAIN=your.domain
export ALIYUN_SECRET_ID_DNS=... ALIYUN_SECRET_KEY_DNS=...
export CLOUDBASE_SECRET_ID=...  CLOUDBASE_SECRET_KEY=...
export CLOUDBASE_ENV_ID=env-xxxxxxxx

bash scripts/manual/cert.sh issue    # 首次：签发 + 挂钩子（会立刻跑一次 deploy）
bash scripts/manual/cert.sh deploy   # 之后任何时候都可手工重跑（幂等）
bash scripts/manual/cert.sh renew    # 演练：强制续期一次，看钩子会不会被触发
bash scripts/manual/cert.sh          # 无参数 / -h：打印用法与所需环境变量，退出码非 0
```

`issue` 结尾会打印后续要手工做的事（首次绑定域名、加 CNAME、演练续期）。

## 前提与限制

- 域名**必须已完成 ICP 备案**：CloudBase 绑定自定义域名要求备案，这是行政前置
- 该域名**必须已经在 CloudBase 里绑定过**。脚本只负责**换证书后重绑**，不负责首次绑定
  （首次请用 `tcb domains add`，并要求先做域名归属校验）
- **证书换新后必须重绑**：CloudBase 存的是证书 ID 指针，换了新证书 ID 不变就没生效 ——
  这正是 `deploy` 存在的理由
- 建议定期演练一次 `bash scripts/manual/cert.sh renew`，别等 60 天后才发现钩子坏了
- 钩子是 acme.sh 的子进程，只继承 acme.sh 自己的环境。手工跑 `issue` / `renew` 没问题；
  但 cron 里直接跑 `acme.sh --cron` 时，只有 cron 环境里**存在**的变量才看得到 ——
  请把这几个 `export` 写进 cron 的环境（或自备 wrapper），否则续期会成功、同步会失败

## 验证边界

脚本做过 `bash -n`、`shellcheck -S warning`（零告警），以及**用假 `tcb` + 假 `acme.sh` 的
70 项端到端演练**：

- 首次 `deploy`：上传 → 解析证书 ID → 重绑 → 回读校验
- 第二次 `deploy`：命中幂等（证书库里不新增证书、不重复重绑）
- 云端绑的是旧证书时：重新上传后重绑并使用回读校验
- `issue`：`--reloadcmd` 指向同一个脚本的 `deploy`，且 `--install-cert` 会立刻执行它
- `renew`：确实会重放钩子
- 证书与私钥不匹配：非 0 退出并给出可操作提示
- 无参数 / `-h` / 未知子命令 / 缺 `CERT_DOMAIN`：用法与退出码

**未对真实的腾讯云 / 阿里云 / Let's Encrypt 接口发起过请求** ——
首次真实执行请当作首次验证（尤其是 `UploadCertificate` 在命中同指纹证书时
返回 `CertificateId` 还是只返回 `RepeatCertId`，脚本两种都兼容，但只在假 `tcb` 上验证过）。
