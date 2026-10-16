# 数据库结构冻结说明（db-freeze）

> 负责人：后端 D1 ｜ 冻结日期：2026-10-15 ｜ 适用：第一阶段（中期考察 2026-10-26 前）
>
> 一句话：**10 张表的结构自本说明发布起冻结**。任何改动必须走第五节的流程，不允许任何人（包括 D1 自己）直接改 `V1__init_schema.sql` 后悄悄提交。

---

## 一、冻结基线是什么

| 项 | 内容 | 状态 |
| --- | --- | --- |
| 结构来源 | `db/migration/V1__init_schema.sql`（10 表 / 10 外键 / 24 CHECK / 31 索引） | ✅ 冻结 |
| 固定配置种子 | `db/seed/V2__seed_security_state.sql`、`db/seed/V3__seed_platform_control_plane.sql` | ✅ 冻结（幂等，可重跑） |
| 验证证据 | `db/verify/verify_schema.sql` → 17 项全 PASS（`verify_result.txt` 留档） | ✅ 已实跑 |
| 数据基线 | `tools/import/output/baseline_data.sql`（10000 员工等，MySQL 8.0.41 实灌 2.7s 零报错） | ✅ 已实跑 |
| 编码映射 | `tools/import/output/code-mappings.json`（映射版本 1） | ✅ 冻结 |

## 二、冻结覆盖的字段级要点（改这些 = 必须走流程）

1. **排序规则**：`sys_dept.node_key`、`sys_user.username`、`sys_role.role_key`、`sys_application.app_key`、`sys_permission.perm_key` 等业务标识列全部 `utf8mb4_bin`（大小写敏感）。改成 ci 级会静默破坏唯一性语义。
2. **生成列与唯一根**：`sys_dept.root_guard`（生成列）+ `uk_dept_single_root` 唯一索引，共同保证全库唯一 ROOT。动其中任何一个都要两个一起动。
3. **跨列 CHECK**：如 `sys_user` 的「ENABLED 必须有 password_hash」、`sys_permission.source_row <> 1`、`sys_security_state.id = 1`。CHECK 在 MySQL ≥ 8.0.16 才生效（verify 的 Section B 就是测这个）。
4. **外键全部 RESTRICT**：不存在任何 CASCADE/SET NULL。这是「只停用、不物理删除」的底层保障（审计可追溯）。
5. **锁串行点**：`sys_security_state` 单行表。所有管理写事务第一步 `SELECT ... FOR UPDATE` 这行。改结构 = 改全组锁流程。
6. **id 空间约定**：V3 种子恒占 `sys_application` 1–2、`sys_permission` 1–25、`sys_role` 1；业务数据（baseline 与后续接口写入）从 **100** 起。任何迁移不得占用他人区间。

## 三、冻结期间明确禁止（不走流程就是事故）

- ❌ 删除/重命名任何列、改任何列类型或排序规则
- ❌ 新增/删除表、外键、CHECK、索引
- ❌ 把 `ON DELETE RESTRICT` 改成其它行为
- ❌ 在业务代码里绕过 Mapper 直接拼 SQL 改这些表
- ❌ 修改 `V1/V2/V3` 已发布内容（它们已被 verify + 灌库验证锚定）

## 四、允许直接做的事（不破坏冻结）

- ✅ 用现有结构写业务 SQL / Mapper XML / 索引调优建议（先提 issue 讨论）
- ✅ 追加**只增不改**的迁移 `V4__xxx.sql`（须走第五节流程）
- ✅ 重跑 `V2/V3` 种子（幂等设计保证无副作用）
- ✅ 重跑 `tools/import/import_excel.py`（映射版本不变则编码不变）

## 五、结构变更流程（谁提都一样走）

```
1. 提出        在 MR/issue 里写清：改什么、为什么、影响哪些表
2. 影响评估    D1 出「字段影响面」清单：涉及 Mapper 哪些方法（对照 docs/mapper-registry.md）、
               E 的哪些文件、已灌数据是否要重导
3. 双确认      D1 + E 都回复同意（分工说明铁律：改表结构先打招呼）
4. 实施        新增迁移文件 V4__xxx.sql（禁止改 V1/V2/V3）；
               同步更新 mapper-registry.md 与 verify_schema.sql 的预期值
5. 回归        空库重跑 V1→V2→V3→V4→verify，全部 PASS；
               有数据依赖时重跑 import_excel.py 并核对 validation-report
6. 公告        组长合并后，在群里发变更说明（改了什么、谁受影响）
```

## 六、冻结解除条件

第一阶段中期考察结束、进入第二阶段（RBAC1）时，由组长宣布解冻并重立新基线。在此之前本说明持续有效。
