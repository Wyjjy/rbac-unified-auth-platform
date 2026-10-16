package com.rbac.service.struct;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * TDD 空壳（红）。§5.6/§6.2：成功审计必须以 MANDATORY 在业务事务内写；
 * 失败事件用 REQUIRES_NEW 独立事务。实现后续填。
 */
@Service
public class StructAuditService {
}
