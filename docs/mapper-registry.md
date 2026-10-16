# Mapper 方法登记表

> 负责人：后端 D1 ｜ 版本：第一阶段 v1 ｜ 登记日期：2026-10-15
>
> 依据：《开发设计文档 V3.1》§10.1 端点目录、§11.2 Mapper 契约、§4 数据库设计（落地为 `db/migration/V1__init_schema.sql`，17 项校验 PASS）。
>
> **约定（§11.2）**：方法名、SQL、返回类型以本表为准，代码前统一登记；部门平面列表 + Service 组树；**所有条件更新必须带 `AND version = #{expectedVersion}` 并 `SET version = version + 1`**。改方法先改本表并同步 E。

通用约定：

- 所有 Mapper 为 MyBatis 接口 + XML，XML 放 `resources/mapper/`。
- Entity 类 `SysXxx` 对应 §11.3 清单，禁止作为 API 响应直接返回。
- 写事务固定流程（§6.1）：`SecurityStateMapper.lockSecurityState()` → 锁目标实体（`...ByIdForUpdate`）→ version 比对 → 写 → 同事务审计。带 🔒 标记的方法即锁点。
- 分页统一 `LIMIT #{offset}, #{limit}`，`offset/limit` 由 Service 从 PageQuery 换算，Mapper 不解析分页对象。

---

## 1. SecurityStateMapper（🔒 锁流程串行点，E 的写操作也要用）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `SysSecurityState lockForUpdate()` | `SELECT ... WHERE id=1 FOR UPDATE` | 所有管理写事务第一步 | 🔒 **写事务必须第一个调用**；行锁持有到事务结束 |
| `SysSecurityState get()` | 读单行（无锁） | 登录策略版本读取 | |
| `int updatePolicyVersion(@Param("newVersion") long newVersion)` | `UPDATE sys_security_state SET policy_version=#{newVersion}, update_time=UTC_TIMESTAMP(3) WHERE id=1` | 写事务收尾 | 与业务写同事务提交 |

## 2. UserMapper（A07–A12）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `SysUser selectByUsername(@Param("username") String username)` | 按**归一后工号**精确查询 | 登录(E)、A09 查重、A34 无关 | `username` 列为 `utf8mb4_bin`，大小写敏感 |
| `SysUser selectById(@Param("id") Long id)` | 按 ID 查 | A08/A10/A11/A12/A13/A14 | |
| `List<SysUser> selectPage(@Param("keyword") String keyword, @Param("deptId") Long deptId, @Param("status") String status, @Param("offset") long offset, @Param("limit") int limit)` | A07 列表 | A07 | keyword 匹配 `username OR real_name`（LIKE 前缀+%，keyword 已在 Service 转义） |
| `long countPage(同上四个条件参数)` | A07 总数 | A07 | 与 selectPage 条件必须逐字一致 |
| `int insert(SysUser user)` | A09 | A09 | 初始 `PENDING_ACTIVATION`、`password_hash=NULL` |
| `int updateById(SysUser user)` | A10 全字段更新 | A10 | XML 里 `WHERE id=#{id} AND version=#{version}`，`SET version=version+1` |
| `int updateStatus(@Param("id") Long id, @Param("status") String status, @Param("expectedVersion") long expectedVersion)` | A11/A12 状态流转 | A11/A12 | 返回 0 = 版本冲突（Service 转 409/412） |

## 3. UserRoleMapper（A13–A14）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<UserRoleItem> selectByUserId(@Param("userId") Long userId)` | 联 `sys_role` 返回当前角色 | A13 | 不伪造继承角色（本阶段无继承边） |
| `int deleteByUserId(@Param("userId") Long userId)` | 完整替换第一步 | A14 | 🔒 在 `assignRoles` 锁流程内执行 |
| `int batchInsert(@Param("list") List<SysUserRole> list)` | 完整替换第二步 | A14 | 空列表跳过，不发 SQL |
| `List<Long> selectRoleIdsByUserId(@Param("userId") Long userId)` | 检查现有角色（增量校验用） | A14、E 的预配置校验 | |

## 4. DeptMapper（A15–A19，含 A10 的部门归属校验）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<SysDept> selectFlatList(@Param("rootId") Long rootId, @Param("includeDisabled") boolean includeDisabled)` | **平面列表**（树由 Service 组装） | A15 | 不在 SQL 里递归；rootId=NULL 时从 ROOT 起 |
| `SysDept selectById(@Param("id") Long id)` | 按 ID 查 | A16/A18/A19、A10 | |
| `SysDept selectByNodeKey(@Param("nodeKey") String nodeKey)` | 按 node_key 查（bin 精确） | A17 查重 | |
| `int insert(SysDept dept)` | A17 | A17 | 🔒 走写事务流程；node_key 唯一由 DB 兜底 |
| `int updateById(SysDept dept)` | A18（不改父节点） | A18 | XML 中 UPDATE 列表**不含 parent_id / node_key** |
| `int updateStatus(@Param("id") Long id, @Param("status") Integer status, @Param("expectedVersion") long expectedVersion)` | A19 | A19 | 停用后是否级联显示由 Service/查询参数决定，**不批量改子节点状态** |
| `List<Long> selectDescendantIds(@Param("rootId") Long rootId)` | 子树 id 集合（内存组树后由 Service 递归或一次闭包查询） | A19 affectedUserCount、停用撤会话 | MySQL 8 支持 `WITH RECURSIVE`；返回含自身 |
| `long countDistinctUsers(@Param("companyIds") List<Long> companyIds, @Param("deptIds") List<Long> deptIds)` | A19 `affectedUserCount` | A19 | `WHERE company_id IN(...) OR dept_id IN(...)` 按 user 去重 |

## 5. RoleMapper（A20–A24）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<SysRole> selectPage(@Param("keyword") String keyword, @Param("status") Integer status, @Param("offset") long offset, @Param("limit") int limit)` | A20 | A20 | keyword 匹配 `role_name OR role_key` |
| `long countPage(同上)` | A20 总数 | A20 | |
| `SysRole selectById(@Param("id") Long id)` | A21/A23/A24/A26 | 多 | 🔒 A23/A24/A26 先 `selectByIdForUpdate`（见下） |
| `SysRole selectByIdForUpdate(@Param("id") Long id)` | 写事务锁实体 | A23/A24/A26 | 🔒 `SELECT ... FOR UPDATE` |
| `SysRole selectByRoleKey(@Param("roleKey") String roleKey)` | A22 查重 / PLATFORM_ADMIN 识别 | A22 | `role_key` 为 `utf8mb4_bin` |
| `int insert(SysRole role)` | A22 | A22 | 初始无权限、不分配给创建者 |
| `int updateById(SysRole role)` | A23 | A23 | **`role_key` 不可变更**：XML UPDATE 列表不含 role_key |
| `int updateStatus(@Param("id") Long id, @Param("status") Integer status, @Param("expectedVersion") long expectedVersion)` | A24 | A24 | 停用保留关系；PLATFORM_ADMIN 保护在 Service |

## 6. RolePermissionMapper（A25–A26；E 的有效权限计算也用）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<RolePermissionItem> selectByRoleId(@Param("roleId") Long roleId)` | 联 `sys_permission`+`sys_application` | A25 | 含应用/权限启用状态供 VO 展示 |
| `int deleteByRoleId(@Param("roleId") Long roleId)` | 完整替换第一步 | A26 | 🔒 锁流程内 |
| `int batchInsert(@Param("list") List<SysRolePermission> list)` | 完整替换第二步 | A26 | 新关联须权限与应用均启用（Service 校验） |
| `List<EffectivePermission> selectEffectiveByUserId(@Param("userId") Long userId)` | 用户有效权限（全部启用链路） | **E 的 A05/A06** | `JOIN user_role→role→role_permission→permission→application`，全部 `status=启用` 且会话未受限；5 个 status 同时为 1 的并集去重 |

## 7. ApplicationMapper（A27–A31；E 的门户卡片 A05 复用）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<SysApplication> selectPage(@Param("keyword") String keyword, @Param("status") Integer status, @Param("offset") long offset, @Param("limit") int limit)` | A27 | A27 | |
| `long countPage(同上)` | A27 总数 | A27 | |
| `SysApplication selectById(@Param("id") Long id)` | A28/A30/A31 | 多 | |
| `SysApplication selectByAppKey(@Param("appKey") String appKey)` | A29 查重 / platform 保护识别 | A29 | `app_key` 为 `utf8mb4_bin` |
| `int insert(SysApplication app)` | A29 | A29 | 不自动授权限 |
| `int updateById(SysApplication app)` | A30 | A30 | version 条件 |
| `int updateStatus(@Param("id") Long id, @Param("status") Integer status, @Param("expectedVersion") long expectedVersion)` | A31 | A31 | 停用使下属权限失效 = 查询侧 JOIN 过滤，**不批量改权限表** |

## 8. PermissionMapper（A32–A35）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `List<SysPermission> selectPage(@Param("applicationId") Long applicationId, @Param("keyword") String keyword, @Param("status") Integer status, @Param("offset") long offset, @Param("limit") int limit)` | A32 | A32 | keyword 匹配 `perm_name OR perm_key` |
| `long countPage(同上)` | A32 总数 | A32 | |
| `SysPermission selectById(@Param("id") Long id)` | A33/A34/A35 | 多 | |
| `SysPermission selectByPermKey(@Param("permKey") String permKey)` | A34 同编码名称一致性检查 | A34 | `perm_key` 为 `utf8mb4_bin`；四段码由 Service 生成 |
| `int insert(SysPermission perm)` | A34 | A34 | `source_row` 仅追溯可空 |
| `int updateStatus(@Param("id") Long id, @Param("status") Integer status, @Param("expectedVersion") long expectedVersion)` | A35 | A35 | 固定技术权限（`platform:*`/`engineering:demo:*`）不可停用——Service 判 |

## 9. SessionMapper（登录/登出是 E 的；**D 的停用撤会话用后两个方法**）

| 方法签名 | 用途 | 服务接口 | 归属 | 备注 |
| --- | --- | --- | --- | --- |
| `int insert(SysSession session)` | 签发会话 | A01 | E | `token_hash` 存 SHA-256 摘要 |
| `SysSession selectByTokenHash(@Param("tokenHash") byte[] tokenHash)` | 认证过滤器 | 全部受保护接口 | E | |
| `int touchLastSeen(@Param("tokenHash") byte[] tokenHash, @Param("now") LocalDateTime now)` | 更新活跃时间 | 每请求 | E | **必须带 `AND revoked_at IS NULL`**，不允许覆盖撤销字段 |
| `int revokeByTokenHash(@Param("tokenHash") byte[] tokenHash)` | 登出撤销 | A02 | E | `SET revoked_at=... WHERE token_hash=? AND revoked_at IS NULL` |
| `int revokeAllByUserId(@Param("userId") Long userId)` | 单用户全部撤销 | A04(E)/A10/A11 | **D** | 同上条件写法 |
| `int revokeAllByUserIds(@Param("userIds") List<Long> userIds)` | 批量撤销（部门子树停用） | A19 | **D** | 列表由 DeptMapper.selectDescendantIds + 用户查询得出 |

## 10. OperationLogMapper（A36–A37 + 审计写入）

| 方法签名 | 用途 | 服务接口 | 备注 |
| --- | --- | --- | --- |
| `int insert(SysOperationLog log)` | 写审计 | 所有写接口（同事务） | **只 INSERT/SELECT**；D 的成功审计（MANDATORY 同事务）与 E 的失败审计（REQUIRES_NEW）都用它 |
| `LogWithUserVO selectById(@Param("id") Long id)` | A37 | A37 | 无 ETag（不可修改） |
| `List<SysOperationLog> selectPage(@Param("from") LocalDateTime from, @Param("to") LocalDateTime to, @Param("userId") Long userId, @Param("eventType") String eventType, @Param("result") String result, @Param("requestId") String requestId, @Param("offset") long offset, @Param("limit") int limit)` | A36 | A36 | `from <= create_time < to`；排序 `create_time DESC, id DESC`；时间必填与跨度 ≤31 天在 Service/Controller 校验 |
| `long countPage(同上)` | A36 总数 | A36 | |

---

## 与 E 的复用清单（谁依赖谁的 Mapper 方法）

| E 的功能 | 复用 D 的方法 |
| --- | --- |
| A05 门户卡片 / A06 有效权限 | `RolePermissionMapper.selectEffectiveByUserId` |
| A04 改密撤会话 | `SessionMapper.revokeAllByUserId` |
| 登录查用户 | `UserMapper.selectByUsername` |
| 锁流程模板 | `SecurityStateMapper.lockForUpdate` + 各 `...ForUpdate` |

**变更纪律**：任何方法签名/SQL/返回类型的修改，先改本表 → 知会 E → 再动代码。Mapper XML 的 SQL 与本表一一对应，MR 里必须能对着本表逐条核对。
