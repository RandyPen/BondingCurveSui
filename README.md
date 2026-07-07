# BondingCurveSui

PumpFun 式代币发射平台（Sui Move），参考 moonbags-contracts-sui 重写并优化。

## 核心特性

- **常数乘积虚拟储备曲线**：原生 u256/u128 数学，所有舍入偏向协议，每次交易断言不变量。
- **quote coin 白名单**：管理员维护（`add_quote<Quote>` / `set_quote_enabled`），每种 quote 独立配置毕业阈值、创建费、最小买入额。`Pool<Base, Quote>` 双泛型。
- **唯一毕业路径**：曲线打干后由任何人触发 `migrate`，全部流动性以 **full range** 进入 Cetus CLMM（`full_range_tick_range`），coin A/B 按类型名 ASCII 序在运行时分支。
- **抢先建池防护（重要）**：发币时趁 TreasuryCap 还在手中（供应为零、无人持有 base 币）向 Cetus 铸 `PoolCreationCap` 并 `register_permission_pair`，迁移走 `create_pool_v3_with_creation_cap`。否则攻击者可用尘埃资金抢先创建同一 `(Base, Quote, tick_spacing)` 池，使迁移永久 `EPoolAlreadyExist`、募集资金卡死（安全评审发现的关键漏洞，已修复并有回归测试）。**运营前提**：白名单中的 quote 必须在 Cetus 的 `allowed_pair_config` 中允许对应 tick_spacing（主网默认 SUI@200；其他 quote 需 Cetus pool manager 执行 `add_allowed_pair_config`），否则 `create_token` 在发射时即中止。
- **应急兜底**：若已完成的池因 Cetus 侧配置变化确实无法迁移，管理员可在完成后 **7 天宽限期**后 `emergency_withdraw`（资金入国库、池进入终态 HALTED、事件留痕）；HALTED 后所有 tranche 可无许可释放给创建者（TVL 条件已永久不可达）。宽限期内任何人仍可正常执行 `migrate`。
- **LP Burn**：迁移后 Position 经 Cetus 官方 `lp_burn::burn_lp_v2` 销毁，`CetusLPBurnProof` 由协议（pool 对象）持有；任何人可触发 `claim_lp_fees`——quote 侧按可配置 bps 分给平台/创建者，**base 侧一律销毁**。
- **Currency (BurnOnly)**：发币时铸完固定供应（默认 8M 曲线 + 2M LP，6 位小数）后：元数据 cap 领取并删除（永久冻结）、`make_supply_burn_only` 消耗 TreasuryCap。之后任何人可凭共享 `Currency<T>` 销毁 base coin，总供应链上可查。
- **创建者首购 tranche**：发币时可分多笔（≤16）首购，每笔独立选择解锁条件：
  - 时间锁（`unlock_tranche_time`，任意相位可解）；
  - 迁移后 CLMM 池 TVL 达标（`unlock_tranche_tvl{,_inverted}`，**private entry** + 直接转给创建者，阻断同 PTB「拉价→解锁→卖出」原子操纵）。
- **每池独立共享对象**：不同代币的交易互不争用；全局 `LaunchpadConfig` 仅存 `Base 类型 → pool ID` 注册表（防重复发射）。
- **AdminCap 仅 `key`**：不可被 `public_transfer`/包装，只能通过 `transfer_admin` 转移。

## 生命周期（3 笔交易发币）

1. **tx1**：创建者发布代币包（标准 OTW `coin::create_currency`，decimals 必须等于配置的 `base_decimals`），持有零供应 `TreasuryCap` + `CoinMetadata`。
2. **tx2**：`sui::coin_registry::migrate_legacy_metadata`（无许可）在 `0xc` registry 创建共享 `Currency<Base>`。（同一交易中无法立刻 `&mut` 使用，故与 tx3 分离。）
3. **tx3**：`pool::create_token<Base, Quote>`（或 `create_token_entry`，需传入 Cetus `GlobalConfig` + `Pools`）——校验、铸币、**预定 Cetus 池位（permission pair）**、冻结元数据、供应转 BurnOnly、推导虚拟储备、执行首购 tranche、共享 Pool。

之后：`buy`/`sell`（exact-in + min-out）→ 曲线打干自动置 `COMPLETED` → 任何人 `migration::migrate`（传入 Cetus GlobalConfig/Pools + lp_burn BurnManager）→ `MIGRATED`；随后 `claim_lp_fees` / TVL 解锁生效。

## 曲线参数

对 `I`（曲线实币）、`R`（LP 保留）、阈值 `T`（quote 单位）：
`vb0 = I²/(I−R)`，`floor = vb0 − I`，`vq0 = ⌈T·R/(I−R)⌉`。
打干时恰好卖出 `I`、募集 ≈`T`，曲线末价 = `T/R` = CLMM 初始价（无迁移价差，有单测验证）。

## 构建与测试

```bash
sui move build
sui move test   # 71 tests
```

依赖说明见 `Move.toml` 注释：CetusClmm 直接钉在 MVR mainnet 解析出的同一坐标（cetus-contracts @ clmm-v14，真源码，单测可真实建池）；lp_burn 接口本地 vendor（`vendor/lp_burn`，剔除引发 MVR testnet 解析失败的 clmm_vester 传递依赖）。

## 部署清单（testnet/mainnet 前必读）

1. **published-at 刷新**：
   - `mvr resolve @cetuspackages/clmm --network mainnet` → 最新 CLMM 包地址（2026-07-07 为 v14 `0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3`）。CetusClmm git 依赖无 published-at，主网发布前需以此地址配置（Move.lock env 固定或临时改用 `r.mvr` 依赖 + mainnet 环境）。
   - `mvr resolve @cetuspackages/lpburn --network mainnet` → lp_burn 最新地址（2026-07-07 为 v7 `0xa5d8457e049c8f2a04b7b47e925b200f457e57016aa158f050a931c8ead99fe0`，已写入 `vendor/lp_burn/Move.toml`）。
2. **testnet 限制**：Cetus 在 MVR 的 testnet 元数据缺失（clmm 无 git_info，lpburn 无映射）。lp_burn 在 testnet 的可用性需向 Cetus 文档确认；若不可用，`migrate` 的 burn 步骤只能在主网验证（本地单测已用真实 CLMM 源码覆盖建池部分）。
3. **上线后首要动作**：`add_quote<SUI>` / `add_quote<USDC>` 等白名单；确认 Cetus `GlobalConfig` 中 `tick_spacing=200` fee tier 存在（主网默认 1%）；**逐一确认每个白名单 quote 已在 Cetus `allowed_pair_config` 允许该 tick_spacing**（SUI@200 主网默认已有，其余需联系 Cetus）。
4. **实链冒烟**：发一个测试币走完 3 笔交易 → 小额买卖 → 打干 → `migrate`（核对 Cetus 池价格与 burn proof）→ `claim_lp_fees` 回路 → `coin_registry::burn` 减供应。
5. **版本升级**：合约升级后调用 `bump_config_version`，并按需对存量池 `bump_pool_version`。

## 已知取舍

- TVL 解锁的跨交易价格操纵未做两段式确认（v1 接受：受益人只能是创建者，成本为 2×池费+滑点+被套利风险；事件记录当时 sqrt price 与余额供审计）。如需加固，v1.1 可加 poke→N 小时后确认的两段式解锁。
- 手续费分润规则待定 → 全部为 admin 可配置 bps（曲线费率 ≤10% 硬顶；平台/创建者分成快照进池）。
