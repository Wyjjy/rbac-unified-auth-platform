-- =====================================================================
-- V1__init_schema.sql
-- 市政公司统一权限管理平台 · 第一阶段（RBAC0）基准建表迁移
-- =====================================================================
-- 来源：开发设计文档 V3.1 §4.13「基准 DDL（新建项目库结构）」
-- 作者：后端 D1
-- 要求：MySQL >= 8.0.16（CHECK 约束需要 8.0.16 才真正生效）
-- 字符集：utf8mb4，中文列 utf8mb4_unicode_ci，编码/工号等 key 列 utf8mb4_bin
--
-- 执行约定（来自文档 §4.13）：
--   1. 本迁移只在**新建空库**时执行一次；后续结构改动一律新增迁移文件，
--      不得用 IF NOT EXISTS 掩盖结构差异。
--   2. 本文件不含 DROP，重复执行会因对象已存在而失败——这是刻意的，
--      避免误在已有库上重跑。本地反复重来请用 db/dev/reset_local.sql。
--   3. 执行完成后必须跑 db/verify/verify_schema.sql 验证 CHECK / 外键 /
--      生成列真的生效（文档明确要求「实现时必须验证」）。
--   4. 表结构与字段在本阶段**冻结**，改动前必须通知 E（分工说明 §二.3）。
--
-- 本文件建 10 张表：
--   sys_dept / sys_user / sys_role / sys_application / sys_permission
--   sys_user_role / sys_role_permission / sys_session
--   sys_operation_log / sys_security_state
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+00:00';

-- ---------------------------------------------------------------------
-- 建库语句：Flyway 需要库已存在，故此处仅作参考，默认不执行。
-- 手动初始化本地库时取消注释即可。
-- ---------------------------------------------------------------------
-- CREATE DATABASE IF NOT EXISTS rbac
--   DEFAULT CHARACTER SET utf8mb4
--   DEFAULT COLLATE utf8mb4_unicode_ci;
-- USE rbac;

-- =====================================================================
-- 1. sys_dept —— 组织节点（树形自关联，含通用字段 C）
-- =====================================================================
-- 要点：
--   · node_key 是全库唯一稳定键；dept_name 不要求唯一（可重名）。
--   · root_guard 是 STORED 生成列，仅用于「全库唯一 ROOT」的唯一索引，
--     不是业务字段、不出现在 VO 里。非 ROOT 行为 NULL，MySQL 唯一索引
--     允许多个 NULL，因此该约束只挡住「第二个 ROOT」。
--   · 仅一个 ROOT：ROOT 的 parent_id 必须为 NULL。
--   · 负责人 manager_user_id 的外键在 sys_user 建表后回填（见文件末尾）。
--   · 建表顺序：先组织（负责人留空）→ 再用户 → 最后 ALTER 补负责人外键。
CREATE TABLE sys_dept (
  id              BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  dept_name       VARCHAR(160) NOT NULL,
  node_key        VARCHAR(160) COLLATE utf8mb4_bin NOT NULL,
  parent_id       BIGINT       NULL,
  node_type       VARCHAR(24)  COLLATE utf8mb4_bin NOT NULL,
  manager_user_id BIGINT       NULL,
  status          TINYINT      NOT NULL DEFAULT 1,
  create_time     DATETIME(3)  NOT NULL,
  update_time     DATETIME(3)  NOT NULL,
  version         BIGINT       NOT NULL DEFAULT 0,
  CHECK (version >= 0),
  root_guard      TINYINT GENERATED ALWAYS AS (CASE WHEN node_type = 'ROOT' THEN 1 ELSE NULL END) STORED,
  UNIQUE KEY uk_dept_node_key   (node_key),
  UNIQUE KEY uk_dept_single_root (root_guard),
  KEY idx_dept_parent_status (parent_id, status),
  FOREIGN KEY (parent_id) REFERENCES sys_dept(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  CHECK (node_type IN ('ROOT','COMPANY','DEPARTMENT','PROJECT_DEPT')),
  CHECK (status IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='组织节点：ROOT/COMPANY/DEPARTMENT/PROJECT_DEPT 四级';

-- =====================================================================
-- 2. sys_user —— 员工与账号（含通用字段 C）
-- =====================================================================
-- 要点：
--   · username = 工号，唯一业务标识，字符串存储、保留前导零、统一大写，
--     发布后不可修改。姓名不唯一，不能作为识别依据。
--   · company_id 指向总公司/分公司节点，dept_id 指向直接所属组织，两条外键。
--   · 跨列 CHECK：ENABLED 状态必须已设密码且已完成首次改密。
--   · 2026-10-15 提醒：本表 CSV 导入时密码列不要写进来，密码一律走
--     A12 重置 / A04 改密流程；导入后统一为 PENDING_ACTIVATION + 无密码。
CREATE TABLE sys_user (
  id                   BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  username             VARCHAR(50)  COLLATE utf8mb4_bin NOT NULL,
  password_hash        VARCHAR(255) NULL,
  real_name            VARCHAR(80)  NOT NULL,
  company_id           BIGINT       NOT NULL,
  dept_id              BIGINT       NOT NULL,
  position_name        VARCHAR(80)  NOT NULL,
  phone_cipher         VARBINARY(256) NULL,
  status               VARCHAR(24)  COLLATE utf8mb4_bin NOT NULL DEFAULT 'PENDING_ACTIVATION',
  must_change_password TINYINT      NOT NULL DEFAULT 1,
  failed_login_count   INT          NOT NULL DEFAULT 0,
  locked_until         DATETIME(3)  NULL,
  create_time          DATETIME(3)  NOT NULL,
  update_time          DATETIME(3)  NOT NULL,
  version              BIGINT       NOT NULL DEFAULT 0,
  CHECK (version >= 0),
  UNIQUE KEY uk_user_username      (username),
  KEY idx_user_company_dept       (company_id, dept_id),
  KEY idx_user_dept_status        (dept_id, status),
  FOREIGN KEY (company_id) REFERENCES sys_dept(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  FOREIGN KEY (dept_id)    REFERENCES sys_dept(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  CHECK (status IN ('ENABLED','DISABLED','PENDING_ACTIVATION')),
  CHECK (must_change_password IN (0,1)),
  CHECK (failed_login_count >= 0),
  CHECK (status <> 'ENABLED' OR (password_hash IS NOT NULL AND must_change_password = 0))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='员工与账号：username 为唯一工号';

-- 组织表的负责人外键必须等 sys_user 建好后再加（循环引用）
ALTER TABLE sys_dept
  ADD CONSTRAINT fk_dept_manager
  FOREIGN KEY (manager_user_id) REFERENCES sys_user(id)
  ON DELETE RESTRICT ON UPDATE RESTRICT;

-- =====================================================================
-- 3. sys_role —— 直接角色（含通用字段 C）
-- =====================================================================
-- 要点：
--   · role_key 稳定且不可改；本阶段**不建** parent_role_id / max_user_count
--     等 RBAC1/RBAC2 预留列，后续用新迁移增加。
--   · PLATFORM_ADMIN 为控制面保留角色，禁止修改、停用或更改其权限集合
--     （该保护在 Service 层实现，数据库层不拦）。
CREATE TABLE sys_role (
  id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  role_name   VARCHAR(80)  NOT NULL,
  role_key    VARCHAR(50)  COLLATE utf8mb4_bin NOT NULL,
  description VARCHAR(300) NULL,
  status      TINYINT      NOT NULL DEFAULT 1,
  create_time DATETIME(3)  NOT NULL,
  update_time DATETIME(3)  NOT NULL,
  version     BIGINT       NOT NULL DEFAULT 0,
  CHECK (version >= 0),
  UNIQUE KEY uk_role_key (role_key),
  CHECK (status IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='直接角色：本阶段不建继承边';

-- =====================================================================
-- 4. sys_application —— 应用（含通用字段 C）
-- =====================================================================
-- 要点：
--   · app_key 只允许 [a-z][a-z0-9_]*（Service 层校验，DB 不做正则）。
--   · 技术管理应用 app_key = 'platform'，禁止通过普通 API 停用或改编码。
--   · ⚠️ 源 Excel 第 15 个应用叫「系统管理后台」，那是**业务应用**，
--     与保留的 platform 应用不是同一个，两者的 app_key 不得重复！
CREATE TABLE sys_application (
  id          BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  app_name    VARCHAR(100) NOT NULL,
  app_key     VARCHAR(32)  COLLATE utf8mb4_bin NOT NULL,
  status      TINYINT      NOT NULL DEFAULT 1,
  create_time DATETIME(3)  NOT NULL,
  update_time DATETIME(3)  NOT NULL,
  version     BIGINT       NOT NULL DEFAULT 0,
  CHECK (version >= 0),
  UNIQUE KEY uk_app_key (app_key),
  CHECK (status IN (0,1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='应用：15 个业务应用 + platform/engineering 技术应用';

-- =====================================================================
-- 5. sys_permission —— 功能点的原子操作（含通用字段 C）
-- =====================================================================
-- 要点：
--   · perm_key 是四段式「应用:模块:功能:操作」，**由服务端生成**，
--     客户端不得提交。业务权限来自 code-mappings.json，技术权限固定。
--   · source_row 仅在来自 Excel 时填写（表头占第 1 行，故 >= 2）；
--     技术控制面权限 source_row 为 NULL。
--   · 固定技术权限不可停用；普通业务权限停用后立即不参与权限计算。
CREATE TABLE sys_permission (
  id                   BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  application_id       BIGINT       NOT NULL,
  module_key           VARCHAR(32)  COLLATE utf8mb4_bin NOT NULL,
  module_name          VARCHAR(100) NOT NULL,
  resource_key         VARCHAR(48)  COLLATE utf8mb4_bin NOT NULL,
  resource_name        VARCHAR(100) NOT NULL,
  resource_description VARCHAR(500) NULL,
  action_code          VARCHAR(32)  COLLATE utf8mb4_bin NOT NULL,
  perm_name            VARCHAR(160) NOT NULL,
  perm_key             VARCHAR(160) COLLATE utf8mb4_bin NOT NULL,
  source_row           INT          NULL,
  status               TINYINT      NOT NULL DEFAULT 1,
  create_time          DATETIME(3)  NOT NULL,
  update_time          DATETIME(3)  NOT NULL,
  version              BIGINT       NOT NULL DEFAULT 0,
  CHECK (version >= 0),
  UNIQUE KEY uk_permission_key   (perm_key),
  UNIQUE KEY uk_permission_tuple (application_id, module_key, resource_key, action_code),
  KEY idx_permission_app_status (application_id, status),
  FOREIGN KEY (application_id) REFERENCES sys_application(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  CHECK (status IN (0,1)),
  CHECK (source_row IS NULL OR source_row >= 2)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='功能点的原子操作：perm_key 四段式，服务端生成';

-- =====================================================================
-- 6. sys_user_role —— 用户角色关系（中间表，无通用字段）
-- =====================================================================
-- 要点：不开放独立行 CRUD，只能通过 A14 完整替换。
--       关系替换会递增目标 sys_user.version。
CREATE TABLE sys_user_role (
  id      BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  role_id BIGINT NOT NULL,
  UNIQUE KEY uk_user_role (user_id, role_id),
  KEY idx_user_role_reverse (role_id),
  FOREIGN KEY (user_id) REFERENCES sys_user(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  FOREIGN KEY (role_id) REFERENCES sys_role(id) ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='用户角色关系：仅允许完整替换';

-- =====================================================================
-- 7. sys_role_permission —— 角色权限关系（中间表，无通用字段）
-- =====================================================================
-- 要点：只存已确认、可在当前范围发布的授权。
--       范围延后（DEFERRED_SCOPE）与待确认（PENDING_CONFIRMATION）的授权
--       保留在离线产物 grant-mappings.csv 中，**不写入本表**。
--       关系替换会递增目标 sys_role.version。
CREATE TABLE sys_role_permission (
  id            BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  role_id       BIGINT NOT NULL,
  permission_id BIGINT NOT NULL,
  UNIQUE KEY uk_role_permission (role_id, permission_id),
  KEY idx_role_permission_reverse (permission_id),
  FOREIGN KEY (role_id)       REFERENCES sys_role(id)       ON DELETE RESTRICT ON UPDATE RESTRICT,
  FOREIGN KEY (permission_id) REFERENCES sys_permission(id) ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='角色权限关系：仅允许完整替换';

-- =====================================================================
-- 8. sys_session —— 可撤销会话（无通用字段）
-- =====================================================================
-- 要点：
--   · 服务端只存 Token 的 SHA-256 摘要（BINARY(32)），明文 Token 永不落库。
--   · 内部会话 UUID 不作为浏览器凭证返回；token_hash 不进入任何 VO。
--   · 绝对 2 小时过期；空闲 30 分钟失效；账号/组织停用、改密、重置均撤销。
--   · 本表归 E（认证门户）使用，D1 只负责建表。
CREATE TABLE sys_session (
  id           CHAR(36)   COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  user_id      BIGINT     NOT NULL,
  token_hash   BINARY(32) NOT NULL,
  restricted   TINYINT    NOT NULL DEFAULT 0,
  created_at   DATETIME(3) NOT NULL,
  expires_at   DATETIME(3) NOT NULL,
  last_seen_at DATETIME(3) NOT NULL,
  revoked_at   DATETIME(3) NULL,
  UNIQUE KEY uk_session_token_hash (token_hash),
  KEY idx_session_user_expiry (user_id, expires_at),
  FOREIGN KEY (user_id) REFERENCES sys_user(id) ON DELETE RESTRICT ON UPDATE RESTRICT,
  CHECK (restricted IN (0,1)),
  CHECK (expires_at > created_at),
  CHECK (last_seen_at >= created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='可撤销会话：仅存 SHA-256 摘要';

-- =====================================================================
-- 9. sys_operation_log —— 审计日志（无通用字段，不可修改）
-- =====================================================================
-- 要点：
--   · user_id / username_snapshot / target_id 均为**快照**，故意不设外键，
--     保证历史记录在实体停用后仍可追溯。
--   · 无 version / update_time，因为本表只允许 INSERT 与 SELECT。
--   · event_type 白名单由 CHECK 强制；新增事件类型必须同步改本约束
--     （已有 22 种：含 A39 追加的 DEMO_SUBMIT）。
--   · 应用身份只授予 INSERT/SELECT 权限，保留清理由独立维护身份执行。
CREATE TABLE sys_operation_log (
  id                BIGINT       NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id           BIGINT       NULL,
  username_snapshot VARCHAR(50)  NULL,
  event_type        VARCHAR(50)  COLLATE utf8mb4_bin NOT NULL,
  target_type       VARCHAR(32)  COLLATE utf8mb4_bin NULL,
  target_id         VARCHAR(64)  NULL,
  http_method       VARCHAR(8)   COLLATE utf8mb4_bin NOT NULL,
  request_path      VARCHAR(200) NOT NULL,
  request_id        VARCHAR(64)  NOT NULL,
  result            VARCHAR(16)  COLLATE utf8mb4_bin NOT NULL,
  reason_code       VARCHAR(48)  NOT NULL,
  source_ip         VARCHAR(45)  NULL,
  details           JSON         NULL,
  create_time       DATETIME(3)  NOT NULL,
  KEY idx_log_time_id    (create_time, id),
  KEY idx_log_user_time  (user_id, create_time),
  KEY idx_log_request    (request_id),
  CHECK (result IN ('SUCCESS','FAILURE')),
  CHECK (event_type IN (
    'LOGIN','LOGOUT',
    'USER_CREATE','USER_UPDATE','USER_STATUS','PASSWORD_RESET',
    'PASSWORD_CHANGE','USER_ROLE_ASSIGN',
    'ROLE_CREATE','ROLE_UPDATE','ROLE_STATUS','ROLE_PERMISSION_ASSIGN',
    'DEPT_CREATE','DEPT_UPDATE','DEPT_STATUS',
    'APP_CREATE','APP_UPDATE','APP_STATUS',
    'PERMISSION_CREATE','PERMISSION_STATUS',
    'AUTHZ_DENY','DEMO_SUBMIT'
  )),
  CHECK (target_type IS NULL OR target_type IN ('USER','ROLE','DEPT','APP','PERMISSION','SESSION')),
  CHECK (http_method IN ('GET','POST','PUT','PATCH','DELETE'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='审计日志：只允许 INSERT/SELECT，主体与对象为快照';

-- =====================================================================
-- 10. sys_security_state —— 安全配置写入串行点（单行锁表）
-- =====================================================================
-- 要点（全系统最关键的一张表）：
--   · 全表只有一行（id = 1，由 CHECK + 主键双重保证）。
--   · 所有管理写操作、密码重置、本人改密，以及签发/撤销会话的
--     登录与退出事务，**第一句 SQL 必须是**：
--         SELECT * FROM sys_security_state WHERE id = 1 FOR UPDATE;
--     它把全系统的写操作强行排成一队，是并发控制的根基。
--   · policy_version 只在「组织/账号状态/资料归属/角色/应用/权限/关系」
--     变更时递增；会话签发撤销、登录计数维护**不**递增（§6.5 例外）。
--   · 种子行的写入见 db/seed/V2__seed_security_state.sql。
CREATE TABLE sys_security_state (
  id             SMALLINT    NOT NULL DEFAULT 1 PRIMARY KEY,
  policy_version BIGINT      NOT NULL DEFAULT 1,
  update_time    DATETIME(3) NOT NULL,
  CHECK (id = 1),
  CHECK (policy_version > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='安全配置写入串行点：单行锁表';

-- =====================================================================
-- 建表完成。接下来依次执行：
--   db/seed/V2__seed_security_state.sql          初始化单行锁
--   db/verify/verify_schema.sql                  验证约束真的生效
--   （应用与权限导入脚本产出的种子见 tools/import/）
-- =====================================================================
