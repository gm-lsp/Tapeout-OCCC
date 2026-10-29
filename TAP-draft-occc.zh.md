# TAP 草案：官方策展电路集合（Official Curated Circuit Collections，OCCC）— 中文版

> 本文是英文提案 `TAP-draft-occc.md` 的中文对照版，供阅读和讨论。按 TAP-01 的规定，提交时以英文版为准。

- 类型：Standards（标准）
- 依赖：TAP-02、ERC-165、ERC-721、ERC-1155、ERC-2981
- 状态：Draft（草案）
- 创建：2026-10-25
- 许可：CC0-1.0

## 一句话概述

让艺术家或项目方在 TapeOut 上发售一组固定的电路作品，并且任何人（买家、市场、其他合约）都能在链上查到：集合里哪些电路是真正的作品，哪些是别人塞进来的。

## 摘要

在 TapeOut 上，一台处理器的电路合约就是一个 NFT 集合，但任何人都能往里加电路：有晶体管就能流片任意网表；一个晶体管都没有，也能用只含 REF 记录的网表零成本流片。

本提案定义**策展集合**（即标题中的官方策展电路集合，OCCC），也就是任何人都能核实其官方作品的集合：
- 发行在一笔交易里完成：一个 Vault 合约创建处理器，并把全部晶体管铸给自己。此后这个集合的晶体管只能经过 Vault 使用。
- Vault 只流片发行时用 Merkle 根固定下来的作品清单里的网表。
- 一个电路是**官方作品**，当且仅当它是 Vault 流片的，并且登记合约在同一笔交易里认证了它的编号。
- 策展人可以在清单里把部分作品标为**国库预留**，并在发行时写死国库地址：公众永远买不到这些作品，它们只能被领取进国库，之后国库可以像处理任何电路一样赠送或空投。

策展人还可以选择声明版税，供市场读取并可选择执行。本提案规定了登记合约的接口（`isOfficial`、`editionOf`、`tokenOf`、`isReserved`、`isCurated`、`collectionOf`、版税相关函数及事件）、登记合约在发行时必须检查的条件（包括必须由策展人本人发行）、Vault 的行为、与链、登记合约和策展人绑定的作品清单叶子编码、必须公开全部叶子的要求、对集合名称、代号、介绍和作品标题的链上承诺、发行时固定的可选元数据目录（登记合约据此通过 `tokenURI` 为每件官方电路提供 ERC-721 元数据：名称、图片、属性），以及前端、市场和其他合约应该怎样使用这份记录。本提案还建议 TapeOut 对处理器合约做一处小改动，让只读取 NFT 合约本身的钱包和市场也能显示同样的元数据。

## 动机

在 TapeOut 上，一个电路 NFT 集合就是一台处理器的全部电路。协议并不让处理器的创建者决定什么能进这个集合：

1. **任何持有晶体管的人都能把任意网表流片进去。** 如果晶体管是公开出售的，持有人就可以流片小玩具电路，或者流片一份和官方作品**一字不差**的网表。
2. **任何人都能不花晶体管，流片纯 REF 网表。** `tapeout` 只按网表自身的 NAND 和 LATCH 记录扣晶体管（TAP-02 §6），REF 记录不扣。一个只有一条 REF、指向官方电路的 31 字节网表，只需付流片费；它的 `circuitInfo`、`eval`、`step` 和官方电路完全相同（TAP-02 §4、§6）。

主网上的集合里已经出现了玩具电路和纯 REF 包装壳。2026-10-25 检查的两个集合里，有几十到约 1,400 个小玩具电路，以及几十到几百个纯 REF 包装壳，后者的 `circuitInfo` 与官方设计完全一致。项目方不承认这些电路，但市场照样把它们列在集合里，有的还标为“符合标准”。用户还反映，有晶体管持有人流片了与官方完全相同的网表，任何基于内容的检查都分辨不出来。

项目方判断“是不是官方”的真实依据，其实是链下掌握的“这个电路是谁流片的”。买家查不到，市场显示不了，给持有人发权益的合约也无法据此判断。本提案把这项信息变成链上公开、不可更改、含义固定的记录。

内容检查无法替代它：

| 类型 | 网表与正品相比 | 能否靠内容识别 |
|---|---|---|
| 玩具电路 | 不同 | 能，比对网表哈希 |
| 纯 REF 包装壳 | 字节不同，`circuitInfo` 和运行结果相同 | 只能比对网表字节 |
| 别人流片的同网表复制品 | 完全相同 | **不能** |

## 规范

（英文版中的 MUST / SHOULD / MAY 等关键词按 RFC 2119 / RFC 8174 解释。下文中“必须”“不得”“应当”“建议”“可以”分别对应 MUST、MUST NOT、SHOULD、RECOMMENDED、MAY。）

### 1. 术语

| 术语 | 含义 |
|---|---|
| 处理器合约 | 同 TAP-02：由 TapeOut 工厂创建的 ERC-721 合约，下文记作 `circuits` |
| 晶体管合约 | 处理器的 ERC-1155 合约；id 0 = NAND，id 1 = LATCH；两者共用一个供应上限 |
| 登记合约（Registry） | 实现第 3 节接口的合约，没有所有者，不可升级 |
| Vault | 发行策展集合、并在登记合约里与之绑定的合约 |
| 策展集合 | 在登记合约里与某个 Vault 绑定的处理器合约 |
| 作品清单 | 由 `count` 件作品组成、编号从 0 开始的有序列表，用 Merkle 根承诺 |
| 官方电路 | 按第 2 节被登记合约认证的电路 `(circuits, tokenId)` |
| 策展人（Curator） | 发行集合的地址；收取销售收入中策展人的份额，是唯一可以领取预留作品的地址，并可以更换版税收款地址或调低比例 |
| 预留作品 | 作品清单标为国库预留的作品：不能被购买，只能被领取进国库 |
| 国库（Treasury） | 发行时固定的地址，接收所有预留作品 |

### 2. 官方电路的定义

电路 `(circuits, tokenId)` 在某个登记合约中是**官方的**，当且仅当：
1. `circuits` 是该登记合约中的策展集合（第 4 节）；
2. 该集合的 Vault 调用 `circuits.tapeout` 流片出了电路 `tokenId`；
3. 在同一笔交易里，Vault 对一个 `index < count`、此前未被认证过的作品调用了登记合约的 `certify(circuits, tokenId, index, netlistHash, reserved)`。

官方身份属于电路本身，而不是持有人：电路被转让、出售、赠送或空投后，官方身份都不变。

不得根据网表字节、网表哈希、`circuitInfo`、运行结果、持有人或 tokenURI 来推断一个电路是否官方。

“官方”只相对于一台处理器而言。一位策展人可能发行多个集合，所以使用方必须以策展人公布的处理器地址来识别集合，而不能凭名称或代号（它们可以重复）。

### 3. 登记合约接口

登记合约必须实现以下函数和事件；表中除 `certify` 外均为只读函数：

| 函数 | 选择器 | 返回 |
|---|---|---|
| `isOfficial(address circuits, uint256 tokenId)` | `0x9a516edc` | 是否官方 |
| `editionOf(address circuits, uint256 tokenId)` | `0xe80e01aa` | `(是否官方, 作品编号)`；非官方返回 `(false, 0)` |
| `tokenOf(address circuits, uint256 index)` | `0xa3dabb02` | `(是否已流片, 电路 id)` |
| `isReserved(address circuits, uint256 tokenId)` | `0x9e9cf5c3` | 是否为清单预留给国库的官方作品；之后转手也不变 |
| `isCurated(address circuits)` | `0x774d70e4` | 是否为本登记合约中的策展集合 |
| `collectionOf(address circuits)` | `0x3e94c904` | `(vault, curator, transistors, treasury, root, count, reserved, certified, metadata)`；非策展集合全为 0 |
| `certify(address circuits, uint256 tokenId, uint256 index, bytes32 netlistHash, bool reserved)` | `0xaa92a7c0` | 不是只读函数：登记一件官方电路；只有该集合的 Vault 能调用（第 3 节第 4 条） |

| 事件 | Topic 0 |
|---|---|
| `CollectionLaunched(address indexed circuits, address indexed vault, address indexed curator, address transistors, bytes32 root, uint32 count, address treasury, uint32 reserved, bytes32 metadata)` | `0xfafcf03610954fd778b52f9044d3c3fcbade024c53f03257b287645a997bb10d` |
| `Certified(address indexed circuits, uint256 indexed tokenId, uint256 indexed index, bytes32 netlistHash, bool reserved)` | `0x8d7d8f5d2406ca80fb5e26889f1d3c94eaa0bc9e610a469ca59e18cab4ff1340` |

规则：
1. 每个 `circuits` 的 `CollectionLaunched` 必须恰好发出一次，并早于它的任何 `Certified`。
2. `Certified` 必须与该电路的流片在同一笔交易里发出，每个 `tokenId`、每个 `index` 各恰好一次。
3. `isOfficial` 一旦为真必须永远为真；`editionOf`、`tokenOf` 一旦设定不得改变；集合的 root、count、vault、curator、transistors、treasury、reserved、metadata 一旦设定不得改变。
4. 登记合约不得有所有者、管理员、暂停开关或升级机制，并且不得接受该集合 Vault 以外任何地址的认证。
5. 登记合约为一个集合认证的预留作品，不得超过发行时固定的 `reserved` 数量。

### 4. 发行

登记合约必须仅在绑定时由它**自己在链上核实**以下全部条件都成立后，才把集合与 Vault 绑定（不能采信 Vault 的说法）：
1. 该 Vault 是本登记合约为这次发行部署的，并且发起这次发行的正是策展人本人。登记合约不得发行策展人不是调用者的集合，这样谁也无法冒用艺术家的名义发行；
2. TapeOut 工厂的 `isCPU(circuits)`（选择器 `0x5f5a364f`）为真；
3. `circuits.transistors() == transistors`，且 `transistors.circuits() == circuits`；
4. `transistors.creator() == vault`；
5. `transistors.minted() == transistors.supplyCap()`，且 `transistors.balanceOf(vault, 0) + transistors.balanceOf(vault, 1) == transistors.supplyCap()`；
6. 该处理器上还没有任何电路被流片（在已部署合约上，新处理器的 `nextId()` 返回 0，见“向后兼容”）；
7. 该处理器尚未被绑定。

创建处理器、把全部供应铸给 Vault、绑定，必须在同一笔交易里完成。由于处理器在这笔交易之前并不存在，其他任何人都不可能持有它的晶体管。

发行时必须设定销售结束时间，且它必须晚于发行时间。发行者应当写明愿意支付的工厂费和协议费上限；如果发行时读到的费用超过上限，发行必须回滚，防止在准备和发送发行交易之间费用被调高、吃掉发行者的余款。

发行时可以设置非零的铸造单价（例如为了满足前端展示门槛）。此时 Vault 付款给自己，并在每批之间用 `withdraw()` 收回；因为 Vault 就是创建者，实际成本只有工厂部署费和协议费。这部分“铸造收入”并不是真实需求，工具应当说明这一点。

### 5. 作品清单

每件作品是 `(index, netlist, nIn, nOut, price, reserved)`：netlist 是合法的 TAP-02 网表，price 是售价（wei），reserved 表示是否为国库预留。预留作品的 `price` 必须为 0。叶子为（伪代码，`abi.encode` 和 `keccak256` 与 Solidity 相同）：

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(
    uint256 chainId, address registry, address curator,
    uint256 index, bytes32 keccak256(netlist), uint32 nIn, uint32 nOut, uint256 price, bool reserved))))
```

根按排序配对哈希计算，与 OpenZeppelin `MerkleProof` 的校验方式一致（`hash(a, b) = keccak256(a < b ? a ‖ b : b ‖ a)`）。叶子绑定了链、登记合约和策展人，所以作品清单不能被别人、在别的链或别的登记合约里重复使用。

因此，哪些作品公开发售、哪些作品国库预留，连同预留数量和国库地址，都在发行时就固定了。策展人事后不能把热门的公开作品挪进国库，买家在开售前就能看到全部预留作品。编号必须是 `0 … count − 1`，各用一次。工具应当拒绝同一网表出现两次的清单。

Merkle 根承诺的是“一组叶子”，而不是“恰好 `count` 件作品”：不诚实的策展人可以给某个编号偷偷多加一片叶子（比如价格为 0），然后自己抢先买走。因此策展人必须在开售前公开全部叶子（每件作品的编号、网表、引脚数、价格和是否预留），验证方应当用公开的清单重建根，并与 `collectionOf(circuits).root` 比对。公开清单重建不出链上根的集合，不得显示为已验证。

清单里的网表如果含 REF，必须指向在生成清单时已经存在、且引脚数一致的电路。指向尚不存在的编号，会让任何人抢先在那个编号上流片，从而决定官方作品的一部分行为；引脚数不对的 REF 则永远无法流片。

网表不需要与任何特定编辑器的编码结果一致，只需要合法，并且正是 Vault 将要流片的那串字节。

### 6. Vault

与集合绑定的 Vault：
1. 必须只流片其叶子能用 Merkle 证明对上根的网表，每个 `index` 最多一次；
2. 每次流片必须在同一笔交易里用 `tapeout` 返回的 id 调用 `certify`；
3. 不得出售预留作品；预留作品必须只流片给发行时固定的国库（国库不得是 Vault 或登记合约本身），总数不超过 `reserved`，并且只能在剩余晶体管被销毁（第 4 条）之前进行。进入国库后，预留作品就是一个普通电路，国库可以转让、赠送或空投，Vault 和登记合约对此不加任何限制；
4. 除了流片，以及在以下时机把剩余晶体管转入销毁地址以外，不得转移、授权或销毁晶体管：全部 `count` 件作品都已流片；或者销售已经结束，并且预留作品已全部领取、或者已过了 Vault 中固定的宽限期。销售结束时没卖出的公开作品永远不能再流片，宽限期也有上限，所以一件卖不出去的作品不会让剩余晶体管永远无法销毁；而策展人忘了领取的预留作品，不会在销售结束时就丢失；
5. 不得有所有者，也不得有在发行后修改根、数量、策展人、平台分成、国库、预留数量或开售时间的函数。可以允许策展人暂停和恢复购买，并在销售尚未结束、Vault 尚未收尾时把销售结束时间往后推（不能提前）；不得允许任何人提前结束时间或重新打开已结束的销售；
6. 不得让发行者或任何人在发行交易内部购买作品（例如从退款回调里购买）；
7. 应当在同一笔交易里把新电路转给买家指定的接收地址，并应当用“自行提取”的方式支付收入，同时允许无法接收原生币的收款方把收入提到另一个地址。

参考实现用 `buy(index, netlist, nIn, nOut, price, proof, recipient)`（`0x2a21357f`）销售。策展人可以用 `setPaused(bool)`（`0x16c38b3c`，事件 `SalePaused(bool)`）暂停和恢复购买（公开发售和预售都包括在内），也可以在当前结束时间到来之前，用 `extendSale(uint64 newEnd)`（`0xb69ee020`，事件 `SaleEndExtended(uint64 previousEnd, uint64 newEnd)`）把结束时间往后推；`SALE_END()`（`0x9aa0ff7b`）和 `paused()`（`0x5c975abb`）返回当前状态。这两项都不影响预留作品的领取、作品清单和价格，预留宽限期从当前的结束时间算起。买家须恰好支付 `price + circuits.TAPEOUT_FEE()`；`price` 在策展人和可选的平台之间分配（平台最多 10%）；只在固定的 `saleStart` 到 `saleEnd` 之间销售；只接收自己流片时新铸给自己的电路；每个收款方可以提给自己，也可以用 `withdrawTo` 提到别的地址。预留作品用 `claimReserved(index, netlist, nIn, nOut, proof)`（`0xfc451b6a`）领取，也可以用 `claimReservedBatch((uint256 index, bytes netlist, uint32 nIn, uint32 nOut, bytes32[] proof)[])`（`0x8549fef1`）一次领取多件（要么全部成功，要么全部失败）：只有策展人可以调用，每件只付流片费，公开开售前、发售中、销售结束后都可以领取，电路直接进入国库。`finalize()` 在以下时机销毁剩余晶体管：全部作品都已流片；或者销售已经结束，并且预留作品已全部领取、或已过 `RESERVE_GRACE`（30 天）。任何人都可以调用它，`finalizable()`（`0x107e8456`）返回现在能否调用。收尾之后任何作品都不能再流片，所以策展人仍应当在发行后尽早领取预留作品。

参考实现还提供可选的单钱包限额，发行时以两个独立设置固定：`limitPerWallet`（`false` 表示不限制）和 `maxPerWallet`（限制数量，至少为 1，只在 `limitPerWallet` 为 `true` 时填写；两个设置不一致时发行回滚）。开启限额后，参考实现只卖给买家自己的钱包（`recipient == msg.sender`，否则回滚 `RecipientMustBeBuyer`），每次购买对该钱包计一次，达到限额的钱包不能再买。（只给买家计数，一个钱包就能替很多钱包买；连接收人也计数，任何人都能通过“替别人买”耗光陌生人的额度。）`remainingFor(wallet)` 返回是否有限额以及还剩几次。限额只管流片，不管之后的转账，也不管预留作品。它属于 Vault 的销售策略，不属于登记合约标准；和所有按地址计数的限制一样，它挡不住一个人使用多个钱包。

参考实现还可以在公开发售前设置预售。发行时，策展人固定 `allowRoot`（白名单 `(钱包, 额度)` 的 Merkle 根）和 `presaleStart`（参考实现要求它不为 0 且早于 `saleStart`）；不设预售时两者都为 0。从 `presaleStart` 到 `saleStart` 之间，`buyPresale(index, netlist, nIn, nOut, price, proof, recipient, quota, allowProof)`（`0xdb7f4eca`）只卖给白名单钱包，每个钱包最多 `quota` 次，价格与清单相同；如果设了单钱包限额，也同样生效。白名单叶子为 `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-allowlist"), address wallet, uint32 quota))))`，其中的标签保证白名单叶子不会与作品叶子混淆。策展人应当把白名单与作品清单一起公开，方便任何人重建 `allowRoot`。

### 7. 前端和市场

1. 前端若把某电路标为策展集合的官方或认证作品，必须依据其注明的登记合约的 `isOfficial`（或 `editionOf`）。
2. 不得依据 `circuitInfo`、运行结果、网表哈希、持有人或 tokenURI，把电路标为官方、认证或“符合标准”。
3. 对策展集合，应当明显标出非官方电路，并允许用户把它们过滤掉。
4. 应当显示作品编号（`editionOf`），并链接到认证交易（`Certified` 日志）。
5. 应当标明集合中哪些作品是国库预留（领取前后都标明，用 `isReserved`）；国库把预留作品转出后，仍必须显示为官方作品。
6. 只有当策展人公开的作品清单能重建出链上的根时（第 5 节），才应当把集合显示为已验证。

### 8. 给持有人发放权益的合约

凡是根据策展集合电路的持有情况发放权益、奖励、访问权或投票权的合约，必须调用该集合登记合约的 `isOfficial(circuits, tokenId)` 进行校验，不得依赖网表内容或 `circuitInfo`。

### 9. 版税声明（可选）

TapeOut 的处理器合约没有实现 ERC-2981，策展人也无法给它加上。因此登记合约必须提供一个仅供参考的版税声明，格式照搬 ERC-2981，只多一个“处理器”参数；是否声明版税由策展人自行选择：

| 函数 / 事件 | 选择器 / Topic 0 | 含义 |
|---|---|---|
| `royaltyInfo(address circuits, uint256 tokenId, uint256 salePrice)` | `0x538bd5ea` | `(收款地址, 版税金额)`；电路不是官方作品、或集合没有声明版税时返回 `(address(0), 0)` |
| `royaltyOf(address circuits)` | `0xbb30d4ce` | 集合的 `(收款地址, 比例 bps)` |
| `setRoyalty(address circuits, address receiver, uint16 bps)` | `0x4adc6e44` | 仅策展人：更换收款地址或调低比例 |
| `RoyaltySet(address indexed circuits, address receiver, uint16 bps)` | `0x42467d290c72e182ef85378ad110bba52b9442ac5509a2fd4c2754a38dac93c9` | 发行时和每次修改时发出 |

1. 策展人可以在发行时声明版税（收款地址 + 比例，单位为万分之一），也可以不声明。当且仅当比例不为 0 时，必须给出收款地址；比例必须不超过 500（5%）。
2. 对非官方电路，`royaltyInfo` 必须返回 `(address(0), 0)`，所以 REF 包装壳和复制品永远搭不上集合的版税。
3. 发行后，策展人可以更换收款地址、可以调低比例，但比例不得调高；因此发行时没有声明版税的集合，之后也无法再加。其他任何人都不能修改。
4. 声明仅供参考。本提案不要求任何人支付，也不限制转账。市场应当为官方电路读取它，可以选择执行；平台可以在经由本平台的交易中强制收取。

### 10. 元数据承诺

网表、价格和预留标记都由根（第 5 节）承诺，但集合名称、代号、介绍和作品标题不在任何叶子里。没有承诺的话，任何网站都可以给官方电路换上别的标题或介绍。因此登记合约在发行时为每个集合记录一个 `metadata` 值，通过 `collectionOf` 返回（伪代码）：

```
titlesHash = keccak256(abi.encodePacked(keccak256(bytes(title_0)), …, keccak256(bytes(title_{count−1}))))
metadata   = keccak256(abi.encode(keccak256("TAP-curated-metadata"),
                                  keccak256(bytes(name)), keccak256(bytes(symbol)), keccak256(bytes(story)),
                                  titlesHash))
```

所有字符串都按 UTF-8 编码，标题按编号顺序排列。`name`、`symbol`、`story` 就是创建处理器时使用的字符串；参考实现的 Vault 在链上用发行参数计算它们的哈希（`metadataOf(name, symbol, story, titlesHash)`，`0xe2e2bef0`），因此承诺不可能与处理器不一致；发行者只需提供 `titlesHash`，且不得为 0。

1. `metadata` 必须在发行时固定，之后不得改变。
2. 策展人必须把名称、代号、介绍和全部标题与作品清单一起公开。
3. 前端应当先用这些内容重建 `metadata`，并与 `collectionOf(circuits).metadata` 比对，一致后才显示集合名称、代号、介绍和标题；不一致时不得把它们当作策展人发布的内容展示。

### 11. 代币元数据与图片（可选）

TapeOut 的处理器合约对每个电路的 `tokenURI` 都返回空值，也没有给处理器创建者留下设置它的入口，所以电路 NFT 在任何钱包和市场里都没有名称、图片和属性。因此登记合约必须实现下列函数；策展人可以在发行时为集合记录一个**按内容寻址**的元数据目录，登记合约据此为官方电路提供 `tokenURI`：

| 函数 / 事件 | 选择器 / Topic 0 | 含义 |
|---|---|---|
| `tokenURI(address circuits, uint256 tokenId)` | `0xe9dc6375` | 官方电路返回 `"<metadataURI>/<index>.json"`，`index` 是它在作品清单中的编号（`editionOf`）；非官方电路，或集合没有目录时，返回 `""` |
| `metadataURIOf(address circuits)` | `0x9eac0ca2` | 集合的目录：`"ipfs://<CID>"`、`"ar://<交易 id>"` 或 `""` |
| `MetadataURISet(address indexed circuits, string uri)` | `0xf4ea916416710952791c00e6c397903c99c416633fd82eeb8f5786572a9d899c` | 在发行交易中发出一次 |

1. 目录必须在发行时固定，之后不得改变。包括策展人在内，任何人都不能事后设置；发行时没有设置目录的集合，永远不会有目录。
2. 目录必须按内容寻址，这样目录里的内容也无法改变：`"ipfs://"` 后接一个指向不可变内容的 CID（CIDv0：`Qm` 加 44 个 base58 字符；或以 `bafy` 或 `bafk` 开头的小写 base32 CIDv1（涵盖 dag-pb、dag-cbor 和 raw 类型，哈希算法不限），50 到 100 个字符；不带路径，不接受其他编码，也不接受指向 IPNS 记录的 libp2p-key CID），或 `"ar://"` 后接 43 个字符、至少含一个大写字母的 Arweave 交易 id（base64url，通常是一个 Arweave 路径清单的 id）。ArNS 名称和子名称都是小写，所以“必须含大写字母”这一条保证 43 个字符的名称永远不会被当成 id；随机 id 不含大写字母的概率约为 2 × 10⁻¹⁰，遇到时上传工具重新签名即可。可变的名称（IPNS、DNSLink、ENS、ArNS）和 `http(s)` 网址必须拒绝。参考实现的登记合约在链上检查（`isContentAddressed(bytes)`，`0x9bdfd89c`），不符合就让发行回滚。
3. 对非官方电路，`tokenURI` 必须返回 `""`，所以 REF 包装壳和复制品永远不会显示作品的图片。
4. 文件 `<index>.json` 应当遵循 ERC-721 元数据 JSON 格式（`name`、`description`、`image`，可选 `animation_url` 和 `attributes`）。其中 `name` 应当等于第 `index` 号作品已承诺的标题（第 10 节），`image` 和 `animation_url` 本身也应当按内容寻址（`ipfs://…` 或 `ar://…`，可以带路径，但路径每段只能有字母、数字和 `. _ ~ -`，不能是 `.` 或 `..`，也不能用百分号编码，这样链接无法跳出它的内容地址）。参考工具还会写入 `properties`，包含作品的 `index` 和 `netlistHash`，把图片和电路设计绑在一起。
5. 前端应当只通过登记合约的 `tokenURI` 读取电路的元数据，应当只显示按内容寻址的图片，并且不得把“有元数据”当作电路是官方作品的证据（第 7.2 条），这只由 `isOfficial` 决定。

因为目录在第一次销售前就已固定，策展人需要在发行前上传：先上传图片（每张图片各自得到一个内容地址），再为每件作品上传一个指向图片的 `<index>.json`，最后上传目录。发行时存储目录地址，比不存储多花约 90,000 gas（`ar://` id）到 105,000 gas（CIDv1），主网分叉实测。文件本身不存放在链上：Arweave 一次付费、永久保存；IPFS 需要至少一方（策展人、平台或持有人）持续保存（pin）这些文件，任何持有文件副本的人都能以同一个 CID 重新发布。图片由网表本身算出来的集合，也可以把 `animation_url` 指向一个存放在链上或 Arweave 上的渲染页面。

### 12. 给 TapeOut 的建议（说明性）

本节是给 TapeOut 的建议，不是本标准的要求；本提案的其他部分都不依赖它。只读取 NFT 合约自身 `tokenURI` 的钱包和市场看不到登记合约。TapeOut 只需对信标背后的共用处理器实现做一处改动，就能让所有策展集合的元数据在任何地方都可见，而且不必信任任何特定的登记合约。示例（说明性）：

```solidity
interface ICircuitURIProvider {
    function circuitURI(address circuits, uint256 tokenId) external view returns (string memory); // 0xcd51078c
}

function tokenURI(uint256 id) public view returns (string memory) {
    _requireOwned(id);
    address creator = transistors.creator();
    if (creator.code.length == 0) return "";
    // low-level calls: try/catch would not catch return data that fails to decode
    (bool ok, bytes memory r) = creator.staticcall{gas: 30_000}(
        abi.encodeCall(IERC165.supportsInterface, (type(ICircuitURIProvider).interfaceId)));
    if (!ok || r.length < 32 || abi.decode(r, (uint256)) != 1) return "";
    (ok, r) = creator.staticcall{gas: 200_000}(abi.encodeCall(ICircuitURIProvider.circuitURI, (address(this), id)));
    if (!ok || r.length < 64) return "";
    (uint256 offset, uint256 length) = abi.decode(r, (uint256, uint256));
    if (offset != 32 || length > r.length - 64) return "";
    return abi.decode(r, (string));
}
```

处理器只询问它自己的创建者，而创建者是谁，只取决于当初创建这台处理器的一方：创建者没有声明 `ICircuitURIProvider` 的处理器（包括所有普通钱包创建的）毫无变化；策展集合的创建者是它的 Vault，Vault 没有所有者，返回的是登记合约的 `tokenURI`（只限官方作品，发行时固定）。TapeOut 不需要给登记合约设白名单，也不需要评判任何集合。gas 上限防止有问题的创建者让 `tokenURI` 变得昂贵；任何失败（调用回滚、gas 用尽、返回数据过短或格式不对）都返回 `""`，也就是现在的行为。正式实现还要最多只复制几 KB 返回数据（需要用汇编，因为普通 `staticcall` 会复制全部返回数据），防止创建者返回超大字符串。参考实现的 Vault 已经实现了 `ICircuitURIProvider` 和 ERC-165，所以 TapeOut 一旦采纳，已发行的策展集合会立刻显示元数据。

## 设计理由

- **看来历，不看内容。** 三类外来电路中，有两类除了原始网表字节以外，和官方电路在处理器合约的任何接口上都一样，其中一类连字节都一样。唯一能在所有情况下区分真假的，是“谁流片的”。在流片当下记录它，任何人都能读取，不必相信策展人事后的说法或某个索引服务。
- **为什么必须由策展人本人发行。** 对参考实现的内部复核发现：如果没有这条规则，任何人都能以真实艺术家的名义发行集合、复用艺术家的根，并让其中的电路被认证为官方。也可以用自己的名义复用艺术家的根。要求 `curator == msg.sender` 堵住了第一条路，把叶子绑定到策展人堵住了第二条。替艺术家操作发行的平台，仍可以让艺术家本人签署发行交易。
- **为什么预留作品在发行时固定。** 项目方常常要把一部分作品留给国库，以后用于赠送、空投或奖励贡献者。如果策展人可以事后决定留哪几件，就可能在看清需求后把最抢手的作品拿走。把预留标记写进叶子，并在发行时固定国库地址和预留数量，就让这个划分在任何人购买之前公开且不可更改。所有预留作品都先进入同一个固定的国库，而不是直接发给任意地址，这样国库的去向一目了然：之后的每一次赠送或空投都是一笔公开可查的普通转账。
- **为什么版税只是声明。** 电路的版税无法强制：NFT 合约属于 TapeOut，策展人既不能给它加 ERC-2981，也不能像 ERC-721C 那样限制转账，任何人都能绕开市场私下交易。整个 NFT 行业里，ERC-2981 本身也是出于同样的原因只作参考。一个公共协议能做的有用的事，是在市场本来就要读取的“官方认证”旁边，提供一个公开的位置写明策展人的条款，并保证在有人购买之后不能调高。实际收取交给平台。平台为自身服务收的费用不属于本提案；只有可选的首发分成（`platform`、`platformBps`）属于本提案，因为它由 Vault 支付。
- **为什么预留作品在销售结束后仍能领取。** 早先的版本在销售结束时就停止预留领取，策展人一旦忘了领取，作品就永久丢失。现在领取一直开放到剩余晶体管被销毁为止，而销毁只在还有预留作品未领取时才推迟，并且最多推迟一个固定的宽限期。这样既消除了这种损失，又不会让任何人把剩余晶体管永远留着不销毁。宽限期也没有给策展人新的权力：它只能把清单里本来就标为预留的作品，流片到发行时固定的国库。
- **为什么标题用哈希承诺。** 把每个标题都写进链上，要为只有前端才读的文字按字节付 gas。发行时固定一个哈希，只占一个存储槽，任何改动都能被发现。名称、代号和介绍由 Vault 用发行参数计算哈希，所以承诺描述的一定是实际创建的那台处理器。
- **为什么元数据用发行时固定的目录，而不是把图片存上链。** 对大多数集合来说，没有图的 NFT 用处不大；但在 BNB Smart Chain 上存图片每字节约 216 gas：一个 700 KB 的动图约 1.5 亿 gas，几千件作品的集合要用掉数百个区块的 gas。按内容寻址的目录在链上只占一个短字符串，而它的地址本身就是目录里每个文件的哈希，所以承诺这个地址，就像根承诺网表一样牢固地承诺了目录里的每个文件，以及这些文件按内容地址链接的每张图片（第 11.4 条）。在发行时固定它，延续了本提案给买家的保证：买之前看到的东西，之后谁都换不掉，策展人也不行。拒绝可变名称，是因为名称只是一个指针，它的所有者可以改指向。对非官方电路返回 `""`，让图片和版税一样，跟着来历走，而不是跟着网表内容走。
- **为什么由 Vault 为它的处理器作答。** 处理器的创建者是 TapeOut 本来就和每台处理器关联的唯一一方，而策展集合的 Vault 按构造就是这个创建者（第 4.4 条）。让处理器去问创建者，TapeOut 就能支持所有策展集合以及将来的其他方案，而不必选择信任哪些登记合约。
- **为什么策展人可以暂停和延长销售，但不能缩短或重新打开。** 项目方在发售中可能遇到问题，比如页面故障、公告有误或市场突发事件，需要先停一停，或者多给买家一些时间。暂停和延长只改变“清单里的作品什么时候能买”：不增加作品、不改价格、不影响已售出的电路，买家得到的和当初承诺的完全一样。缩短销售或重新打开已结束的销售，会打破买家可以依赖的承诺：作品在公布的结束时间之前一直可以买，结束之后永远不再卖。所以这两种都做不到。
- **为什么策展人不能更换。** 发行后，包括策展人自己在内，任何人都不能更换策展人地址，私钥丢失也没有任何找回办法。任何找回途径都是一种可能被盗用或滥用的特权，买家还得去信任掌握它的人。担心单把私钥丢失的策展人，可以用多签钱包发行。
- **为什么由 Vault 流片，而不是买家自己流片。** 如果买家拿着分到的晶体管自己流片，登记合约就分不清他们的电路和用同样晶体管流片的复制品。晶体管全部留在 Vault 里，别人能流片进这台处理器的就只剩不消耗晶体管的纯 REF 网表，其中包括本身就是纯 REF 的清单作品的同字节复制品（见安全考虑）；它们都永远不会被认证。
- **为什么绑定时登记合约要自己全部重查。** 如果登记合约采信 Vault 的说法，那么保证的强度就只取决于最不严谨的那个 Vault。第 4 节的检查都是廉价的只读调用，能让发行保证不依赖 Vault 代码本身（前提是该 Vault 由本登记合约部署）。
- **为什么不做包装集合。** 包装集合（另发一个 ERC-721 包住官方电路）能让市场不接入也看到一个干净的集合，但它必须长期托管所有作品，风险集中；而且包装后电路归包装合约所有，买家会失去电路容器账户（ERC-6551）的控制权，在 TapeOut 上也不显示为持有人。登记合约什么资产都不持有。将来可以在这个登记合约之上再做可选的包装层。
- **为什么 Merkle 根在发行时固定。** 这样整份作品清单和每件作品的价格在第一次销售前就已经确定，策展人不能事后加作品，也不能悄悄把某个设计换成另一版。
- **为什么不要求与 tapeout.net 编辑器逐字节一致。** 官方身份来自被认证的流片，而不是重新推导网表。叶子承诺的就是 Vault 实际流片的字节。
- **为什么平台分成最多 10% 且没有管理员。** 发行工具常由平台替艺术家运行。限制分成上限并去掉所有管理权限，艺术家在发行后就不需要信任平台。

## 向后兼容

本提案不修改任何 TapeOut 合约。已有的处理器无法按第 4 节成为策展集合，因为它们的晶体管已经流通。这些项目可以在另一个 TAP 里发布签名的官方编号名单，但那属于项目方的声明，不是来历保证，不在本提案范围内。

开发中在主网发现：`circuits.nextId()` 返回的是“到目前为止已流片的电路数”（新处理器返回 0；第一次流片后返回 1，该电路的 id 为 1），而不是 TAP-02 §6 所写的“下一个电路将获得的 id”。参考实现按 `nextId() == 0` 检查第 4.6 条。TAP-02 可能需要更正这一描述。

## 测试用例

参考实现包含 50 个 Foundry 测试，在 BNB Smart Chain 主网分叉上运行（`forge test --fork-url https://bsc-dataseed.bnbchain.org`），作品清单是参考工具生成的 7 个临时测试电路：翻转触发器（toggle）、4 位计数器、7 位 LFSR、异或门、引用创世 13 号电路并加一位奇偶校验输出的电路，以及两件预留给国库的作品（TAP-02 测试向量 `popcount8_3151` 和一个使用中文标题的与门）。2026-10-30 全部通过（免费公共节点只保留近期状态，所以测试分叉的是最新区块，而不是固定区块）。测试如下：

| 测试函数 | 测试 | 证明了什么 |
|---|---|---|
| `test_Launch_AtomicAndVerified` | 原子发行 | 一笔交易完成创建、铸完（非零单价，5 批）、绑定、锁定元数据目录、退回余款；408 万 gas；发行者实付正好是工具预测的工厂部署费和协议费共 0.0015 BNB（0.001 部署费 + 5 × 0.0001） |
| `test_Launch_ZeroMintPrice` | 零单价发行 | 单价为 0 时同样可行 |
| `test_Launch_RejectsBadParams` | 拒绝错误参数 | 平台分成超过 10%、销售结束时间不晚于开售时间、发行资金不足 |
| `test_L2_LaunchFeeCap` | 发行费上限 | 费用超过发行者设定的上限时发行回滚 |
| `test_H1_CopycatLaunchRejected` | 拒绝冒名发行 | 任何人都不能以别人的名义发行；复用根、自任策展人的山寨集合卖不出清单里的任何作品 |
| `test_L3_RefundReentryBlocked` | 退款重入防护 | 策展人账户若在发行退款回调里尝试购买，会碰到重入保护（`ReentrancyGuardReentrantCall`），什么也买不到 |
| `test_L4_TokenOfAndEditionOfDefaults` | `tokenOf` 与 `editionOf` 的默认值 | 作品流片前，`tokenOf` 报告“未流片”（绝不会当成 id 0）；非官方电路返回 `(false, 0)`；流片后作品对应到它的电路 id |
| `test_PayeesCannotBeVaultOrRegistry` | 收款方不能是 Vault 或登记合约 | 国库不能是正在部署的 Vault；平台既不能是该 Vault，也不能是登记合约 |
| `test_BuyAll_CertifyPayFinalize` | 全部售出 | 7 件作品都发出带网表哈希的 `Certified`、按正确编号认证、归买家所有（两件预留作品归国库）、网表字节与清单一致、晶体管消耗与工具预测完全相同；收入分配正确；剩余 9,814 个 NAND 和 3 个 LATCH 被销毁 |
| `test_M1_FinalizeAfterSaleEnd` | 销售结束后收尾 | 销售结束后停止购买；还有预留作品未领取时，销毁要等宽限期结束，之后即使仍有作品未售也能销毁剩余晶体管 |
| `test_L1_WithdrawTo` | 提到别的地址 | 收款方可以把收入提到另一个地址，其他人不行 |
| `test_R1_NoWayToExtractTransistors` | R1 晶体管无法取出 | 任何人都无法转走、销毁或增发 Vault 的晶体管；售罄前且销售结束前无法收尾 |
| `test_R2_SameNetlistElsewhereIsNotOfficial` | R2 别处的同网表不算官方 | 同一网表在别的处理器上流片不是官方；在策展处理器上别人无法流片（`ERC1155InsufficientBalance`） |
| `test_R3_RefWrapperIsNotOfficial` | R3 REF 包装壳不算官方 | 陌生人零晶体管流片 REF 包装壳进入策展集合，`circuitInfo` 与官方相同，但不是官方 |
| `test_R4_EachWorkOnceAndStrictInputs` | R4 每件只铸一次，输入严格校验 | 重复购买、篡改网表、低价、错误证明、错误引脚数、把有效作品换到别的编号下、错误金额、越界编号、零接收地址 |
| `test_R5_OnlyBoundVaultCanCertify` | R5 只有绑定的 Vault 能认证 | 陌生人、非登记合约部署的 Vault 都无法绑定或认证（伪造的 Vault 两者都试过）；不能重复认证；编号不能越界 |
| `test_R7_WorkListIsFixed` | R7 清单不可改 | 根不可变；即使用真实的证明、编号和价格，清单外的网表也无法出售 |
| `test_SaleStartIsEnforced` | 开售时间 | 开售前无法购买 |
| `test_Sale_CuratorCanPauseAndResume` | 暂停与恢复 | 只有策展人能暂停；暂停期间谁都买不了，预留作品照常领取；恢复后可以继续购买 |
| `test_Sale_PauseAlsoStopsPresale` | 暂停也停预售 | 暂停同样停止预售，恢复后预售重新开放 |
| `test_Sale_ExtendOnlyLaterWhileOpen` | 只能延长 | 只有策展人能延长；新的结束时间必须更晚；过了原结束时间仍可购买，收尾要等到新的结束时间；新的结束时间过后，既不能再延长，也不能重新开放 |
| `test_Sale_NoControlsAfterFinalize` | 收尾后不能再控制 | 收尾之后，既不能暂停，也不能延长 |
| `test_Limit_Unlimited` | 不限制选项 | 选择“不限制”时，一个钱包可以买下全部公开作品 |
| `test_Limit_CapsEachWallet` | 单钱包限额 | 限额为 2 时，达到限额的钱包不能再买；替别的钱包购买（无论哪个方向）都会被拒绝，且不计数；转账和预留领取不受限制 |
| `test_Royalty_OfficialOnly` | 版税只给官方作品 | 官方作品返回声明的 3% 版税；同集合里的 REF 包装壳返回 0 |
| `test_Royalty_None` | 不设版税 | 集合可以不声明版税，之后也无法再加 |
| `test_Royalty_CuratorCanOnlyLower` | 版税只能调低 | 策展人能换收款地址、调低比例；调高、陌生人修改、重复声明都会被拒绝 |
| `test_Royalty_ParamsChecked` | 版税参数校验 | 比例超过 5%、只有地址没有比例、只有比例没有地址，发行时都会被拒绝；正好 5% 可以发行 |
| `test_Presale_AllowlistedWithinQuota` | 白名单额度 | 白名单钱包在预售期内最多买到自己的额度 |
| `test_Presale_OnlyAllowlisted` | 只限白名单 | 陌生人不能参加预售，谁也不能冒领更大额度，公开发售仍未开始 |
| `test_Presale_Window` | 预售时间窗 | 预售从 `presaleStart` 开始，到公开发售开始时结束；之后所有人都可购买 |
| `test_Presale_RespectsWalletLimit` | 预售也受单钱包限额 | 单钱包限额叠加在预售额度之上 |
| `test_Presale_ParamsChecked` | 预售参数校验 | 没有白名单就不能设预售时间；预售必须早于公开发售 |
| `test_Limit_ParamsChecked` | 限额参数校验 | 开启限额却没填数量、或填了数量却没开启限额，都会被拒绝；限额可在链上查询 |
| `test_Reserved_PublicCannotBuy` | 预留作品不能购买 | 无论价格为 0 还是其他价格，都买不到预留作品 |
| `test_Reserved_CuratorClaimsToTreasury` | 策展人领取进国库 | 只有策展人能领取，开售前也可以；作品进入国库，是官方作品且标为预留，不产生收入，不能重复领取 |
| `test_Reserved_TreasuryCanTransferAndItStaysOfficial` | 国库转出后仍是官方 | 国库把作品送人、对方再转手，作品依然是官方作品且标为预留 |
| `test_Reserved_CannotClaimPublicWork` | 不能把公开作品挪进国库 | 策展人无法把公开作品领取进国库 |
| `test_Reserved_DeclaredCountIsACap` | 预留数量是上限 | 即使清单里藏了更多预留叶子，超过发行时声明的预留数量也领取不了 |
| `test_Reserved_Params` | 预留参数校验 | 有预留作品就必须设国库，国库不能是登记合约；预留数量不能超过作品总数 |
| `test_Reserved_ClaimAfterSaleEndWithinGrace` | 销售结束后仍可领取 | 销售结束后策展人仍能领取预留作品；还有未领取时，收尾要等到宽限期恰好结束；之后任何人都能收尾，收尾后不能再领取 |
| `test_Reserved_AllClaimedFinalizeAtSaleEnd` | 全部领取后立即收尾 | 预留作品全部领取后，销售结束时即可收尾，不必等待 |
| `test_Reserved_BatchClaim` | 一次领取多件 | 一笔交易把两件预留作品领取进国库；陌生人、总费用不对、混入公开作品（整批都不领取）、重复领取都会被拒绝 |
| `test_Metadata_Committed` | 元数据承诺 | 登记合约记录的承诺与工具计算的一致（含中文标题）；介绍不同则承诺不同；没有标题哈希时拒绝发行 |
| `test_Metadata_TokenURIOfficialOnly` | 只有官方作品有元数据 | 官方作品（购买的和预留的）返回 `<目录>/<编号>.json`；官方作品的 REF 包装壳、不存在的电路和其他处理器返回 `""`；作为处理器创建者的 Vault 通过 `circuitURI` 给出同样的答案，并通过 ERC-165 声明支持 `ICircuitURIProvider` |
| `test_Metadata_FixedAtLaunch` | 目录发行时固定 | Vault 和策展人都不能再次设置目录 |
| `test_Metadata_None` | 不设目录 | 发行时没有目录的集合，对所有电路返回 `""` |
| `test_Metadata_OnlyContentAddressed` | 只接受按内容寻址的目录 | `https` 网址、IPNS 名称（包括写成 base36 和 base32 CID 的 IPNS 密钥）、ENS 式域名、ArNS 名称、43 个字符的小写名称、带结尾斜杠的 CID、长度不对的 id、大写的 base32、非 base58 字符、大写的协议名都在发行时被拒绝；CIDv0、dag-pb 和 raw 类型的 CIDv1、Arweave id 被接受 |
| `test_L5_RejectsStrayFundsAndTokens` | 拒收意外资产 | Vault 拒收普通 BNB，也拒收第三方转来的本处理器电路 |
| `test_ReentrancyFromRecipientFails` | 重入防护 | 接收方在回调里再次购买，会以 `ReentrancyGuardReentrantCall` 使整笔购买回滚 |

测试向量取自测试样例 `test/fixtures/manifest.json`（链 id 56，登记合约 `0x00000000000000000000000000000000c0dec0de`，策展人 `0x00000000000000000000000000000000000c0ffe`），第 5、6、10、11 节的任何实现都必须得出相同的结果：

| 输入 | 期望输出 |
|---|---|
| 作品叶子（第 5 节）：index 0，netlistHash `0x7ca496e2d18c48a09aea26fc7df653df9c3fa5a10cb1a2bb7ec311c8220130b2`，nIn 1，nOut 1，price 10¹⁶ wei，reserved false | `0x14358d2386912617595812f5484d92d4899a96129a8904f771b29454b0524156` |
| 7 件作品的根（第 5 节） | `0x131d82b25cc3283cc417942e38b63e6d665024c75cc40c645602d13437af1949` |
| 白名单叶子（第 6 节）：钱包 `0x00000000000000000000000000000000000a11ce`，额度 2 | `0xdecc2768d819e2e59a3b44125831aaf52623a661945407499fbaf406f8658755` |
| 7 个标题的 `titlesHash`（第 10 节） | `0x1ecdc691abff41d0c4b6f032dd9b4845349526520462790a1fcffac33215ba9a` |
| `metadata`（第 10 节）：名称 `P05 Test Collection`、代号 `P5TEST`、样例中的介绍和上面的 `titlesHash` | `0x131a0d4c42d02f4d670b1f463011bea1aa93a04665aaadcb1fe32dd663cd218c` |
| `isContentAddressed`（第 11 节）：`ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG`、`ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi`、`ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U`、`""` | true |
| `isContentAddressed`（第 11 节）：`ipfs://k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8`、`ar://myundername_mycollectionname-permaweb123456`、`https://example.com/meta` | false |

工具自检通过全部 13 个 TAP-02 向量（5 个合法、8 个非法）和 200 个随机画布设计；另外跑了 6,000 个随机设计（含输入、常量、LATCH 反馈、打乱文件顺序、多输出），编码后的网表与画布图在 8–24 拍内的运行结果全部一致。在本地分叉上按真实流程做了端到端演示：部署登记合约，针对它生成清单（链上检查 REF 目标），以策展人身份发行（`script/Demo.s.sol`），购买两件作品，一次领取两件预留作品，再由另一个账户流片一个 REF 包装壳。`curate verify` 报告两件作品为官方且网表一致，预留作品为官方、预留且归国库所有，包装壳为非官方——尽管它的 `circuitInfo` 完全相同；`curate checkroot` 用公开的作品重建出的根与链上一致，国库地址和预留数量也一致。

发售与验真页面（`web/index.html`）在本地分叉上用真实浏览器测试过（`web/run_e2e.sh`，26 项浏览器检查和一次链上 `checkroot` 全部通过）：能加载集合，发行清单与链上不一致时拒绝加载（哪怕只改了一件作品的价格、一个标题，或换了策展人）；已承诺的、含 HTML 的标题只显示为文字，不会执行脚本；在钱包里切换账户会断开连接；页面在自己的内容安全策略下正常运行；白名单钱包在预售期内购买直到额度用完；公开发售开始后再买一件，两件都归买家所有；预留作品不向买家提供购买按钮；策展人在发售期间领取一件预留作品进国库，销售结束后再领取另一件；验真页能报告官方作品的编号和网表一致性，能识别零成本 REF 包装壳并说明原因，能报告不存在的电路；在 390 像素宽的手机屏幕上布局正常。

工具还会拒绝含有“指向尚不存在的电路”或“引脚数不对”的 REF 的清单，并对纯 REF 作品发出警告（任何人都能流片它的同字节复制品）。

## 参考实现

代码仓库：<https://github.com/gm-lsp/Tapeout-OCCC/tree/fcdec699d7dacdb74c54e457f9094212214e5f72>（MIT）
- `src/CuratedRegistry.sol`：登记合约兼发行器（第 3、4 节）
- `src/CuratedVault.sol`：Vault（第 6 节），参考实现为每件作品固定价格
- `src/interfaces/ICuratedRegistry.sol`：第 3、9、11 节的接口
- `src/interfaces/ICircuitURIProvider.sol`：第 12 节建议 TapeOut 采用的接口
- `tool/curate.py`：无依赖的 Python 工具：TapeOut 画布 → TAP-02 网表编码（用 TAP-02 参考实现校验）、链上检查 REF 目标、晶体管计数、作品清单 Merkle 树与证明、元数据承诺、第 11 节目录所需的元数据文件（`metadata`）、发行清单与费用上限、重建根和元数据（`checkroot`）、链上验真（`verify`）
- `test/Curated.t.sol`、`script/Demo.s.sol`：上述测试与演示；`script/Launch.s.sol` 按清单发行集合
- `web/index.html`、`web/app.js`、`web/run_e2e.sh`：发售与验真页面及其浏览器测试

## 部署

尚未部署。

| 链（chainId） | 合约 | 地址 | 必须指向的实现 | 只读核对方式 | 已封存？ |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | CuratedRegistry | 待定 | 不是代理合约 | `FACTORY()` 返回 `0x68224F668083c29e9800Be2a646d42d18cedF7e2`，且运行时字节码与所链接提交的参考实现一致 | 是（无所有者、无代理） |

## 安全考虑

- **对 TapeOut 的信任。** 工厂、处理器和晶体管合约都可被 TapeOut 多签升级。本提案依赖于：`isCPU` 正确；`tapeout` 只扣调用者的晶体管（晶体管合约有一个可由处理器合约调用的 `burnFrom`，所以升级后的处理器合约可以销毁 Vault 的库存）；供应上限不变；允许向销毁地址转账。登记合约的发行检查只在发行当时成立；已经做出的认证不受影响，因为它们记录的是流片当时的来历。
- **内部复核。** 对参考实现做过四轮内部安全复核，每轮都由未参与编写代码的人进行。第一轮：没有严重问题；1 个高危（冒用策展人名义发行，已用第 4.1 条和绑定策展人的叶子修复）；2 个中危（一件卖不出的作品让收尾永远无法进行；给某个编号偷加叶子——已用销售结束时间和第 5 节的公开要求修复）；5 个低危（已修复：`withdrawTo`、发行费上限、发行退款重入、`tokenOf` 不再依赖 id 0、拒收外来电路）。第二轮覆盖国库预留、限额、预售、版税和网页代码，没有严重问题；合约和工具方面的问题均已修复（开启限额时只能给自己的钱包买，别人无法耗光你的额度；预售开始时间为 0、国库地址等于 Vault 或登记合约时拒绝发行；`checkroot` 改为重建全部作品和白名单，并逐项核对链上的全部发行设置），网页方面的问题也已修复（见下面“网页”一条）。第三轮对最终代码重新复核，没有严重、高危或中危问题；低危问题已修复，或列在下面（预留作品、国库合约、作品清单、销售结束时间、收款方）。第四轮复核元数据部分（第 11~12 节及工具和网页的相应代码），没有严重问题，发现的问题都已修复：图片路径中用百分号编码的 `..` 可以跳出内容地址；写成 `ipfs://` CID 的 IPNS 密钥能通过检查；43 个字符的 ArNS 子名称理论上可能被当成 Arweave id（现在由“必须含大写字母”一条排除）；工具发行前没有把目录读回核对；元数据文件并非在所有平台上都按 UTF-8 写入。每一项链上修复都有回归测试；“偷加叶子”的问题由第 5 节的公开要求处理，`checkroot` 和参考网页都会执行这项检查。
- **元数据的可用性。** 登记合约固定的是元数据的地址，而不是它能否被访问。IPFS 上的文件如果没有人保存，就会消失；策展人最好在多个服务商处保存，或使用 Arweave。通过 HTTP 网关读取文件的前端，相信网关返回的就是地址所对应的内容；前端可以自行用地址核对内容。发行时目录无法访问或写错的集合，事后无法更正（§11.1），所以工具最好在发行前把目录读回来核对。
- **“官方”不保证什么。** 登记合约认证的是电路的来历，而不是它的功能。策展人可以列入任何合法网表，包括引用其他处理器电路的网表，其行为取决于被引用的电路（TAP-02 安全考虑）。
- **外来电路仍会出现在集合里。** 纯 REF 包装壳永远可以流片进任何处理器。本提案让它们可以被区分，但无法也不试图阻止它们。不遵守第 7 节的前端仍会显示它们。
- **Vault 的资产。** Vault 持有的晶体管只能用于它自己的处理器；它还暂存销售收入，直到由固定的收款方提取或代为提取。Vault 没有所有者。每次销售和领取都先更新 Vault 的状态，再进行外部调用；所有会进行外部调用、修改状态的入口（`initialize`、`buy`、`buyPresale`、`claimReserved`、`claimReservedBatch`、`withdraw`、`withdrawTo`、`finalize`）共用同一个重入保护（`setPaused` 和 `extendSale` 不进行外部调用）；`receive` 不受重入保护，但只接收本处理器晶体管合约转来的 BNB。
- **合约买家与 EIP-7702 账户。** 电路用 `safeTransferFrom` 发送。如果接收方有代码但没有实现 `onERC721Received`，购买会整体回滚，不会损失资金；买家可以指定另一个接收地址。注意 BNB Smart Chain 上一些广为人知的地址带有 EIP-7702 委托代码。
- **先到先得。** 网表和证明都是公开的，开售后机器人可以立刻抢走 0 元或低价作品；两人也可能同时抢同一件，后到的交易回滚。盲盒或先承诺后揭示的发售方式可以避免这一点，并且可以基于同一个登记合约实现。
- **预留作品。** 国库像持有普通电路一样持有预留作品，保护它们的是国库的私钥，建议使用多签钱包。预留作品可以一直领取到剩余晶体管被销毁为止：销售结束后，如果预留作品已全部领取，或者已过 `RESERVE_GRACE`，任何人都可以调用 `finalize` 销毁；到那时还没领取的预留作品会永久丢失。
- **国库合约。** 预留作品用 `safeTransferFrom` 发给国库。如果国库是一个不接收 ERC-721 的合约，每次领取都会回滚，收尾后这些预留作品就丢失了。Safe 等多签钱包可以接收；策展人最好在发行后立即领取一件预留作品来确认。
- **作品清单。** 叶子绑定的是链、登记合约和策展人，而不是某一个集合。策展人如果在第二个集合里重复使用同一份作品清单或白名单，每份证明在两个集合里都有效；工具最好为每个集合生成新的清单，前端以处理器地址识别集合，绝不用名称。
- **销售结束时间。** 销售结束前，未售出的作品都可以购买，剩余晶体管也一直留在 Vault 里。如果结束时间非常遥远（测试样例用的是 2100 年），剩余晶体管实际上永远不会被销毁；策展人最好设定合理的结束时间。
- **收款方。** 收入需要收款方自己提取。如果收款方是一个既不能接收 BNB、也不能调用 `withdrawTo` 的合约，它自己的那份收入就会被锁住；Vault 只拒绝把 Vault 自己和登记合约设为收款方。
- **销售控制。** 策展人可以无限期暂停购买，也可以不断把结束时间往后推，这同时会推迟收尾和剩余晶体管的销毁。暂停期间买家无法强行购买；拿到策展人私钥的攻击者可以暂停或延长销售，但拿不走收入、改不了价格、也加不了作品。持有人和已售作品的官方身份永远不受影响。前端应当读取 `paused()` 和当前的 `SALE_END()`，而不是发行时的值。
- **策展人私钥。** 策展人地址永远不能更换。私钥一旦丢失，未领取的预留作品无法再领取，版税也无法再修改；收入仍可提取，但只能提到这个地址。这是有意的设计（见设计理由）。
- **纯 REF 作品。** 只由 REF 记录组成的作品不消耗晶体管，任何人都能把它的同字节复制品流片进策展处理器。复制品不是官方的，但看起来一样；工具会对这类作品发出警告。
- **费用变化。** Vault 在购买时读取 `TAPEOUT_FEE()`，费用变化会转给买家承担，而不会导致无法销售。
- **网表大小。** 主网上超过约 34,000 字节的流片会失败，工具会拒绝。大作品应拆成子电路，再用 REF 组合。
- **Merkle 叶子**做了双重哈希，内部节点无法被冒充为叶子。
- **网页。** 页面把发行清单视为不可信数据：链、RPC、登记合约和处理器地址只从本站的 `site.json` 读取（网址参数只在本机测试时有效）；在链上核对 Vault 属于该登记合约；用发行清单重建每一件作品的叶子和白名单的根，任何一项与链上不一致就拒绝加载；发行清单里的所有内容都只作为文字插入；脚本从本站加载，并启用严格的内容安全策略；外部 ethers 库用子资源完整性（SRI）哈希锁定。在别的集合里是官方作品的电路，只会显示“不属于本集合”，绝不显示为官方。页面还会重建元数据承诺（第 10 节），名称、代号、介绍或标题与之不一致的发行清单一律拒绝加载。
- **尚未审计。** 参考实现只做过内部复核。在独立审计之前，不宜用于承载大额资产。

## 版权

依 [CC0](../LICENSE) 放弃版权及相关权利。
