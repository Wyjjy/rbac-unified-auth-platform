-- =====================================================================
-- V2__seed_security_state.sql
-- 固定配置种子：sys_security_state 单行锁的初始行
-- =====================================================================
-- 来源：开发设计文档 V3.1 §4.13 末尾的 INSERT + §7.5「结构与固定配置分开管理」
-- 作者：后端 D1
--
-- 幂等性要求（文档 §7.5）：
--   重跑本脚本**不得**覆盖已有的 policy_version。安装脚本只在行不存在时
--   插入 id=1 的初始行；后续 policy_version 的变化一律由业务事务递增，
--   绝不允许种子脚本把它重置回 1。
--   因此这里用 INSERT IGNORE，而不是 ON DUPLICATE KEY UPDATE。
--
-- 为什么单独成文件：结构迁移（V1）与固定配置（本文件）分开管理，便于
--   结构变更时不动配置、配置变更时不动结构。
-- =====================================================================

SET NAMES utf8mb4;
SET time_zone = '+00:00';

INSERT IGNORE INTO sys_security_state (id, policy_version, update_time)
VALUES (1, 1, UTC_TIMESTAMP(3));

-- ---------------------------------------------------------------------
-- 自检：必须恰好存在一行，且 policy_version > 0。
-- 预期输出：row_count = 1, policy_version = 1（重跑后仍为当前值，不被重置）
-- ---------------------------------------------------------------------
SELECT COUNT(*)        AS row_count,
       MIN(policy_version) AS policy_version
FROM sys_security_state;
