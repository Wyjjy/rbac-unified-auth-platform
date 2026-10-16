package com.rbac.baseline;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * ✅ 数据层基线测试（应当全绿）。
 * 验证「建表迁移 + 种子 + Excel 导入基线」在测试库中真实就位——
 * 这是对 D1 已交付数据链路（V1/V2/V3/baseline_data.sql）的自动化回归。
 */
@SpringBootTest
@ActiveProfiles("test")
@DisplayName("数据层基线：10 表 / 种子 / 万级数据")
class SchemaSeedTest {

    @Autowired
    JdbcTemplate jdbc;

    @Test
    @DisplayName("10 张业务表全部存在")
    void tenTablesExist() {
        Integer n = jdbc.queryForObject("""
                SELECT COUNT(*) FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = 'rbac' AND TABLE_NAME IN (
                  'sys_dept','sys_user','sys_role','sys_application','sys_permission',
                  'sys_user_role','sys_role_permission','sys_session','sys_operation_log','sys_security_state')
                """, Integer.class);
        assertEquals(10, n, "10 张表必须全部存在");
    }

    @Test
    @DisplayName("安全状态单行（id=1，policy_version=1）")
    void securityStateSingleRow() {
        Integer rows = jdbc.queryForObject("SELECT COUNT(*) FROM sys_security_state", Integer.class);
        assertEquals(1, rows);
        Integer pv = jdbc.queryForObject("SELECT policy_version FROM sys_security_state WHERE id = 1", Integer.class);
        assertEquals(1, pv);
    }

    @Test
    @DisplayName("技术控制面 platform 应用已种子")
    void platformAppSeeded() {
        Integer n = jdbc.queryForObject(
                "SELECT COUNT(*) FROM sys_application WHERE app_key = 'platform'", Integer.class);
        assertEquals(1, n);
    }

    @Test
    @DisplayName("Excel 基线已导入：10000 名员工，全部 PENDING_ACTIVATION 且无密码")
    void baselineEmployeesImported() {
        Integer total = jdbc.queryForObject("SELECT COUNT(*) FROM sys_user", Integer.class);
        assertEquals(10000, total);
        Integer pending = jdbc.queryForObject(
                "SELECT COUNT(*) FROM sys_user WHERE status='PENDING_ACTIVATION' AND password_hash IS NULL", Integer.class);
        assertEquals(10000, pending);
    }
}
