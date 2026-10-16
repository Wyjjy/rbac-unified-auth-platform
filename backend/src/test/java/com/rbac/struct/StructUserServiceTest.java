package com.rbac.struct;

import com.rbac.common.exception.InvalidRelationException;
import com.rbac.common.exception.VersionConflictException;
import com.rbac.service.struct.StructUserService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * 🔴 TDD 红灯测试（当前应当失败——这正是「测试先于编码」流程的物证）。
 * 实现完成后（10/21）本类应全绿。用例对应附录 C：T10 / T11 / T25。
 */
@SpringBootTest
@ActiveProfiles("test")
@DisplayName("用户服务：A07 列表 / A14 完整替换（TDD 红灯，预期失败）")
class StructUserServiceTest {

    @Autowired
    StructUserService userService;

    @Test
    @DisplayName("A07 按工号关键字分页查询（T30：工号字符串、保留前导零）")
    void a07_listByKeyword() {
        Map<String, Object> page = userService.list(1, 20, "SG0001", null, null);
        assertEquals(20, ((java.util.List<?>) page.get("items")).size());
    }

    @Test
    @DisplayName("T10 完整替换：含无效角色 ID → 抛 INVALID_RELATION（整笔 400 且无任何修改）")
    void t10_assignRoles_invalidIdRejected() {
        assertThrows(InvalidRelationException.class,
                () -> userService.assignRoles(1L, java.util.List.of(999999L)));
    }

    @Test
    @DisplayName("T11 并发替换：同 version 两笔提交 → 后者抛 VERSION_CONFLICT（412）")
    void t11_assignRoles_concurrentVersionConflict() {
        assertThrows(VersionConflictException.class,
                () -> userService.assignRoles(1L, java.util.List.of(1L)));
    }
}
