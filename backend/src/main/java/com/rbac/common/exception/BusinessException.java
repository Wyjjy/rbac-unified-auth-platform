package com.rbac.common.exception;

/** 业务规则异常基类：携带统一错误码（§9.2），由全局异常处理器翻译为 HTTP 状态。 */
public class BusinessException extends RuntimeException {
    private final String code;

    public BusinessException(String code, String message) {
        super(message);
        this.code = code;
    }

    public String getCode() { return code; }
}
