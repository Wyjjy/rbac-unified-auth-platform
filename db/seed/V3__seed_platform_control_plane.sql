-- =====================================================================
-- V3__seed_platform_control_plane.sql
-- 固定配置种子：技术控制面（platform / engineering 应用 + 25 条技术权限
--                + PLATFORM_ADMIN 保留角色及其权限绑定）
-- =====================================================================
-- 来源：开发设计文档 V3.1 附录 B「权限 key 常量清单（RBAC0）」+ §8.1 + §10.1
-- 作者：后端 D1
--
-- 为什么需要本文件：
--   platform:* 这 23 条技术权限**不来自 Excel**，是系统固定的控制面权限，
--   source_row 为 NULL。没有它们，任何人都进不了管理后台，A07–A37 全部 403。
--   §7.5 的执行顺序也把「控制面管理员角色（PLATFORM_ADMIN）」单列为一步，
--   与原五类业务角色分开。
--
-- 本文件只做「固定配置」，不做业务数据：
--   ✅ platform / engineering 两个技术应用
--   ✅ 23 条 platform:* 技术管理权限
--   ✅ 2 条 engineering:demo:project:* 演示权限（额外测试权限，不映射真实功能行）
--   ✅ PLATFORM_ADMIN 角色 + 绑定全部 platform:*
--   ❌ 不创建原五类业务角色（SYS_ADMIN 等）——由 Excel 导入脚本负责
--   ❌ 不创建业务权限——由 code-mappings.json 导入
--   ❌ 不把 engineering:* 绑给 PLATFORM_ADMIN（§8.1 明确 PLATFORM_ADMIN
--      只拿「所有 platform:* 码的去重集合」；演示权限由角色单独授予，见 T06）
--
-- 幂等性：全部使用 INSERT IGNORE + 按 key 解析 ID，重跑不产生重复、
--         不覆盖已有的人工调整。
--
-- ⚠️ 若组长已在仓库中提供了等价的控制面种子，请**只保留一份**并与 E 确认，
--    不要两处都执行（会因唯一键冲突被 IGNORE 掉，但会造成维护歧义）。
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+00:00';

-- ---------------------------------------------------------------------
-- 1. 技术应用
--    platform    ：技术管理应用，禁止通过普通 API 停用或改编码
--    engineering ：合成演示应用，承载 A38/A39 的额外测试权限
--    注意：源 Excel 里的「系统管理后台」是**业务应用**，不是 platform，
--          两者的 app_key 绝不能相同（导入脚本生成编码时需避开这两个保留值）。
-- ---------------------------------------------------------------------
INSERT IGNORE INTO sys_application (app_name, app_key, status, create_time, update_time, version)
VALUES
  ('技术管理平台', 'platform',    1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0),
  ('工程演示系统', 'engineering', 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);

-- ---------------------------------------------------------------------
-- 2. 技术权限（共 25 条）
--    perm_key 严格取自附录 B，一字不改；source_row 一律 NULL。
--    分批按应用插入，避免命令行过长。
-- ---------------------------------------------------------------------

-- 2.1 用户管理 platform:user:account:*（6 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'user' AS mk, '用户管理' AS mn, 'account' AS rk, '账号' AS rn, 'view'           AS ac, '账号查看'     AS pn, 'platform:user:account:view'           AS pk
  UNION ALL SELECT 'user','用户管理','account','账号','create',        '账号新增',     'platform:user:account:create'
  UNION ALL SELECT 'user','用户管理','account','账号','edit',          '账号编辑',     'platform:user:account:edit'
  UNION ALL SELECT 'user','用户管理','account','账号','status',        '账号状态变更', 'platform:user:account:status'
  UNION ALL SELECT 'user','用户管理','account','账号','reset_password','账号重置密码', 'platform:user:account:reset_password'
  UNION ALL SELECT 'user','用户管理','account','账号','assign_role',   '账号分配角色', 'platform:user:account:assign_role'
) t
JOIN sys_application a ON a.app_key = 'platform';

-- 2.2 部门管理 platform:org:department:*（4 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'org' AS mk, '组织管理' AS mn, 'department' AS rk, '部门' AS rn, 'view'   AS ac, '部门查看'     AS pn, 'platform:org:department:view'   AS pk
  UNION ALL SELECT 'org','组织管理','department','部门','create', '部门新增',     'platform:org:department:create'
  UNION ALL SELECT 'org','组织管理','department','部门','edit',   '部门编辑',     'platform:org:department:edit'
  UNION ALL SELECT 'org','组织管理','department','部门','status', '部门状态变更', 'platform:org:department:status'
) t
JOIN sys_application a ON a.app_key = 'platform';

-- 2.3 角色管理 platform:role:role:*（5 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'role' AS mk, '角色管理' AS mn, 'role' AS rk, '角色' AS rn, 'view'   AS ac, '角色查看'     AS pn, 'platform:role:role:view'   AS pk
  UNION ALL SELECT 'role','角色管理','role','角色','create', '角色新增',     'platform:role:role:create'
  UNION ALL SELECT 'role','角色管理','role','角色','edit',   '角色编辑',     'platform:role:role:edit'
  UNION ALL SELECT 'role','角色管理','role','角色','status', '角色状态变更', 'platform:role:role:status'
  UNION ALL SELECT 'role','角色管理','role','角色','grant',  '角色授权',     'platform:role:role:grant'
) t
JOIN sys_application a ON a.app_key = 'platform';

-- 2.4 应用管理 platform:app:application:*（4 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'app' AS mk, '应用管理' AS mn, 'application' AS rk, '应用' AS rn, 'view'   AS ac, '应用查看'     AS pn, 'platform:app:application:view'   AS pk
  UNION ALL SELECT 'app','应用管理','application','应用','create', '应用新增',     'platform:app:application:create'
  UNION ALL SELECT 'app','应用管理','application','应用','edit',   '应用编辑',     'platform:app:application:edit'
  UNION ALL SELECT 'app','应用管理','application','应用','status', '应用状态变更', 'platform:app:application:status'
) t
JOIN sys_application a ON a.app_key = 'platform';

-- 2.5 权限点管理 platform:resource:permission:*（3 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'resource' AS mk, '权限点管理' AS mn, 'permission' AS rk, '权限点' AS rn, 'view'   AS ac, '权限点查看'     AS pn, 'platform:resource:permission:view'   AS pk
  UNION ALL SELECT 'resource','权限点管理','permission','权限点','create', '权限点新增',     'platform:resource:permission:create'
  UNION ALL SELECT 'resource','权限点管理','permission','权限点','status', '权限点状态变更', 'platform:resource:permission:status'
) t
JOIN sys_application a ON a.app_key = 'platform';

-- 2.6 日志审计 platform:audit:log:*（1 条）
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, 'audit','日志审计','log','操作日志', NULL, 'view','操作日志查看',
       'platform:audit:log:view', NULL, 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM sys_application a WHERE a.app_key = 'platform';

-- 2.7 演示端点 engineering:demo:project:*（2 条）
--     额外测试权限，不映射真实功能行；供 T06「两个角色分别授查看与提交」使用。
INSERT IGNORE INTO sys_permission
  (application_id, module_key, module_name, resource_key, resource_name,
   resource_description, action_code, perm_name, perm_key, source_row, status,
   create_time, update_time, version)
SELECT a.id, t.mk, t.mn, t.rk, t.rn, NULL, t.ac, t.pn, t.pk, NULL, 1,
       UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM (
  SELECT 'demo' AS mk, '演示模块' AS mn, 'project' AS rk, '合成项目' AS rn, 'view'   AS ac, '合成项目查看' AS pn, 'engineering:demo:project:view'   AS pk
  UNION ALL SELECT 'demo','演示模块','project','合成项目','submit', '合成项目提交', 'engineering:demo:project:submit'
) t
JOIN sys_application a ON a.app_key = 'engineering';

-- ---------------------------------------------------------------------
-- 3. PLATFORM_ADMIN 保留角色
--    §8.1：显式获得系统全部技术管理权限，即目录中所有 platform:* 码的
--    去重集合。该角色禁止修改、停用或更改其权限集合（Service 层强制）。
-- ---------------------------------------------------------------------
INSERT IGNORE INTO sys_role (role_name, role_key, description, status, create_time, update_time, version)
VALUES ('控制面管理员', 'PLATFORM_ADMIN',
        '系统保留角色：拥有全部 platform:* 技术管理权限，禁止修改、停用或更改其权限集合',
        1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);

-- 绑定全部 platform:* 权限（23 条）
-- 用 SUBSTRING_INDEX 取 perm_key 第一段做匹配，避免 LIKE 与通配符。
INSERT IGNORE INTO sys_role_permission (role_id, permission_id)
SELECT r.id, p.id
FROM sys_role r
JOIN sys_permission p ON SUBSTRING_INDEX(p.perm_key, ':', 1) = 'platform'
WHERE r.role_key = 'PLATFORM_ADMIN';

-- ---------------------------------------------------------------------
-- 4. 自检：预期 4 个数字分别为 2 / 23 / 2 / 23
--    若 platform_perms 或 platform_admin_grants 小于 23，说明应用或权限
--    插入不完整，不要继续往下做认证功能。
-- ---------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM sys_application
    WHERE app_key IN ('platform','engineering'))                              AS tech_apps,
  (SELECT COUNT(*) FROM sys_permission
    WHERE SUBSTRING_INDEX(perm_key, ':', 1) = 'platform')                     AS platform_perms,
  (SELECT COUNT(*) FROM sys_permission
    WHERE SUBSTRING_INDEX(perm_key, ':', 1) = 'engineering')                  AS engineering_perms,
  (SELECT COUNT(*) FROM sys_role_permission rp
     JOIN sys_role r ON r.id = rp.role_id
    WHERE r.role_key = 'PLATFORM_ADMIN')                                      AS platform_admin_grants;
