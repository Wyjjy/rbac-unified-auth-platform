package com.rbac.common.exception;

/** T11/T27：If-Match 版本冲突（HTTP 412），配合 Retry-After 头使用。 */
public class VersionConflictException extends BusinessException {
    public VersionConflictException(String message) {
        super("VERSION_CONFLICT", message);
    }
}
