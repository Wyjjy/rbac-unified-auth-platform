package com.rbac.common.exception;

/** T10：关系替换含无效/重复 ID → 整笔拒绝（HTTP 400，无任何修改）。 */
public class InvalidRelationException extends BusinessException {
    public InvalidRelationException(String message) {
        super("INVALID_RELATION", message);
    }
}
