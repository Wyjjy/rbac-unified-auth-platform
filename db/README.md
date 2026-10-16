# 数据库交付物 · 使用说明

> 负责人：后端 D1 ｜ 版本：第一阶段 ｜ 最后更新：2026-10-15
>
> 本目录是**建表与种子**的唯一来源。E 的认证门户（A01–A06）依赖它，务必以本目录为准。

---

## 一、目录结构

```
D1交付物/
├── db/
│   ├── migration/
│   │   └── V1__init_schema.sql              # 10 张表 + 索引 + 外键 + 24 条 CHECK
│   ├── seed/
│   │   ├── V2__seed_security_state.sql      # 安全状态单行（id=1, policy_version=1）
│   │   └── V3__seed_platform_control_plane.sql  # platform/engineering 技术应用 + PLATFORM_ADMIN
│   ├── verify/
│   │   ├── verify_schema.sql                # 结构自检 8 项 + 约束行为验证 9 项
│   │   └── verify_result.txt                # 2026-10-15 实跑通过的输出留档
│   └── dev/
│       └── reset_local.sql                  # ⚠️ 仅限本地开发库，清空 10 张表
└── .gitignore                               # 仓库根目录用
```

**执行顺序是强制的**：`V1 → V2 → V3 → verify`。
`verify` 里的 B4 依赖 V3 建出的 `platform` 应用，顺序错了会空跑。

---

## 二、怎么跑

### 本地开发（从零开始）

```bash
# 0. 建库（只需一次）
mysql -h 127.0.0.1 -P 3306 -u root -e \
  "CREATE DATABASE IF NOT EXISTS rbac DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# 1. 建表
mysql -h 127.0.0.1 -P 3306 -u root --default-character-set=utf8mb4 rbac < db/migration/V1__init_schema.sql

# 2. 种子
mysql -h 127.0.0.1 -P 3306 -u root --default-character-set=utf8mb4 rbac < db/seed/V2__seed_security_state.sql
mysql -h 127.0.0.1 -P 3306 -u root --default-character-set=utf8mb4 rbac < db/seed/V3__seed_platform_control_plane.sql

# 3. 校验（关键！逐条看 verdict 列是否全为 PASS）
mysql -h 127.0.0.1 -P 3306 -u root --default-character-set=utf8mb4 rbac --table < db/verify/verify_schema.sql
```

### 重来一遍（本地库）

```bash
mysql ... rbac < db/dev/reset_local.sql      # 清空 10 张表
# 然后重新跑上面的第 1 步起的流程
```

### 接进项目（如果组里用 Flyway）

把 `migration/` 和 `seed/` 下的三个文件按 `V1__` / `V2__` / `V3__` 命名原样放进
`src/main/resources/db/migration/`，Flyway 会按版本号自动执行。
**`dev/reset_local.sql` 和 `verify/` 不要放进去**——前者是本地工具，后者会被 Flyway 当成迁移。

---

## 三、必须先确认的一件事：MySQL 版本 ≥ 8.0.16

**低于 8.0.16 的 MySQL 会静默忽略 CHECK 约束**（只解析、不执行、不报错）。
本项目把大量业务规则压在 CHECK 上（24 条），版本不够等于**这些规则全部失效**。

自查方法：跑一次 `verify_schema.sql`，若 `A2 CHECK 约束数` 通过但 `Section B`
大面积 FAIL，就是这个原因。

```sql
SELECT VERSION();   -- 必须 >= 8.0.16
```

---

## 四、十张表一览

| 表 | 职责 | 关键约束 |
| --- | --- | --- |
| `sys_dept` | 组织节点，四级：ROOT / COMPANY / DEPARTMENT / PROJECT_DEPT | `root_guard` 生成列 + 唯一索引保证**全库只有一个 ROOT** |
| `sys_user` | 员工与账号，`username` = 工号 | `ENABLED` 状态必须有 `password_hash`（跨列 CHECK） |
| `sys_role` | 直接角色，本阶段不建继承边 | `role_key` 唯一 |
| `sys_application` | 15 个业务应用 + 2 个技术应用（platform / engineering） | `app_key` 唯一 |
| `sys_permission` | 功能点的原子操作，`perm_key` 四段式 | `source_row <> 1`（不许把表头行导进来） |
| `sys_user_role` | 用户↔角色，**只允许完整替换** | 复合唯一键 |
| `sys_role_permission` | 角色↔权限，**只允许完整替换** | 复合唯一键 |
| `sys_session` | 可撤销会话，只存 token 的 SHA-256 摘要 | 主键 `CHAR(36)` |
| `sys_operation_log` | 审计日志，**只允许 INSERT / SELECT** | `event_type` 限定在 21 个登记值内 |
| `sys_security_state` | 安全配置写入的串行点（单行锁表） | `id` 恒为 1 |

设计要点：

- **没有一条外键是 `ON DELETE CASCADE`** —— 全部 `RESTRICT`。角色、用户、部门只允许
  「停用」（改 `status`），禁止物理删除。审计日志因此永远可追溯。
- **两条链**：`授权链` = user → user_role → role → role_permission → permission → application；
  `组织链` = dept 自引用四级树。`security_state` 和 `operation_log` 故意不连任何表。
- 详细 ER 图见 `../D1速读版_设计文档§3-§7.md`。

---

## 五、种子脚本的幂等性

`V2` 和 `V3` **可以安全地重复执行**，不会产生重复行（已实测：重跑两次行数完全不变）。
它们用的是 `INSERT ... ON DUPLICATE KEY UPDATE` / `INSERT IGNORE` 语义，
所以放进部署流水线不需要额外的「是否已执行」判断。

---

## 六、给 E 的三样东西（交接清单）

| # | 交付内容 | 位置 | 用途 |
| --- | --- | --- | --- |
| 1 | **建表 SQL 定稿** | `db/migration/V1__init_schema.sql` | 认证门户依赖的 `sys_user` / `sys_session` / `sys_security_state` 三张表 |
| 2 | `sys_security_state` 种子 | `db/seed/V2__seed_security_state.sql` | 登录时的策略版本号来源 |
| 3 | 技术应用与固定权限 | `db/seed/V3__seed_platform_control_plane.sql` | PLATFORM_ADMIN 角色、23 条平台权限、2 条工程权限 |

`assignRoles` 的锁流程代码（E 的 5 个写操作要复用）另行提供，不在本目录。

---

## 七、验证结果摘要（2026-10-15 实跑）

| 项目 | 结果 |
| --- | --- |
| 执行链路 `reset → V1 → V2 → V3 → verify` | 零报错 |
| 结构自检 A1–A8 | 8 / 8 PASS |
| 约束行为验证 B1–B9 | 9 / 9 PASS |
| 种子幂等（重跑两次） | 通过 |
| 测试数据残留 | 0 |

完整输出见 `db/verify/verify_result.txt`。

> 验证环境：MySQL 8.0.41，utf8mb4 / utf8mb4_unicode_ci，时区 +00:00。
> 验证方式为独立临时实例（未使用开发机既有 MySQL 安装），保证结论干净可复现。
