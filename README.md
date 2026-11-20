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

### 4.0 先判断你属于哪种情况

两种情况的操作**完全相反**：全新安装要跑菜单【1】，升级更新绝不能跑【1】。先确认：

```bash
nft list table ip port_forward 2>/dev/null | grep -c 'dnat to'
```

| 输出 | 情况 | 去往 |
|---|---|---|
| `0` 或报错（表不存在） | 全新机器，还没有任何转发 | [4.1 全新安装](#41-全新安装) |
| 大于 `0` | 机器上已有转发在跑 | [4.2 升级更新](#42-升级更新已装-v10v11-的机器) |

拿不准时，先跑仓库里的只读体检脚本（不写任何文件、不动规则）：

```bash
curl -fsSL https://raw.githubusercontent.com/yinet/nft-forward-remark/main/audit-readonly.sh | sudo bash
```

若 raw 域名不通（境内机器常见），走 API 通道：

```bash
curl -fsSL -H "Accept: application/vnd.github.raw" \
  "https://api.github.com/repos/yinet/nft-forward-remark/contents/audit-readonly.sh?ref=main" | sudo bash
```

体检会输出十节信息，其中 §4 是内核实际规则、§7 是"重写会丢失的行"、§9 是机器上旧脚本的版本，据此可确定该走哪条路。

### 4.1 全新安装

拉脚本：

```bash
curl -L https://raw.githubusercontent.com/yinet/nft-forward-remark/main/nft.sh -o nft.sh
chmod +x nft.sh
sudo ./nft.sh
```

**第一步选【1 安装 nftables】**。脚本按机器现状分两条分支：

| 场景 | 动作 |
|---|---|
| 已有 nftables（多数云镜像） | 把 `/etc/nftables.conf` 与 `/etc/nftables.d/*.conf` 改名成 `.bak.时间戳` → `nft flush ruleset` → 开 IP 转发与 BBR/fq → 建空配置 → `nft -f` 验证 → 启用服务 |
| 没有 nftables | 按发行版 `apt/dnf/yum/pacman` 装包 → 同样开转发与 BBR → 建配置 → 启用服务 |

**第二步选【3 新增端口转发】**，依次填写本机监听端口、目标 IP、目标端口（回车默认同端口）、备注（可留空）。

**第三步选【2 查看现有端口转发】** 核对规则与备注。

装完先验证四项：

```bash
nft list table ip port_forward              # 应见 prerouting / postrouting 两条链
sysctl -n net.ipv4.ip_forward               # 应为 1
sysctl -n net.ipv4.tcp_congestion_control   # 应为 bbr
systemctl is-enabled nftables               # 应为 enabled
```

三个必须知道的限制：

- **默认封禁端口**：该产品的 `80`、`443`、`8080`、`8443`、`8000`、`1080` 属默认封禁端口，转发到这些端口不会通。监听端口请避开。
- **`flush ruleset` 的连带影响**：它清的是整个 nftables 规则集，不只是本脚本的表。若机器上还有别的东西依赖 nftables，会一起没了。非"刚重装"的机器先 `nft list tables` 看一眼。
- **时间同步**：本脚本不校准时间，但协议握手对时间敏感。`timedatectl status | grep synchronized` 确认已同步。

另有一个 UX 细节：在"已装 nftables"分支若对"是否继续"回答 `n`，脚本执行 `exit 0` 直接退出整个程序（不是返回菜单），需要重新运行。

### 4.2 升级更新（已装 v1.0/v1.1 的机器）

#### 原理：换脚本不动规则

转发规则活在**内核 nftables 里**，备注活在 `/etc/nftables.d/port-forward.conf` 里，脚本只是一层读写这两个东西的外壳。所以替换脚本文件本身不会中断任何转发，也不需要重载规则。

#### 第 1 步：备份

```bash
cp /etc/nftables.d/port-forward.conf /root/port-forward.conf.v1.1.bak
nft list table ip port_forward > /root/nft-port_forward.v1.1.bak
```

第二行备份的是"内核里实际生效的规则"，是配置文件和实际状态不一致时唯一可靠的对照物。

#### 第 2 步：绝不要选【1 安装 nftables】

`do_install()` 会把 `/etc/nftables.conf` 与 `/etc/nftables.d/*.conf` 全部改名成 `.bak.时间戳`，然后 `nft flush ruleset` 清空内核规则，再由 `init_conf()` 生成一份**空规则**配置。后果是所有转发从内核和配置里同时消失。

升级只需要替换脚本文件，不跑安装。

#### 第 3 步：替换脚本

```bash
ls -l ./nft.sh /root/nft.sh /usr/local/bin/nft.sh /usr/local/bin/nftf 2>/dev/null   # 定位旧脚本

cd /root
curl -fsSL https://raw.githubusercontent.com/yinet/nft-forward-remark/main/nft.sh -o nft.sh.new
grep -m1 -o '管理工具 v[0-9.]*' nft.sh.new     # 应输出 v1.2
grep -c sanitize_note nft.sh.new               # 应大于 0

mv nft.sh nft.sh.v1.1 && mv nft.sh.new nft.sh && chmod +x nft.sh   # 旧文件留作回滚
```

#### 第 4 步：确认接管

```bash
sudo ./nft.sh    # 菜单标题应为 v1.2，共 8 项
# 选【2 查看现有端口转发】
```

预期：旧规则全部列出，备注列为 `-`。此时内核规则一条没动，可以放心继续。

#### 第 5 步：补备注

有一条前置检查必须先做——重写配置时脚本会用 `get_local_ip()` 重新推导 `define LOCAL_IP`（取 `ip route get 1.1.1.1` 的源地址），它决定转发流量的回程源地址（SNAT）。若推导结果与当前不同，回程可能中断：

```bash
ip route get 1.1.1.1 | grep -oP 'src \K[0-9.]+'
grep 'define LOCAL_IP' /etc/nftables.d/port-forward.conf
```

两行一致才继续。注意云厂商机器（腾讯云等）网卡上是私网地址、公网由 EIP 映射，因此这里出现 `10.x` 是正常的。

**方式 A：逐条，适合规则少（≤ 10 条）**

选【5 修改备注】→ 输入序号 → 输入备注。每条会触发一次 `flush + nft -f`，规则表在毫秒级窗口内不存在（已建立的连接由 conntrack 维持，正在传输的流量不受影响，但**新连接**可能在该瞬间未被 DNAT）。

**方式 B：批量，适合规则多，且只 reload 一次**

准备好端口与备注的对照表（Tab 分隔）：

```bash
cat > /root/notes.tsv <<'EOF'
30001	香港落地A
30002	日本中转
30003	日本落地 备用
EOF
```

按端口把 `# @note:` 标记写进配置：

```bash
cp /etc/nftables.d/port-forward.conf /root/pf.before-notes.bak
python3 - <<'PY'
import io, re
conf = '/etc/nftables.d/port-forward.conf'
notes = {}
for ln in io.open('/root/notes.tsv', encoding='utf-8'):
    ln = ln.rstrip('\n')
    if not ln.strip() or ln.lstrip().startswith('#'):
        continue
    port, _, note = ln.partition('\t')
    notes[port.strip()] = note.strip()

pat = re.compile(r'tcp dport (\d+) dnat to (\d+\.\d+\.\d+\.\d+):(\d+)')
out = []
for ln in io.open(conf, encoding='utf-8'):
    raw = ln.rstrip('\n')
    m = pat.search(raw)
    if m and '@note:' not in raw and m.group(1) in notes:
        raw += '    # @note: ' + notes[m.group(1)]
    out.append(raw + '\n')
io.open(conf, 'w', encoding='utf-8').write(''.join(out))
print('已处理端口数:', len(notes))
PY
```

然后 reload 一次（等价于脚本内部的 `reload_rules`）：

```bash
nft flush table ip port_forward
nft delete table ip port_forward
nft -f /etc/nftables.d/port-forward.conf
```

该脚本只标注 `tcp` 行（`load_rules` 只读 tcp 行），判断条件里带 `@note:` 已存在则跳过，因此重复执行是幂等的。下一次任何写操作时，`write_conf_file` 会把 udp 行与 `# 备注:` 行一并补齐。

#### 第 6 步：验证

```bash
# 内核里实际 DNAT 条数（每条转发对应 tcp+udp 各一行，故应为规则数×2）
nft list table ip port_forward | grep -c 'dnat to'
# 脚本视角的规则与备注
sudo ./nft.sh   # 选【2 查看现有端口转发】
```

两者数量对得上、备注列正确，即迁移完成。此后新增转发会在录入时直接问备注，配置重写时备注自动保留。

#### 回滚

```bash
cp /root/port-forward.conf.v1.1.bak /etc/nftables.d/port-forward.conf
nft flush table ip port_forward
nft delete table ip port_forward
nft -f /etc/nftables.d/port-forward.conf
mv /root/nft.sh.v1.1 /root/nft.sh
```

旧版脚本读到 `# @note:` 行尾注释不会有任何问题（它按 `tcp dport ... dnat to ...` 正则解析，行尾注释被忽略），所以回滚后规则完好，只是不再显示备注。

#### 注意事项

- **手工改过 `port-forward.conf` 的机器要格外小心**：`load_rules()` 只认 `tcp dport N dnat to IP:P` 这一种模式，脚本自动生成格式之外的手写规则（如端口段、`ip saddr` 限定、独立 chain），在脚本第一次重写配置时会**不进入 `RULES` 数组从而丢失**。升级前先对比：

  ```bash
  nft list table ip port_forward | grep -E 'dnat to|snat to'
  grep -E 'dnat to' /etc/nftables.d/port-forward.conf
  ```

  两边不一致就先把手写规则摘出来，迁移完再单独维护。只读体检脚本的 §7 会自动列出这类行。
- **多层拓扑逐台升级**：Po0、RFC 中转机各自独立运行脚本，互不影响。建议先升级不承载主链路的那台验证。
- **备注不跨机同步**：备注只存在本机配置文件里，换机时连同 `port-forward.conf` 一起拷走即可带过去。

## 五、兼容性

- 旧配置文件（无 `@note`）可直接读取，备注显示为 `-`，不会报错、不会丢规则。
- 未使用内核级 `comment "..."`，因此不依赖内核版本；代价是 `nft list ruleset` 中看不到备注（只有 `cat port-forward.conf` 或脚本内【查看】可见）。若需要 `nft list` 也显示备注，把规则行改为 `... dnat to IP:PORT comment "note:xxx"`（需内核 4.10+，comment 长度上限 128 字节）。

## 六、测试

仓库内改动经本地 17 项用例验证（写入/回读往返一致、旧配置兼容、删中间项重排、备注净化、共享目标判定等），全部通过。`audit-readonly.sh` 另经模拟环境验证（伪造 `nft` 输出与含手写规则的样例配置）。

## 授权

沿用上游脚本的分享方式。原始脚本出自 NodeSeek 社区，本仓库仅追加备注能力。
