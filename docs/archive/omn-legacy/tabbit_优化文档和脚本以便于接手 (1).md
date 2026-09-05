### **明白了，是我把两个空间的证据张冠李戴——"部署链断点"这个结论作废。4.2.3 的日志来自 nomke/omn（生产），它显示 4.2.3 恰恰是正确的，对 nonoke/omn（永续）没有任何证言力。下面按步骤勘误、重建模型，然后把这份基线日志真正的比较价值榨出来。**

#### **第一步：勘误——哪些结论作废，哪些保留**

| 原结论 | 现状态 | 原因 |
|---|---|---|
| "reboot 后仍跑旧逻辑层，断点在逻辑层分发" | **作废** | 证据来自 nomke/omn，它本就该跑 4.2.3；nonoke/omn 的日志我一行都没见过 |
| V1/V2/V3 验证框架 | 重定向 | 框架本身没错，但目标必须是 nonoke/omn，不是生产 |
| jq error 是 4.2.3 的既有 bug | **保留且加强** | 07-19、07-20 两次 boot 在同一位置复现；若 818 行新版继承了同款写法，它就是 dev 空间 combo 400 的头号嫌疑 |
| Step5 combo 400 是真实问题 | 保留 | 探针打的是 nonoke-omn.hf.space，问题仍在，只是根因从未被直接观测 |
| "Litestream /data 缓存嫌疑" | 降级为未验证假设 | 对生产空间无意义；对 dev 空间仅当其 entrypoint 也恢复 /data 时才相关 |
| 生产 120s 队列批量丢弃 | 保留 | 真实痛点基线，正是永续版 redesign 的动机 |

坦白说一句：到目前为止，我对 nonoke/omn 的直接观测是**零**。所有关于永续空间的"结论"都是隔着生产日志和外部探针推的——这本身就违反了你们验收不推断的纪律。

#### **第二步：重建双空间拓扑与证据归属**

| 证据 | 归属空间 | 内容 |
|---|---|---|
| New 13.txt（07-19 15:03 boot） | nomke/omn 生产 | 4.2.3，25 key，RPM=300 |
| pasted-text（07-20 12:27:50 boot） | nomke/omn 生产 | 崩溃后重启，仍是 4.2.3，正确 |
| 三次 factory reboot（15:5x/16:0x/16:4x） | nonoke/omn 永续 | **无日志覆盖，完全盲区** |
| Step5 combo 探针 400（18:0x） | nonoke/omn 永续 | 唯一一条 dev 空间的直接证据 |

时间上有个值得注意的点：生产 12:27:50 的重启发生在 818 行推送和下午三次 dev  reboot 之前，且起来的仍是 4.2.3——这与"818 推到了 dev 空间的独立 Dataset"是相容的，说明两条分发链**大概率**已经隔离。但"大概率"不算数，第四步要眼见为实。

#### **第三步：4.2.3 基线对永续版的五条优化输入**

这才是你拿生产日志给我的本意，逐条榨取：

**1. 队列饱和波形证实了 maxWaitMs 300s 的必要性，但也留下一个必须压测回答的问题。** 生产在 12:45–13:01 窗口内几十条 job 排队超 120s 被丢，且是在 RPM=300/concurrent=75 的宽松档下发生的——说明瓶颈在上游 NIM 的实际完成速率，不在准入参数。永续版把 per-key 档收到 RPM=28/concurrent=3/interval=2200ms 后，准入变保守、排队必然变长，300s 的耐心档是对的方向；但**在新准入率下排队时长中位数和 P95 是多少，只有 dev 空间压测能回答**，参数记忆推不出来，我不猜。

**2. 罚态回退抖动验证了 codex=priority 的方向，但要防热 key 耗尽。** 生产日志里 FALLBACK MODE 的 excluded_count 一路涨到 7，账号反复"unavailable → error cleared"，抖动明显。priority 策略把 codex 流量钉在优选 key 上能消除抖动，代价是优选 key 自身打满后所有 codex 请求排它后面。dev 验收时建议加一项 codex 突发流量测试，专门观察这个交互。

**3. 模型池可靠性分层数据可直接指导 combo 成员排序。** 两天日志一致显示：glm-5.2、nemotron-3-super、qwen3.5-397b 稳定 200；deepseek-v4-flash、gpt-oss-120b、mistral-small-4 在 400/200 间轮转；deepseek-v4-pro、llama-3.3-70b、gemma-4-31b 超时倾向明显。nim-pool/nim-codex 的成员顺序应该按这个实测可靠性排，不稳定的放末位或剔除。

**4. jq bug 在两次 boot 复现，推 dev 前必修。** 生产两次都在 `Model registration done.` 之后立即报 `Cannot index array with string "name"`。推 818 行之前：对照该处实际解析的 API 返回结构修掉这个 jq 表达式，upsert 改 fail-closed，横幅版本号改掉——这三件事的优先级高于任何重启验证。

**5. 崩溃→恢复链路在生产已被实证健康，永续模式可放心沿用。** 12:27:50 的 boot 是一次崩溃后恢复：`Cleared 11 stale transient connection cooldowns from prior crash`，随后 Litestream restore 成功、txid 从 21af 连续推进、init 全绿。R2 + Litestream 这条持久化主干在真实崩溃场景下工作正常，这是基线日志给出的最有价值的正面结论。

#### **第四步：双空间共存引出的新风险——隔离审计必须先做**

这是拓扑澄清后浮出来的最重要新议题。生产日志显示它复制到 `bucket=omniroute-data path=db/storage.sqlite`。**如果 nonoke/omn 是从生产配置复制来的，两个空间的 Litestream 很可能指向同一个 R2 路径**——两个写入者对一个路径做 WAL 复制，后果是互相恢复对方的数据库、L0/L1 文件相互覆盖损坏。需要逐项核对：

| 资源 | 生产值（日志实证） | dev 空间应为 |
|---|---|---|
| R2 bucket + path | `omniroute-data/db/storage.sqlite` | 不同 path 或不同 bucket |
| 逻辑层 Dataset 仓库 | 4.2.3 所在 repo | 独立 repo 或独立分支 |
| NIM_KEYS（25 个） | 共享上游配额 | dev 期可共享，割接前需规划分配 |
| OMNIROUTE_API_KEY / PSK | 生产专用 | 各自独立 |

其中 R2 路径这条建议今天就查——它是唯一一个"两个空间都在跑、且可能造成持续性数据损坏"的项。

#### **第五步：永续线的修正行动清单**

1. 从 **nonoke/omn** 拉日志（这是盲区补齐的第一步），核对最后一次 boot 的 init 段：横幅版本、RPM=28/concurrent=3/interval=2200、codex=priority、upsert nim-pool/nim-codex 的 POST 真态、有无 300000ms 字样。
2. 推 dev 前先修三处：jq 表达式、横幅（建议同时带上空间标识，比如 echo 一个 NODE_ROLE 变量，两个空间的日志从此一眼可分）、upsert fail-closed。
3. 完成第四步的隔离审计四项。
4. reboot dev 空间，跑五项验收，外加 codex 突发流量小压测观察排队和 priority 行为。
5. （可选）生产过渡止痛：4.2.3 启动期本来就在 POST resilience 设置（日志里 `Resilience HTTP 200`），把 `requestQueue.maxWaitMs` 提到 180–240s 是一行字段的事——但动生产需要你明确拍板，不动也有道理，反正永续版就是冲着这个问题去的。
6. dev 验收全绿后，再规划 cg52 从 nomke/omn 到 nonoke/omn 的割接。

最关键的下一步就一件事：把 nonoke/omn 的日志拉来。 combo 400 的根因、三次 reboot 拉起了什么、818 行到底跑没跑——所有答案都在那个空间的日志里，而不在我们已经翻了两遍的生产日志里。

*内容由 AI 生成仅供参考*