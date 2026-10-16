-- =====================================================================
-- verify_schema.sql
-- 建表后的结构自检 + 约束行为验证
-- =====================================================================
-- 用途：文档 §4.13 明确要求「实现时必须验证迁移、外键和 CHECK 实际生效」。
--       MySQL 8.0.16 以下版本会**静默忽略** CHECK 约束（只解析不执行），
--       所以这一步不能跳。本脚本把「约束到底有没有生效」变成可判定的 PASS/FAIL。
--
-- 用法：在目标库中直接执行本文件，逐条看 verdict 列是否为 PASS。
--       执行顺序必须是 V1 建表 → V2 安全状态种子 → V3 控制面种子 → 本文件
--       （B4 依赖 V3 建出的 platform 应用，否则那条测试会空跑）。
--
-- 安全性：Section B 的全部写入都在一个事务里，结尾无条件 ROLLBACK，不留数据。
--
--   执行示例：
--     mysql -h 127.0.0.1 -P 3306 -u root --default-character-set=utf8mb4 \
--           rbac < db/verify/verify_schema.sql
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+00:00';

-- =====================================================================
-- Section A · 结构自检（只读，全部应为 PASS）
-- =====================================================================

SELECT check_item, expected, actual, CASE WHEN expected = actual THEN 'PASS' ELSE 'FAIL' END AS verdict
FROM (
  SELECT 'A1 表数量' AS check_item, '10' AS expected,
         CAST((SELECT COUNT(*) FROM information_schema.TABLES
               WHERE TABLE_SCHEMA = DATABASE()
                 AND TABLE_NAME IN ('sys_dept','sys_user','sys_role','sys_application',
                                    'sys_permission','sys_user_role','sys_role_permission',
                                    'sys_session','sys_operation_log','sys_security_state'))
              AS CHAR) AS actual
  UNION ALL
  SELECT 'A2 CHECK 约束数',
         '24',
         CAST((SELECT COUNT(*) FROM information_schema.CHECK_CONSTRAINTS
               WHERE CONSTRAINT_SCHEMA = DATABASE()) AS CHAR)
  UNION ALL
  SELECT 'A3 外键数',
         '10',
         CAST((SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
               WHERE CONSTRAINT_SCHEMA = DATABASE() AND CONSTRAINT_TYPE = 'FOREIGN KEY') AS CHAR)
  UNION ALL
  SELECT 'A4 root_guard 生成列存在',
         '1',
         CAST((SELECT COUNT(*) FROM information_schema.COLUMNS
               WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sys_dept'
                 AND COLUMN_NAME = 'root_guard' AND GENERATION_EXPRESSION IS NOT NULL) AS CHAR)
  UNION ALL
  SELECT 'A5 node_key 排序规则为 bin',
         '1',
         CAST((SELECT COUNT(*) FROM information_schema.COLUMNS
               WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sys_dept'
                 AND COLUMN_NAME = 'node_key' AND COLLATION_NAME = 'utf8mb4_bin') AS CHAR)
  UNION ALL
  SELECT 'A6 username 排序规则为 bin',
         '1',
         CAST((SELECT COUNT(*) FROM information_schema.COLUMNS
               WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sys_user'
                 AND COLUMN_NAME = 'username' AND COLLATION_NAME = 'utf8mb4_bin') AS CHAR)
  UNION ALL
  SELECT 'A7 安全状态行数',
         '1',
         CAST((SELECT COUNT(*) FROM sys_security_state) AS CHAR)
  UNION ALL
  SELECT 'A8 无 DELETE 遗留的物理删除外键(应为0)',
         '0',
         CAST((SELECT COUNT(*) FROM information_schema.REFERENTIAL_CONSTRAINTS
               WHERE CONSTRAINT_SCHEMA = DATABASE()
                 AND DELETE_RULE NOT IN ('RESTRICT','NO ACTION')) AS CHAR)
) a
ORDER BY check_item;

-- =====================================================================
-- Section B · 约束行为验证（负向测试）
-- =====================================================================
-- 为什么需要这节：Section A 只证明「约束被建出来了」，不证明「约束真的拦得住」。
--   MySQL 在批处理（mysql < file.sql）模式下**遇到第一个错误就中止整个脚本**，
--   所以不能简单地一条条 INSERT 去撞约束——那样脚本会停在第一行红色 ERROR 上。
--   这里的做法：把每条「预期失败的写入」交给存储过程 sp_expect_blocked 执行，
--   过程内用 EXIT HANDLER FOR SQLEXCEPTION 捕获异常：
--       抛异常  → 说明约束生效 → 记 PASS
--       没抛异常 → 说明约束失效 → 记 FAIL
--   结果写进 MyISAM 临时表（不参与事务，ROLLBACK 也不会丢），最后统一输出。
--
-- 前置假设：本脚本在「刚跑完 V1→V2→V3 的干净库」上执行（sys_dept 为空）。
-- =====================================================================

DROP TEMPORARY TABLE IF EXISTS verify_blocked;
CREATE TEMPORARY TABLE verify_blocked (
  check_item VARCHAR(100) NOT NULL,
  verdict    VARCHAR(10)  NOT NULL
) ENGINE = MyISAM;

DROP PROCEDURE IF EXISTS sp_expect_blocked;
DELIMITER $$
CREATE PROCEDURE sp_expect_blocked(IN p_item VARCHAR(100), IN p_sql TEXT)
BEGIN
  -- 只要写入被数据库拒绝（唯一键 / CHECK / 外键），就判定为「成功拦下」
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    INSERT INTO verify_blocked VALUES (p_item, 'PASS');
  END;

  SET @v_sql = p_sql;
  PREPARE v_stmt FROM @v_sql;
  EXECUTE v_stmt;
  DEALLOCATE PREPARE v_stmt;

  -- 能走到这里说明写入成功了，即约束没拦住
  INSERT INTO verify_blocked VALUES (p_item, 'FAIL');
END$$
DELIMITER ;

START TRANSACTION;

-- 基准数据：一个合法的 ROOT（B1 需要一个「已存在的 ROOT」来制造唯一键冲突）
INSERT IGNORE INTO sys_dept (dept_name, node_key, parent_id, node_type, manager_user_id,
                             status, create_time, update_time, version)
VALUES ('_verify_root', '__VERIFY_ROOT__', NULL, 'ROOT', NULL,
        1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0);

-- B1：再插一个 ROOT，应被 uk_dept_single_root（唯一索引 + root_guard 生成列）挡住
CALL sp_expect_blocked('B1 第二个 ROOT 被挡',
  'INSERT INTO sys_dept (dept_name,node_key,parent_id,node_type,manager_user_id,status,create_time,update_time,version)
   VALUES (''_verify_root2'',''__VERIFY_ROOT2__'',NULL,''ROOT'',NULL,1,UTC_TIMESTAMP(3),UTC_TIMESTAMP(3),0)');

-- B2：node_type 非法值，应被 CHECK 挡住
CALL sp_expect_blocked('B2 非法 node_type 被挡',
  'INSERT INTO sys_dept (dept_name,node_key,parent_id,node_type,manager_user_id,status,create_time,update_time,version)
   VALUES (''_verify_bad'',''__VERIFY_BAD__'',NULL,''NOT_A_TYPE'',NULL,1,UTC_TIMESTAMP(3),UTC_TIMESTAMP(3),0)');

-- B3：ENABLED 但 password_hash 为 NULL，应被跨列 CHECK 挡住
CALL sp_expect_blocked('B3 ENABLED 无密码被挡',
  'INSERT INTO sys_user (username,password_hash,real_name,company_id,dept_id,position_name,phone_cipher,status,must_change_password,failed_login_count,locked_until,create_time,update_time,version)
   SELECT ''__VERIFY_USER__'',NULL,''验证用'',d.id,d.id,''测试岗'',NULL,''ENABLED'',1,0,NULL,UTC_TIMESTAMP(3),UTC_TIMESTAMP(3),0
   FROM sys_dept d WHERE d.node_key = ''__VERIFY_ROOT__''');

-- B4：source_row = 1（表头行），应被 CHECK 挡住
CALL sp_expect_blocked('B4 source_row=1 被挡',
  'INSERT INTO sys_permission (application_id,module_key,module_name,resource_key,resource_name,resource_description,action_code,perm_name,perm_key,source_row,status,create_time,update_time,version)
   SELECT a.id,''v'',''验证'',''r'',''资源'',NULL,''view'',''验证查看'',''verify:v:r:view'',1,1,UTC_TIMESTAMP(3),UTC_TIMESTAMP(3),0
   FROM sys_application a WHERE a.app_key = ''platform''');

-- B5：负 version，应被 CHECK 挡住
CALL sp_expect_blocked('B5 负 version 被挡',
  'INSERT INTO sys_role (role_name,role_key,description,status,create_time,update_time,version)
   VALUES (''验证角色'',''__VERIFY_ROLE__'',NULL,1,UTC_TIMESTAMP(3),UTC_TIMESTAMP(3),-1)');

-- B6：operation_log 未登记的 event_type，应被 CHECK 挡住
CALL sp_expect_blocked('B6 未登记 event_type 被挡',
  'INSERT INTO sys_operation_log (user_id,username_snapshot,event_type,target_type,target_id,http_method,request_path,request_id,result,reason_code,source_ip,details,create_time)
   VALUES (NULL,NULL,''NOT_A_REAL_EVENT'',NULL,NULL,''GET'',''/verify'',''verify-req'',''SUCCESS'',''OK'',NULL,NULL,UTC_TIMESTAMP(3))');

-- B7：sys_security_state 插第二行（id=2），应被 CHECK (id = 1) 挡住
CALL sp_expect_blocked('B7 第二行安全状态被挡',
  'INSERT INTO sys_security_state (id,policy_version,update_time)
   VALUES (2,1,UTC_TIMESTAMP(3))');

-- B8：删除一个仍被 sys_role_permission 引用的角色（V3 种下的 PLATFORM_ADMIN），
--     应被外键 ON DELETE RESTRICT 挡住——这是「角色只允许停用、不允许物理删除」的底层保障
CALL sp_expect_blocked('B8 被授权引用的角色禁止删除',
  'DELETE FROM sys_role WHERE role_key = ''PLATFORM_ADMIN''');

-- B9：删除一个仍有子部门的部门，应被 sys_dept.parent_id 自引用外键挡住
INSERT INTO sys_dept (dept_name, node_key, parent_id, node_type, manager_user_id,
                      status, create_time, update_time, version)
SELECT '_verify_child', '__VERIFY_CHILD__', d.id, 'DEPARTMENT', NULL,
       1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3), 0
FROM sys_dept d WHERE d.node_key = '__VERIFY_ROOT__';

CALL sp_expect_blocked('B9 有子部门的节点禁止删除',
  'DELETE FROM sys_dept WHERE node_key = ''__VERIFY_ROOT__''');

ROLLBACK;

-- 汇总：B1–B9 必须全部 PASS
SELECT 'Section B · 约束行为验证' AS section, check_item, verdict
FROM verify_blocked
ORDER BY check_item;

-- 回滚后的最终确认：测试数据必须全部消失
SELECT 'ROLLBACK 后残留测试数据(应全为 0)' AS check_item,
       CAST((SELECT COUNT(*) FROM sys_dept
              WHERE node_key IN ('__VERIFY_ROOT__','__VERIFY_CHILD__','__VERIFY_ROOT2__','__VERIFY_BAD__')) AS CHAR) AS dept_left,
       CAST((SELECT COUNT(*) FROM sys_user WHERE username = '__VERIFY_USER__') AS CHAR) AS user_left,
       CAST((SELECT COUNT(*) FROM sys_role WHERE role_key = '__VERIFY_ROLE__') AS CHAR) AS role_left,
       CAST((SELECT COUNT(*) FROM sys_permission WHERE perm_key = 'verify:v:r:view') AS CHAR) AS perm_left,
       CAST((SELECT COUNT(*) FROM sys_operation_log WHERE request_id = 'verify-req') AS CHAR) AS log_left,
       CAST((SELECT COUNT(*) FROM sys_security_state) AS CHAR) AS security_state_rows;

DROP TEMPORARY TABLE IF EXISTS verify_blocked;
DROP PROCEDURE IF EXISTS sp_expect_blocked;

-- =====================================================================
-- 全部 verdict 为 PASS 后，本阶段建表才算完成，可以开始跑导入脚本。
-- 任何一项 FAIL：先定位原因（多半是 MySQL 版本 < 8.0.16 导致 CHECK 被忽略），
-- 修好再继续，不要带着失效的约束往下开发。
-- =====================================================================
