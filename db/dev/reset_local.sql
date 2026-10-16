-- =====================================================================
-- reset_local.sql  ⚠️ 仅限本地开发库 ⚠️
-- =====================================================================
-- 作用：把 10 张表**全部删除**，方便本地从零重跑 V1 → V2 → V3。
--
-- 🚫 绝对不要在共享库 / 演示库 / 任何有人用过的库上执行本文件。
-- 🚫 不要把本文件写进 Flyway 自动迁移目录（它不在 db/migration 下就是为了这个）。
-- 🚫 执行前先确认 DATABASE() 是你自己的本地库：
--        SELECT DATABASE();
--
-- 为什么不用 DROP TABLE IF EXISTS 直接删：
--   sys_dept 与 sys_user 之间是**循环外键**（dept.manager_user_id → user，
--   user.company_id/dept_id → dept），直接删会报外键错误。
--   这里先关掉外键检查，整体删完再打开。
-- =====================================================================

SELECT DATABASE() AS current_database_before_reset;

SET FOREIGN_KEY_CHECKS = 0;

DROP TABLE IF EXISTS
  sys_operation_log,
  sys_user_role,
  sys_role_permission,
  sys_session,
  sys_permission,
  sys_role,
  sys_application,
  sys_user,
  sys_dept,
  sys_security_state;

SET FOREIGN_KEY_CHECKS = 1;

-- 确认清空：预期返回 0
SELECT COUNT(*) AS remaining_tables
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('sys_dept','sys_user','sys_role','sys_application',
                     'sys_permission','sys_user_role','sys_role_permission',
                     'sys_session','sys_operation_log','sys_security_state');
