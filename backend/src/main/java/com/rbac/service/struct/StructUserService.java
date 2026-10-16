package com.rbac.service.struct;

import org.springframework.stereotype.Service;

import java.util.List;
import java.util.Map;

/**
 * TDD 空壳（红）：方法签名先按 docs/mapper-registry.md 与附录 C 用例定格。
 * 实现一律抛 UnsupportedOperationException —— 测试先红，实现后变绿（老师要求「测试→编码」流程）。
 * 注意：返回类型 Map 为占位，10/21 建立正式 DTO/VO 后重构为强类型签名。
 */
@Service
public class StructUserService {

    /** A07 GET /users：keyword 匹配工号或姓名，分页 */
    public Map<String, Object> list(int page, int size, String keyword, Long deptId, String status) {
        throw new UnsupportedOperationException("A07 未实现（TDD 红）");
    }

    /** A14 PUT /users/{id}/roles：完整替换语义 + 锁流程（E 要复用的模板） */
    public Map<String, Object> assignRoles(Long userId, List<Long> roleIds) {
        throw new UnsupportedOperationException("A14 未实现（TDD 红）");
    }
}
