# nftables 端口转发管理工具（带备注版）v1.2

在社区脚本 [Po0 / NodeSeek 版 nftables 转发管理脚本](https://wiki.uuuz.de/guide/tutorials/nftables-script.html) v1.1 基础上，为**每条转发规则增加备注（备注名）**能力的修改版。

DNAT / SNAT 逻辑、防火墙放行、BBR/fq、诊断等原有能力均未改动。

## 一、为什么要改脚本，而不是手改配置

原版脚本把规则存在 `/etc/nftables.d/port-forward.conf`，但**每次增删规则都会整份重写该文件**：`write_conf_file()` 依据内存数组 `RULES` 重新生成全文。

因此手工在 conf 里加一行注释，下一次操作就会被覆盖丢失。备注必须进入 `RULES` 数据模型，并让 `load_rules()` 能反向解析回来。

## 二、实现方式

| 项目 | v1.1 | v1.2 |
|---|---|---|
| `RULES` 元素格式 | `端口\|目标IP\|目标端口` | `端口\|目标IP\|目标端口\|备注` |
| 备注落盘形式 | — | 行尾 `# @note: xxx` + 上方 `# 备注: xxx` |
| 备注回读 | — | `load_rules` 用 `@note:` 正则抓取 |
| 是否需要内核支持 | — | 不需要，纯文件注释，对规则集零影响 |

生成的配置片段示例：

```
        # 转发: 本机:30001 -> 203.0.113.10:30001
        # 备注: 香港落地A
        tcp dport 30001 dnat to 203.0.113.10:30001    # @note: 香港落地A
        udp dport 30001 dnat to 203.0.113.10:30001    # @note: 香港落地A
```

nft 词法约定明确："A hash sign (#) begins a comment. All following characters on the same line are ignored."（注释可位于语句之后，至行尾结束），所以行尾注释不会影响 `nft -f` 加载。

## 三、改动清单

1. **`sanitize_note()`（新增）**：备注净化。剔除 `|`（会破坏数组分隔）、换行、CR、反引号、`$`、反斜杠、双引号，去首尾空白，限长 60 字符。原版 `write_conf_file` 用未加引号的 heredoc，备注若含 `$` 或反引号会被二次解释，这里提前剔除。
2. **`load_rules()`**：解析行尾 `# @note:`，组成四字段。
3. **`write_conf_file()`**：改用 `printf` 写出规则行（避免 heredoc 二次展开），备注为空时不写 `@note` 标记。
4. **`do_add()`**：目标端口之后新增"备注（可留空）"输入，确认提示与日志同步带备注。
5. **`do_note()`（新增，菜单 5）**：按序号修改/清空备注，不动端口与 IP，不重建防火墙放行，风险最低。
6. **`do_list()` / `do_delete()`**：增加备注列。**备注置于行尾**——`printf "%-10s"` 按字符数补齐，中文属双宽字符，放中间会导致整列错位。
7. **全量四字段读取**：原版 `IFS='|' read -r lport dip dport` 在三字段数据下正确，但在四字段下 `dport` 会把 `|备注` 一并吞入（`read` 的最后一个变量吸收剩余全部内容），必须改为 `read -r lport dip dport _` 或四变量。涉及 `dest_still_used`、`write_conf_file`、`do_diagnose`、`do_list`、`do_delete`、`do_clear_all`。
8. **菜单重排**：`1 安装 / 2 查看 / 3 新增 / 4 删除 / 5 修改备注 / 6 清空 / 7 诊断 / 8 退出`。

## 四、安装

```bash
curl -L https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/nft.sh -o nft.sh
chmod +x nft.sh
sudo ./nft.sh
```

已装原版 v1.1 的机器**不需要重跑【安装 nftables】**（那会 `flush ruleset` 并备份走旧配置）。直接替换脚本文件后运行，用【查看】确认旧规则仍在，再用【修改备注】逐条补备注；备注在下次重写配置时落盘。

## 五、升级与回滚

- 首次运行前建议手工备份：`cp /etc/nftables.d/port-forward.conf /root/pf.conf.bak`
- 脚本自身在每次写配置前会调用 `backup_conf`，备份落在 `/etc/nftables.d/backups/`
- 回滚：用旧版脚本 + 备份文件覆盖 `port-forward.conf`，再 `nft -f /etc/nftables.d/port-forward.conf`

## 六、兼容性

- 旧配置文件（无 `@note`）可直接读取，备注显示为 `-`，不会报错、不会丢规则。
- 未使用内核级 `comment "..."`，因此不依赖内核版本；代价是 `nft list ruleset` 中看不到备注（只有 `cat port-forward.conf` 或脚本内【查看】可见）。若需要 `nft list` 也显示备注，把规则行改为 `... dnat to IP:PORT comment "note:xxx"`（需内核 4.10+，comment 长度上限 128 字节）。

## 七、测试

仓库内改动经本地 17 项用例验证（写入/回读往返一致、旧配置兼容、删中间项重排、备注净化、共享目标判定等），全部通过。

## 授权

沿用上游脚本的分享方式。原始脚本出自 NodeSeek 社区，本仓库仅追加备注能力。
